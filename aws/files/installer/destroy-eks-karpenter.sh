#!/usr/bin/env bash
set -euo pipefail
export ROOT_DIR=$(dirname "$0")
export AWS_PAGER=""

# require env
if [ ! -f "$ROOT_DIR/env.variables" ]; then
  echo "env.variables missing"
  exit 1
fi
set -a
source "$ROOT_DIR/env.variables"
set +a

# ask whether to remove EFS and S3 storage as part of teardown
DELETE_STORAGE="no"
read -p "Also delete EFS filesystem and S3 bucket? (yes/no) " DELETE_STORAGE

# 1. remove external access rules if we know an IP
if [ -n "${EXTERNAL_IP:-}" ]; then
  echo "Cleaning security‑group rules (external IP $EXTERNAL_IP)…"
  AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION" \
    UZA_PUBLIC_IP="$EXTERNAL_IP" \
    bash "$ROOT_DIR/setup_external_access.sh" cleanup || true
fi

# 2. delete Funnel resources
# aggressively purge anything namespaced and also sweep the whole cluster
# in case some stray object is keeping the namespace in Terminating.

# kill everything in funnel with zero grace period, then strip their finalizers
echo "Purging objects in funnel namespace (force removal)…"
kubectl -n funnel get all,cm,secret,ingress,sts,ds,jobs,cronjobs -o name \
    | xargs -r kubectl delete --force --grace-period=0 --ignore-not-found || true
kubectl -n funnel get $(kubectl -n funnel get all -o name) -o json \
    | jq '.items[]?.metadata.finalizers = []' \
    | kubectl delete --force --grace-period=0 -f - || true

# delete funnel namespace without waiting – our earlier purge emptied it
# plus the cluster teardown immediately following will remove anything else.
echo "Deleting Funnel namespace and ingress/service…"
kubectl delete ns funnel --ignore-not-found --wait=false || true
sleep 2

# if namespace still appears, clear its finalizers immediately (no waiting)
if kubectl get ns funnel >/dev/null 2>&1; then
  echo "namespace still exists, removing finalizers to force deletion"
  kubectl patch ns funnel --type=merge -p '{"metadata":{"finalizers":[]}}' || true
fi

# 3. uninstall LB controller
echo "Uninstall AWS Load Balancer Controller"
helm -n kube-system uninstall aws-load-balancer-controller || true
kubectl -n kube-system delete sa aws-load-balancer-controller || true

# 4. delete associated IAM policy & serviceaccount role
# the SA may be gone; set defaults so later tests don’t blow up
ROLE_ARN=$(kubectl -n kube-system get sa aws-load-balancer-controller \
           -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)
