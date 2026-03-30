#!/usr/bin/env bash
set -u
set -e  # Exit on error

#############
### GOAL ###
##############
# Allow direct access from UZA on-prem IP to Funnel TES
# usage: setup_external_access.sh [cleanup]
MODE="apply"
if [ $# -gt 0 ]; then
  if [ "$1" = "cleanup" ] || [ "$1" = "--cleanup" ]; then
    MODE="cleanup"
    shift
  fi
fi

# Namespace and service name used by the installer (allow overrides via env)
: "${TES_NAMESPACE:=funnel}"
: "${SERVICE_NAME:=tes-service}"
: "${FUNNEL_PORT:=8000}"
: "${AWS_DEFAULT_REGION:=eu-west-2}"

# we'll accumulate load balancer security group IDs here; start as empty array
SG_IDS=()

# validate we have an IP when applying rules
if [ "$MODE" = "apply" ] && [ -z "${UZA_PUBLIC_IP}" ]; then
  echo "ERROR: UZA_PUBLIC_IP must be set (either in env or by exporting)"
  exit 1
fi

# try to infer cluster name from node SG tags if not provided
if [ -z "${CLUSTER_NAME:-}" ]; then
  CLUSTER_NAME=$(aws ec2 describe-security-groups --region "$AWS_DEFAULT_REGION" \
      --filters "Name=tag:eksctl.cluster.k8s.io/v1alpha1/cluster-name,Values=*" \
      --query 'SecurityGroups[0].Tags[?Key==`eksctl.cluster.k8s.io/v1alpha1/cluster-name`].Value | [0]' \
      --output text 2>/dev/null || echo "")
  if [ -z "$CLUSTER_NAME" ]; then
    echo "WARNING: could not infer CLUSTER_NAME; node SG patching may not work."
  else
    echo "Inferred cluster name: $CLUSTER_NAME"
  fi
fi

if [ "$MODE" = "apply" ]; then
  echo "Waiting for Funnel Ingress / Service external hostname to be assigned..."
  echo "Looking in ${TES_NAMESPACE} namespace"
  LB_HOSTNAME=""
  for i in {1..180}; do
    # prefer Ingress (ALB)
    echo "- checking for hostname"
    LB_HOSTNAME=$(kubectl -n "${TES_NAMESPACE}" get ingress tes-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -z "$LB_HOSTNAME" ]; then
      echo "- checking for IP"
      LB_HOSTNAME=$(kubectl -n "${TES_NAMESPACE}" get ingress tes-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    else 
      echo "✓ Ingress hostname/IP: $LB_HOSTNAME"
    fi

    # fallback to Service (LoadBalancer)
    if [ -z "$LB_HOSTNAME" ]; then
      echo "- checking Service for hostname"
      LB_HOSTNAME=$(kubectl -n "${TES_NAMESPACE}" get svc ${SERVICE_NAME} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    fi
    if [ -z "$LB_HOSTNAME" ]; then
      echo "- checking Service for IP"
      LB_HOSTNAME=$(kubectl -n "${TES_NAMESPACE}" get svc ${SERVICE_NAME} -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    fi

    if [ -n "$LB_HOSTNAME" ] && [ "$LB_HOSTNAME" != "None" ]; then
      echo "✓ External hostname/IP: $LB_HOSTNAME"
      break
    fi

    if [ $((i % 15)) -eq 0 ]; then
      echo "  Waiting... (${i}s)"
    fi
    sleep 1
  done

  if [ -z "$LB_HOSTNAME" ] || [ "$LB_HOSTNAME" == "None" ]; then
    echo "❌ External hostname/IP not assigned after 3 minutes."
    echo ""
    echo "Service status:"
    kubectl -n "${TES_NAMESPACE}" get svc ${SERVICE_NAME} -o wide
    kubectl -n "${TES_NAMESPACE}" get ingress tes-ingress -o wide || true
    exit 1
  fi

  echo "Looking up Load Balancer in AWS (classic or v2) by DNS/IP..."
  # Try Classic ELB (v1)
  CLB_NAME=$(aws elb describe-load-balancers \
    --region "${AWS_DEFAULT_REGION}" \
    --query "LoadBalancerDescriptions[?DNSName=='${LB_HOSTNAME}'].LoadBalancerName" \
    --output text 2>/dev/null || echo "")
  SG_IDS=()
  if [ -n "$CLB_NAME" ] && [ "$CLB_NAME" != "None" ]; then
    echo "Found Classic ELB: $CLB_NAME"
    # Get the security group attached to this Classic ELB
    SG_ID=$(aws elb describe-load-balancers \
      --region "${AWS_DEFAULT_REGION}" \
      --load-balancer-names "${CLB_NAME}" \
      --query "LoadBalancerDescriptions[0].SecurityGroups[0]" \
      --output text)
    if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
      SG_IDS+=("$SG_ID")
    fi
  else
    # Try ALB / NLB (elbv2)
    LB_ARN=$(aws elbv2 describe-load-balancers \
      --region "${AWS_DEFAULT_REGION}" \
      --query "LoadBalancers[?DNSName=='${LB_HOSTNAME}'].LoadBalancerArn" \
      --output text 2>/dev/null || echo "")
    if [ -n "$LB_ARN" ] && [ "$LB_ARN" != "None" ]; then
      echo "Found ALB/NLB ARN: $LB_ARN"
      # collect security groups attached to the LB
      SG_LIST=$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB_ARN" --region "${AWS_DEFAULT_REGION}" --query 'LoadBalancers[0].SecurityGroups' --output text 2>/dev/null || echo "")
      for sg in $SG_LIST; do
        SG_IDS+=("$sg")
      done
    fi
  fi
else
  echo "cleanup mode - discovering security groups by UZA IP filter"
  # Query may return multiple IDs separated by whitespace; read them into an array
  mapfile -t SG_IDS < <(aws ec2 describe-security-groups --region "${AWS_DEFAULT_REGION}" \
    --filters "Name=ip-permission.cidr,Values=${UZA_PUBLIC_IP}/32" \
            "Name=ip-permission.from-port,Values=${FUNNEL_PORT},9090" \
            "Name=ip-permission.to-port,Values=${FUNNEL_PORT},9090" \
    --query 'SecurityGroups[].GroupId' --output text)
fi

# Ensure SG_IDS is always an array before checking its length
if [ ${#SG_IDS[@]} -eq 0 ]; then
  echo "❌ Could not find any security groups attached to load balancer $LB_HOSTNAME"
  exit 1
fi

echo "✓ Load balancer security groups: ${SG_IDS[*]}"

# ensure node security groups allow traffic from ALB SGs (needed when target-type=ip)
NODE_SGS=$(aws ec2 describe-security-groups --region "${AWS_DEFAULT_REGION}" \
            --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME:-}" \
            --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || echo "")
if [ -n "$NODE_SGS" ]; then
  if [ "$MODE" = "apply" ]; then
    echo "Patching node security groups to allow ALB ingress..."
    for nsg in $NODE_SGS; do
      for alb in "${SG_IDS[@]}"; do
        # allow 8000 and 9090
        for p in ${FUNNEL_PORT:-8000} 9090; do
          aws ec2 authorize-security-group-ingress \
            --group-id "$nsg" --protocol tcp --port $p --source-group "$alb" \
            --region "${AWS_DEFAULT_REGION}" 2>/dev/null || true
        done
      done
    done
    echo "Node SG patch complete: $NODE_SGS"
  else
    echo "Removing ALB-to-node rules in cleanup mode"
    for nsg in $NODE_SGS; do
      for alb in "${SG_IDS[@]}"; do
        for p in ${FUNNEL_PORT:-8000} 9090; do
          aws ec2 revoke-security-group-ingress \
            --group-id "$nsg" --protocol tcp --port $p --source-group "$alb" \
            --region "${AWS_DEFAULT_REGION}" 2>/dev/null || true
        done
      done
    done
    echo "Node SG cleanup complete: $NODE_SGS"
  fi
fi
echo "✓ Load balancer security groups: ${SG_IDS[*]}"

##########################
## ADD INGRESS RULES    ##
##########################

for SG_ID in "${SG_IDS[@]}"; do
  echo "Processing SG: $SG_ID"
  if [ "$MODE" = "apply" ]; then
    # Port for HTTP API
    echo "Checking ingress rule for port ${FUNNEL_PORT} on $SG_ID..."
    RULE_HTTP=$(aws ec2 describe-security-groups \
      --group-ids "$SG_ID" \
      --region "${AWS_DEFAULT_REGION}" \
      --query "SecurityGroups[0].IpPermissions[?FromPort==\`${FUNNEL_PORT}\` && ToPort==\`${FUNNEL_PORT}\` && IpRanges[?CidrIp==\`${UZA_PUBLIC_IP}/32\`]]" \
      --output json | jq '. | length' 2>/dev/null || echo 0)

    if [ "$RULE_HTTP" -eq 0 ]; then
      echo "Adding ingress rule for port ${FUNNEL_PORT} from $UZA_PUBLIC_IP to $SG_ID..."
      aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port ${FUNNEL_PORT} \
        --cidr "$UZA_PUBLIC_IP/32" \
        --region "${AWS_DEFAULT_REGION}" 2>/dev/null || echo "⚠ Rule might already exist or insufficient permissions"
      echo "✓ Ingress rule added for port ${FUNNEL_PORT}"
    else
      echo "✓ Ingress rule already exists for port ${FUNNEL_PORT} on $SG_ID"
    fi

    # Port 9090 (gRPC / RPC) — optional
    echo "Checking ingress rule for port 9090 on $SG_ID..."
    RULE_RPC=$(aws ec2 describe-security-groups \
      --group-ids "$SG_ID" \
      --region "${AWS_DEFAULT_REGION}" \
      --query "SecurityGroups[0].IpPermissions[?FromPort==\`9090\` && ToPort==\`9090\` && IpRanges[?CidrIp==\`${UZA_PUBLIC_IP}/32\`]]" \
      --output json | jq '. | length' 2>/dev/null || echo 0)

    if [ "$RULE_RPC" -eq 0 ]; then
      echo "Adding ingress rule for port 9090 from $UZA_PUBLIC_IP to $SG_ID..."
      aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp \
        --port 9090 \
        --cidr "$UZA_PUBLIC_IP/32" \
        --region "${AWS_DEFAULT_REGION}" 2>/dev/null || echo "⚠ Rule might already exist or insufficient permissions"
      echo "✓ Ingress rule added for port 9090"
    else
      echo "✓ Ingress rule already exists for port 9090 on $SG_ID"
    fi
  else
    # cleanup mode: revoke rules
    echo "Removing UZA rules from SG $SG_ID"
    aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --protocol tcp --port ${FUNNEL_PORT} --cidr "$UZA_PUBLIC_IP/32" --region "${AWS_DEFAULT_REGION}" 2>/dev/null || true
    aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 9090 --cidr "$UZA_PUBLIC_IP/32" --region "${AWS_DEFAULT_REGION}" 2>/dev/null || true
  fi
done

##########################
## VERIFY + SHOW INFO   ##
##########################

set +e

echo ""
echo "=== TES Service Information ==="
kubectl -n "${TES_NAMESPACE}" get svc ${SERVICE_NAME} -o wide

TES_ENDPOINT="http://${LB_HOSTNAME}:${FUNNEL_PORT}"

if [ "$MODE" = "cleanup" ]; then
  echo "cleanup mode - skipping status/test output"
  exit 0
fi

echo ""
echo "=== Funnel pod status ==="
kubectl get pods -n "${TES_NAMESPACE}" -l app=funnel -o wide

echo ""
echo "=== Testing TES endpoint (may need 60s for LB health checks to pass) ==="
if curl -s -m 10 "${TES_ENDPOINT}/service-info" >/dev/null 2>&1; then
  echo "✓ TES endpoint responding"
else
  echo "⚠ TES endpoint not responding yet (LB health checks still propagating - wait ~60s and retry)"
fi

echo ""
echo "=== Cromwell Configuration ==="
echo ""
echo "endpoint = \"${TES_ENDPOINT}\""
echo ""
echo "=== Quick API test commands ==="
echo "  curl ${TES_ENDPOINT}/service-info"
echo "  curl ${TES_ENDPOINT}/v1/tasks"
echo ""