ROLE_NAME=""
POL_ARN=""
[ -n "$ROLE_ARN" ] && ROLE_NAME=${ROLE_ARN##*/}
if [ -n "$ROLE_NAME" ]; then
  echo "Detaching policy from $ROLE_NAME"
  POL_ARN=$(aws iam list-attached-role-policies \
               --role-name "$ROLE_NAME" \
               --query "AttachedPolicies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].PolicyArn" \
               --output text || true)
  [ -n "$POL_ARN" ] && aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POL_ARN" || true
  echo "Deleting role $ROLE_NAME"
  aws iam delete-role --role-name "$ROLE_NAME" || true
fi
if [ -n "$POL_ARN" ]; then
  echo "Deleting policy $POL_ARN"
  aws iam delete-policy --policy-arn "$POL_ARN" || true
fi

# also clean up TES IAM role created during installation
TES_ROLE_NAME="${CLUSTER_NAME}-iam-role"
if aws iam get-role --role-name "$TES_ROLE_NAME" >/dev/null 2>&1; then
  echo "Removing inline policies from $TES_ROLE_NAME"
  for pol in $(aws iam list-role-policies --role-name "$TES_ROLE_NAME" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "$TES_ROLE_NAME" --policy-name "$pol" || true
  done
  echo "Deleting TES IAM role $TES_ROLE_NAME"
  aws iam delete-role --role-name "$TES_ROLE_NAME" || true
fi

# clean up a few well‑known roles that CloudFormation sometimes leaves behind
# such as the node and service‑roles; detach any instance profiles and
# policies first so the delete succeeds.
EXTRA_ROLES=("KarpenterNodeRole-${CLUSTER_NAME}" "AWSServiceRoleForAmazonEKS" "AWSServiceRoleForAmazonEKSNodegroup")
for role in "${EXTRA_ROLES[@]}"; do
  if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    # check path to see if AWS manages it; those are unmodifiable/protected
    ROLE_PATH=$(aws iam get-role --role-name "$role" --query 'Role.Path' --output text 2>/dev/null || echo "")
    if [[ "$ROLE_PATH" == /aws-service-role/* ]]; then
      echo "Skipping protected AWS service role $role (path $ROLE_PATH)"
      continue
    fi
    echo "Cleaning dependencies on IAM role $role"
    # remove from any instance profiles
    for ip in $(aws iam list-instance-profiles-for-role --role-name "$role" --query 'InstanceProfiles[].InstanceProfileName' --output text); do
      aws iam remove-role-from-instance-profile --instance-profile-name "$ip" --role-name "$role" || true
    done
    # detach managed policies
    for arn in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); do
      aws iam detach-role-policy --role-name "$role" --policy-arn "$arn" || true
    done
    # delete inline policies
    for pol in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text); do
      aws iam delete-role-policy --role-name "$role" --policy-name "$pol" || true
    done
    echo "Deleting role $role"
    aws iam delete-role --role-name "$role" || true
  fi
done

# 5. delete EKS cluster & CF stack
echo "Deleting EKS cluster ${CLUSTER_NAME}"
eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_DEFAULT_REGION" || true

# wait for any EC2 instances tagged for the cluster to vanish; the EKS
# cluster tear‑down may take a little time. give up after 2 minutes.
echo "Waiting for cluster EC2 instances to terminate…"
for i in {1..24}; do
  # ignore instances that have already reached the terminated state;
  # describe-instances returns only running, pending, stopping, stopped,
  # etc.  terminated ones are skipped by the filter below.
  INSTANCES=$(aws ec2 describe-instances \
                --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
                          "Name=instance-state-name,Values=pending,running,stopping,stopped" \
                          --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -z "$INSTANCES" ]; then
    echo "no more cluster instances"
    break
  fi
  echo "still have instances: $INSTANCES  (attempt $i/24)"
  sleep 5
done

# delete the CloudFormation stack now that the control plane and nodes
# have been removed. doing this before subnet cleanup ensures the CF
# stack isn’t holding onto ENIs, NATs, etc.
echo "Deleting CloudFormation stack EKS-${CLUSTER_NAME}"
aws cloudformation delete-stack --stack-name "EKS-${CLUSTER_NAME}" --region "$AWS_DEFAULT_REGION" || true
# wait for the stack to actually go away; this usually completes quickly but
# avoids racing against the later subnet-wipe code.
echo "Waiting for CF stack deletion to complete…"
aws cloudformation wait stack-delete-complete \
    --stack-name "EKS-${CLUSTER_NAME}" --region "$AWS_DEFAULT_REGION" || true

# clear any lingering attachments in subnets (ENIs, NAT gateways, load balancers,
# EFS mount targets, etc) now that the stack is gone.
echo "Cleaning subnet dependencies for cluster $CLUSTER_NAME…"
# identify VPC created by eksctl (tagged by name)
VPC_ID=$(aws ec2 describe-vpcs \
           --filters "Name=tag:Name,Values=eksctl-${CLUSTER_NAME}-cluster/VPC" \
           --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)
if [ -n "$VPC_ID" ]; then
  for sn in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
                    --query 'Subnets[].SubnetId' --output text); do
    echo " wiping resources in subnet $sn"
    # try multiple times in case attachments disappear slowly
    for attempt in {1..5}; do
      echo "  cleanup attempt $attempt for subnet $sn"
      # delete network interfaces (may be 'in use' first few times)
      aws ec2 describe-network-interfaces --filters "Name=subnet-id,Values=$sn" \
          --query 'NetworkInterfaces[].NetworkInterfaceId' --output text \
          | xargs -r -n1 aws ec2 delete-network-interface --network-interface-id || true
      # delete NAT gateways
      aws ec2 describe-nat-gateways --filter "Name=subnet-id,Values=$sn" \
          --query 'NatGateways[].NatGatewayId' --output text \
          | xargs -r -n1 aws ec2 delete-nat-gateway --nat-gateway-id || true
      # delete any load balancers in the subnet
      aws elbv2 describe-load-balancers \
          --query 'LoadBalancers[?contains(AvailabilityZones[].SubnetId,`'"$sn"'`)].LoadBalancerArn' \
          --output text | xargs -r -n1 aws elbv2 delete-load-balancer --load-balancer-arn || true
      # see if any interfaces still exist in-use
      REMAIN=$(aws ec2 describe-network-interfaces --filters "Name=subnet-id,Values=$sn" \
                --query 'NetworkInterfaces[?Status==`in-use`].NetworkInterfaceId' --output text)
      if [ -z "$REMAIN" ]; then
        echo "  no more in-use interfaces in $sn"
        break
      fi
      echo "  still have interfaces: $REMAIN"
      sleep 5
    done
  done
  # also remove EFS mount targets if we know one
  if [ -n "${EFS_ID:-}" ]; then
    aws efs describe-mount-targets --file-system-id "$EFS_ID" \
        --query 'MountTargets[?VpcId==`'"$VPC_ID"'`].MountTargetId' \
        --output text \
        | xargs -r -n1 aws efs delete-mount-target --mount-target-id || true
  fi
fi

# 6. optionally remove S3 bucket and EFS filesystem
if [ "$DELETE_STORAGE" = "yes" ]; then
  if aws s3 ls "s3://${TES_S3_BUCKET}" >/dev/null 2>&1; then
    echo "Deleting S3 bucket ${TES_S3_BUCKET} and its contents..."
    aws s3 rb "s3://${TES_S3_BUCKET}" --force || echo "warning: failed to delete bucket"
  else
    echo "S3 bucket ${TES_S3_BUCKET} not found"
  fi
  # attempt to locate EFS by ID or tag
  if [ -n "${EFS_ID:-}" ]; then
    echo "Deleting EFS filesystem $EFS_ID..."
    aws efs delete-file-system --file-system-id "$EFS_ID" || true
  else
    # try to find by name tag
    EFSPATH=$(aws efs describe-file-systems --region "$AWS_DEFAULT_REGION" \
             --query 'FileSystems[?Tags[?Key==`Name`&&Value==`"${CLUSTER_NAME}-efs"`]].FileSystemId | [0]' \
             --output text 2>/dev/null || echo "")
    if [ -n "$EFSPATH" ]; then
      echo "Deleting EFS filesystem $EFSPATH found by tag..."
      aws efs delete-file-system --file-system-id "$EFSPATH" || true
    else
      echo "No EFS filesystem found by tag"
    fi
  fi
fi

echo "Teardown complete."