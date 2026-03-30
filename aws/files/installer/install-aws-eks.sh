#!/bin/bash
# ============================================================
# AWS EKS Installer — Cromwell + Funnel TES platform
# EKS + Karpenter (Spot) + EFS + ALB + Funnel TES
# ============================================================
# Usage:
#   cd aws/files/installer
#   ./install-aws-eks.sh
#
# Prerequisites:
#   aws    — AWS CLI v2 (credentials configured via aws configure / IAM role)
#   eksctl — EKS cluster lifecycle tool
#   kubectl — Kubernetes CLI
#   helm   — Helm 3
#   envsubst — from gettext package
#   python3  — for instance-type filtering
#
# Follows: https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/
# ============================================================
set -euo pipefail

export ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Disable AWS CLI pager (prevents interactive 'less' prompt)
export AWS_PAGER=""

######################
## COLOUR HELPERS   ##
######################
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠  $*${NC}"; }
die()  { echo -e "${RED}❌ $*${NC}" >&2; exit 1; }

######################
## HELPER FUNCTIONS ##
######################

# Retry kubectl apply with exponential back-off to handle transient API errors.
retry_kubectl() {
    local yaml_file="$1"
    local max_attempts=5
    local delay=10
    local attempt=1
    until kubectl apply -f "$yaml_file"; do
        if [ $attempt -ge $max_attempts ]; then
            die "Failed to apply $yaml_file after $max_attempts attempts"
        fi
        warn "Retrying $yaml_file in ${delay}s (attempt $attempt)..."
        sleep $delay
        attempt=$((attempt+1))
    done
}

# Render a template with envsubst and apply it with kubectl.
# Usage: apply_template <template_file> [envsubst_var_list]
# The rendered output is written to <template_file without .template>.
apply_template() {
    local template="$1"
    local vars="${2:-}"
    local out="${template/.template/}"
    if [ -n "$vars" ]; then
        envsubst "$vars" < "$template" > "$out"
    else
        envsubst < "$template" > "$out"
    fi
    retry_kubectl "$out"
}

# Poll a command until its output matches an expected value, or timeout.
# Usage: wait_for_status <poll_command_string> <expected> <timeout_sec> <label>
wait_for_status() {
    local poll_cmd="$1"
    local expected="$2"
    local timeout="${3:-600}"
    local label="${4:-resource}"
    local waited=0
    local interval=15
    echo "Waiting for $label to reach status '$expected' (timeout ${timeout}s)..."
    while true; do
        local status
        status=$(eval "$poll_cmd" 2>/dev/null | tr -d '"' | tr -d '[:space:]') || true
        if [[ "$status" == "$expected" ]]; then
            ok "$label is $expected"
            return 0
        fi
        if [[ $waited -ge $timeout ]]; then
            die "Timed out waiting for $label (last status: $status)"
        fi
        echo "  [${waited}s/${timeout}s] $label status: $status — waiting..."
        sleep $interval
        waited=$((waited + interval))
    done
}

############################
## PHASE 0: ENV + PREREQS ##
############################
echo "============================================"
echo " Phase 0: Environment check & prerequisites"
echo "============================================"

# ── Load env.variables ────────────────────────────────────────────────────────
if [ ! -f "$ROOT_DIR/env.variables" ]; then
    die "env.variables not found at $ROOT_DIR/env.variables"
fi
set -a
source "$ROOT_DIR/env.variables"
set +a

# ── Resolve derived / optional variables ──────────────────────────────────────
# AWS_ACCOUNT_ID
# Command: aws sts get-caller-identity
# Output: {"UserId":"...","Account":"123456789012","Arn":"..."}
# Parse:  --query Account --output text → "123456789012"
if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity \
        --query Account --output text 2>/dev/null) \
        || die "Cannot resolve AWS_ACCOUNT_ID. Check your AWS credentials."
    echo "Resolved AWS_ACCOUNT_ID: $AWS_ACCOUNT_ID"
fi
export AWS_ACCOUNT_ID

# ALIAS_VERSION — AL2023 AMI alias tag for Karpenter (e.g. v20260223)
# Step 1: SSM parameter → AMI ID
# Command: aws ssm get-parameter
#   --name /aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id
# Output: {"Parameter":{"Value":"ami-0abc...",...}}
# Parse:  --query Parameter.Value --output text → "ami-0abc..."
# Step 2: AMI ID → name string
# Command: aws ec2 describe-images --image-ids <ami-id>
# Output: {"Images":[{"Name":"al2023-ami-2023.6.20260223.0-kernel-6.1-x86_64",...}]}
# Parse:  --query 'Images[0].Name' --output text → extract v<date> with sed
if [ -z "${ALIAS_VERSION:-}" ]; then
    _ami_id=$(aws ssm get-parameter \
        --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" \
        --region "${AWS_DEFAULT_REGION}" \
        --query Parameter.Value --output text 2>/dev/null || echo "")
    if [ -n "$_ami_id" ]; then
        ALIAS_VERSION=$(aws ec2 describe-images \
            --region "${AWS_DEFAULT_REGION}" \
            --image-ids "$_ami_id" \
            --query 'Images[0].Name' --output text 2>/dev/null \
            | sed -r 's/^.*(v[0-9]+).*$/\1/' || echo "")
    fi
    [ -z "${ALIAS_VERSION:-}" ] && die "Cannot resolve ALIAS_VERSION from SSM. Set it manually in env.variables."
    echo "Resolved ALIAS_VERSION: $ALIAS_VERSION"
fi
export ALIAS_VERSION

# SPOT_QUOTA — Standard Spot vCPU limit in this region
# Command: aws service-quotas list-service-quotas --service-code ec2
# Output: {"Quotas":[{..."QuotaName":"All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests","Value":100.0,...}]}
# Parse:  --query "Quotas[?QuotaName=='All Standard ...'].Value" --output text → "100.0"
# Note:   Value is a float string; convert to integer with awk '{print int($1)}'
if [ -z "${SPOT_QUOTA:-}" ]; then
    SPOT_QUOTA=$(aws service-quotas list-service-quotas \
        --service-code ec2 \
        --region "${AWS_DEFAULT_REGION}" \
        --query "Quotas[?QuotaName=='All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests'].Value" \
        --output text 2>/dev/null | awk '{print int($1)}' || echo "100")
    echo "Resolved SPOT_QUOTA: $SPOT_QUOTA"
fi
export SPOT_QUOTA

# Bootstrap nodegroup name (used for post-creation labeling)
export BOOTSTRAP_NG="${CLUSTER_NAME}-baseline-arm"
export BOOTSTRAP_LABEL_VALUE="true"

# Karpenter IAM role ARN (created by CloudFormation, referenced by Helm)
export KARPENTER_IAM_ROLE_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter"

# TES IAM role name
export TES_ROLE_NAME="${CLUSTER_NAME}-iam-role"

# Funnel image — derive from account/region/version if not pre-filled
FUNNEL_IMAGE="${FUNNEL_IMAGE:-${AWS_ACCOUNT_ID}.dkr.ecr.${ECR_IMAGE_REGION}.amazonaws.com/funnel:${TES_VERSION}}"
export FUNNEL_IMAGE

# TES S3 bucket — derive from account/region if not pre-filled
TES_S3_BUCKET="${TES_S3_BUCKET:-tes-tasks-${AWS_ACCOUNT_ID}-${AWS_DEFAULT_REGION}}"
export TES_S3_BUCKET

# USE_EFS defaults to false
USE_EFS="${USE_EFS:-false}"
# Initialise EFS mount vars to empty (set properly after EFS creation, Phase 5)
export EFS_WORKER_MOUNT=""
export EFS_WORKER_VOLUME=""
export EFS_NERDCTL_MOUNT=""

# Defaults for optional tuning knobs
SYSTEM_NODE_TYPE="${SYSTEM_NODE_TYPE:-t4g.medium}"
KARPENTER_REPLICAS="${KARPENTER_REPLICAS:-1}"
EBS_IOPS="${EBS_IOPS:-3000}"
EBS_THROUGHPUT="${EBS_THROUGHPUT:-250}"
BOOTSTRAP_LABEL_KEY="${BOOTSTRAP_LABEL_KEY:-karpenter.io/bootstrap}"
export SYSTEM_NODE_TYPE KARPENTER_REPLICAS EBS_IOPS EBS_THROUGHPUT BOOTSTRAP_LABEL_KEY

# ── Validate required variables ───────────────────────────────────────────────
REQUIRED_VARS=(
    CLUSTER_NAME AWS_DEFAULT_REGION AWS_ACCOUNT_ID AWS_PARTITION
    K8S_VERSION ALIAS_VERSION SPOT_QUOTA
    KARPENTER_NAMESPACE KARPENTER_VERSION KARPENTER_REPLICAS
    WORKER_INSTANCE_FAMILIES WORKER_MIN_GENERATION WORKER_EXCLUDE_TYPES
    TES_NAMESPACE TES_VERSION FUNNEL_IMAGE TES_S3_BUCKET ARTIFACTS_S3_BUCKET
    FUNNEL_PORT SERVICE_NAME
)
for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR:-}" ]; then
        die "$VAR is not set. Check env.variables."
    fi
done

# ── Validate CLI tools ────────────────────────────────────────────────────────
for tool in eksctl kubectl aws helm envsubst python3; do
    command -v "$tool" &>/dev/null || die "'$tool' is not in PATH. Install it first."
done
ok "All CLI tools found"

# ── Validate AWS credentials ──────────────────────────────────────────────────
aws sts get-caller-identity --output text >/dev/null 2>&1 \
    || die "AWS credentials are not configured. Run: aws configure"
ok "AWS credentials valid"

echo ""
echo "  Cluster       : $CLUSTER_NAME"
echo "  Region        : $AWS_DEFAULT_REGION"
echo "  Account       : $AWS_ACCOUNT_ID"
echo "  K8s version   : $K8S_VERSION"
echo "  AMI alias     : $ALIAS_VERSION"
echo "  Spot quota    : $SPOT_QUOTA vCPU"
echo "  Funnel image  : $FUNNEL_IMAGE"
echo "  TES bucket    : $TES_S3_BUCKET"
echo "  USE_EFS       : $USE_EFS"
echo ""

#################################################
## PHASE 1: CLOUDFORMATION PREREQUISITES STACK ##
#################################################
echo "============================================"
echo " Phase 1: CloudFormation prerequisites"
echo "============================================"
# The Karpenter getting-started CloudFormation stack creates:
#   - KarpenterNodeRole-<cluster>   (instance profile for worker nodes)
#   - Five KarpenterController* IAM policies for the controller's IRSA role
#   - An SQS interruption queue named <cluster>
#   - EventBridge rules that feed Spot/rebalance/health events into the queue
#
# Command: aws cloudformation deploy
# Output: prints "Successfully created/updated stack - EKS-<cluster>" on success
# Failure: exits non-zero; describe-stacks can show the failure reason.
echo "Deploying CloudFormation stack for Karpenter prerequisites..."
aws cloudformation deploy \
    --region "$AWS_DEFAULT_REGION" \
    --stack-name "EKS-${CLUSTER_NAME}" \
    --template-file "$ROOT_DIR/yamls/eks-cluster-cloudformation.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides "ClusterName=${CLUSTER_NAME}"

# Poll until CREATE_COMPLETE (or fail fast on terminal error states).
# Command: aws cloudformation describe-stacks --stack-name EKS-<cluster>
# Output: {"Stacks":[{"StackStatus":"CREATE_COMPLETE",...}]}
# Parse:  --query "Stacks[0].StackStatus" --output text
# Valid terminal states: CREATE_COMPLETE | UPDATE_COMPLETE
# Error states: CREATE_FAILED | ROLLBACK_COMPLETE | ROLLBACK_FAILED
echo "Waiting for CloudFormation stack to complete..."
ITER=0; MAX_ITER=40
while [[ $ITER -lt $MAX_ITER ]]; do
    ITER=$((ITER+1))
    CF_STATUS=$(aws cloudformation describe-stacks \
        --stack-name "EKS-${CLUSTER_NAME}" \
        --query "Stacks[0].StackStatus" --output text)
    if [[ "$CF_STATUS" == "CREATE_COMPLETE" || "$CF_STATUS" == "UPDATE_COMPLETE" ]]; then
        ok "CloudFormation stack is $CF_STATUS"
        break
    elif [[ "$CF_STATUS" == *"IN_PROGRESS"* ]]; then
        echo "  $ITER/$MAX_ITER : Stack status: $CF_STATUS — waiting 15s..."
        sleep 15
    else
        die "CloudFormation stack reached unexpected status: $CF_STATUS"
    fi
done

echo ""

####################################
## PHASE 2: EKS CLUSTER (eksctl)  ##
####################################
echo "============================================"
echo " Phase 2: EKS cluster"
echo "============================================"
# eksctl create cluster reads a ClusterConfig YAML that declares:
#   - Managed nodegroup (1 ARM64 t4g.medium baseline node) with OIDC enabled
#   - Pod Identity Association for Karpenter (links SA to IAM role)
#   - IAM identity mapping for KarpenterNodeRole (allows nodes to join the cluster)
#   - Addons: eks-pod-identity-agent, vpc-cni
#
# Command: eksctl create cluster -f <file>
# Output: progress lines + "EKS cluster <name> in <region> region is ready"
# Note: this is slow (10-15 min); eksctl polls internally.
CLUSTER_TEMPLATE="$ROOT_DIR/yamls/cluster.template.yaml"
CLUSTER_YAML="${CLUSTER_TEMPLATE/.template/}"
echo "Rendering cluster configuration..."
envsubst < "$CLUSTER_TEMPLATE" > "$CLUSTER_YAML"
echo "Creating EKS cluster '${CLUSTER_NAME}' in ${AWS_DEFAULT_REGION} (K8s ${K8S_VERSION})..."
eksctl create cluster -f "$CLUSTER_YAML"

# Wait for cluster ACTIVE status.
# Command: aws eks describe-cluster --name <cluster>
# Output: {"cluster":{..."status":"ACTIVE",...}}
# Parse:  --query "cluster.status" --output text
# Valid terminal: ACTIVE
# In-progress: CREATING | UPDATING | PENDING
wait_for_status \
    "aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_DEFAULT_REGION} --query 'cluster.status' --output text" \
    "ACTIVE" 1800 "EKS cluster"

# Fetch cluster endpoint and VPC ID (needed in later phases).
# Command: aws eks describe-cluster --name <cluster>
# Output: {"cluster":{..."endpoint":"https://...","resourcesVpcConfig":{"vpcId":"vpc-..."}}}
# Parse:  --query "cluster.endpoint" --output text
# Parse:  --query "cluster.resourcesVpcConfig.vpcId" --output text
export CLUSTER_ENDPOINT
CLUSTER_ENDPOINT=$(aws eks describe-cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_DEFAULT_REGION}" \
    --query "cluster.endpoint" --output text)
export VPC_ID
VPC_ID=$(aws eks describe-cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_DEFAULT_REGION}" \
    --query "cluster.resourcesVpcConfig.vpcId" --output text)
ok "Cluster endpoint: $CLUSTER_ENDPOINT"
ok "VPC ID: $VPC_ID"

# Label bootstrap nodes (ARM baseline managed nodegroup).
# Command: kubectl label nodes -l eksctl.io/nodegroup=<ng> <key>=<value>
# Note: the label selector uses the eksctl-applied nodegroup label.
if kubectl get node -l "eksctl.io/nodegroup=${BOOTSTRAP_NG}" \
        --no-headers 2>/dev/null | grep -q .; then
    echo "Labeling bootstrap nodes: ${BOOTSTRAP_LABEL_KEY}=${BOOTSTRAP_LABEL_VALUE}, workload-type=system"
    kubectl label nodes -l "eksctl.io/nodegroup=${BOOTSTRAP_NG}" \
        "${BOOTSTRAP_LABEL_KEY}=${BOOTSTRAP_LABEL_VALUE}" \
        workload-type=system \
        --overwrite || true
fi

echo ""

#######################################
## PHASE 3: NODE IAM POLICIES        ##
#######################################
echo "============================================"
echo " Phase 3: Node IAM policies"
echo "============================================"
# KarpenterNodeRole-<cluster> is created by CloudFormation (Phase 1).
# Attach inline policies for EBS autoscale and optional EFS access.

# Render and attach the EBS autoscale + S3 artifacts policy from template.
# Command: aws iam put-role-policy --role-name ... --policy-document file://...
# Note: put-role-policy is idempotent (overwrites existing inline policy).
echo "Rendering EBS autoscale policy..."
EBS_POLICY_TEMPLATE="$ROOT_DIR/policies/EBSAutoscaleAndArtifactsPolicy.template.json"
EBS_POLICY_OUT="${EBS_POLICY_TEMPLATE/.template/}"
if [ -f "$EBS_POLICY_TEMPLATE" ]; then
    envsubst < "$EBS_POLICY_TEMPLATE" > "$EBS_POLICY_OUT"
else
    [ -f "$EBS_POLICY_OUT" ] || die "EBS policy template not found at $EBS_POLICY_TEMPLATE"
fi
aws iam put-role-policy \
    --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --policy-name "EBSAutoscaleAndArtifactsPolicy" \
    --policy-document file://"$EBS_POLICY_OUT"
ok "EBSAutoscaleAndArtifactsPolicy attached"

# EFS access policy (only if USE_EFS=true).
# Command: aws iam put-role-policy (same as above — idempotent)
if [ "${USE_EFS}" = "true" ]; then
    EFS_POLICY="$ROOT_DIR/policies/EFSClientPolicy.json"
    [ -f "$EFS_POLICY" ] || die "EFSClientPolicy.json not found at $EFS_POLICY"
    aws iam put-role-policy \
        --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
        --policy-name "EFSClientPolicy" \
        --policy-document file://"$EFS_POLICY"
    ok "EFSClientPolicy attached"
fi

echo ""

###############
## PHASE 4: KARPENTER ##
###############
echo "============================================"
echo " Phase 4: Karpenter controller"
echo "============================================"

# Log out of public ECR to avoid stale credential conflicts when pulling the Helm chart.
# Command: helm registry logout public.ecr.aws
# Output: "Removing login credentials for public.ecr.aws"
helm registry logout public.ecr.aws 2>/dev/null || true

# ── Subnet and security-group discovery tagging ───────────────────────────────
# Karpenter discovers subnets and SGs by the tag karpenter.sh/discovery=<cluster>.
# We also add kubernetes.io/cluster/<cluster>=owned so the AWS Load Balancer
# Controller can discover the same subnets.
#
# Command: aws ec2 describe-subnets
# Filter:  vpc-id=<vpc>
# Output:  {"Subnets":[{"SubnetId":"subnet-..."},...]}
# Parse:   --query 'Subnets[].SubnetId' --output text → space-separated list
echo "Tagging subnets for Karpenter and ALB discovery..."
SUBNET_IDS=$(aws ec2 describe-subnets \
    --region "$AWS_DEFAULT_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[].SubnetId' --output text 2>/dev/null || echo "")
[ -z "$SUBNET_IDS" ] && die "No subnets found in VPC $VPC_ID"

for sn in $SUBNET_IDS; do
    # Check for existing cluster tag:
    # Command: aws ec2 describe-tags --filters Name=resource-id,...
    # Output:  {"Tags":[...]}
    # Parse:   --query 'Tags | length(@)' --output text → integer string
    has_cluster=$(aws ec2 describe-tags \
        --region "$AWS_DEFAULT_REGION" \
        --filters "Name=resource-id,Values=$sn" \
                  "Name=key,Values=kubernetes.io/cluster/${CLUSTER_NAME}" \
        --query 'Tags | length(@)' --output text 2>/dev/null || echo 0)
    [ "$has_cluster" -eq 0 ] && \
        aws ec2 create-tags --region "$AWS_DEFAULT_REGION" \
            --resources "$sn" \
            --tags "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned" 2>/dev/null || true

    has_karpenter=$(aws ec2 describe-tags \
        --region "$AWS_DEFAULT_REGION" \
        --filters "Name=resource-id,Values=$sn" \
                  "Name=key,Values=karpenter.sh/discovery" \
        --query 'Tags | length(@)' --output text 2>/dev/null || echo 0)
    [ "$has_karpenter" -eq 0 ] && \
        aws ec2 create-tags --region "$AWS_DEFAULT_REGION" \
            --resources "$sn" \
            --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" 2>/dev/null || true
done
ok "Subnet tags applied"

# Brief pause for tag propagation across AZs before Karpenter queries them.
sleep 10

# ── Create TES namespace early (needed before any namespaced resource) ─────────
echo "Creating namespace ${TES_NAMESPACE}..."
apply_template "${ROOT_DIR}/yamls/funnel-namespace.template.yaml" \
    '${TES_NAMESPACE}'

# ── Install Karpenter Helm chart ───────────────────────────────────────────────
# Chart source: public ECR (oci://public.ecr.aws/karpenter/karpenter)
# Command: helm upgrade --install karpenter oci://... --version <version>
# The SA annotation (IRSA) is already set by eksctl podIdentityAssociation;
# we use --wait --timeout 10m so the install block only succeeds once the
# controller pod is Running.
helm_args=(
    "upgrade" "--install" "karpenter"
    "oci://public.ecr.aws/karpenter/karpenter"
    "--version" "${KARPENTER_VERSION}"
    "--namespace" "${KARPENTER_NAMESPACE}"
    "--create-namespace"
    "--set" "settings.clusterName=${CLUSTER_NAME}"
    "--set" "settings.interruptionQueue=${CLUSTER_NAME}"
    "--set" "replicas=${KARPENTER_REPLICAS}"
    "--set" "controller.resources.requests.cpu=250m"
    "--set" "controller.resources.requests.memory=512Mi"
    "--set" "controller.resources.limits.cpu=250m"
    "--set" "controller.resources.limits.memory=750Mi"
)
# Pin controller to the bootstrap node if BOOTSTRAP_LABEL_KEY is set.
if [ -n "${BOOTSTRAP_LABEL_KEY:-}" ]; then
    esckey=$(echo "$BOOTSTRAP_LABEL_KEY" | sed 's/\./\\\./g')
    helm_args+=("--set" "controller.nodeSelector.${esckey}=${BOOTSTRAP_LABEL_VALUE}")
fi
helm "${helm_args[@]}" --wait --timeout 10m
ok "Karpenter controller installed"

# ── Verify Karpenter SA annotation (IRSA) ────────────────────────────────────
# Command: kubectl get sa karpenter -n kube-system
#   -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
# Expected: "arn:aws:iam::123456789012:role/TES-karpenter"
SA_ANNOTATION=$(kubectl -n "${KARPENTER_NAMESPACE}" get sa karpenter \
    -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
if [ -z "$SA_ANNOTATION" ]; then
    echo "Annotating Karpenter ServiceAccount with role ARN..."
    kubectl -n "${KARPENTER_NAMESPACE}" annotate sa karpenter \
        "eks.amazonaws.com/role-arn=${KARPENTER_IAM_ROLE_ARN}" --overwrite
else
    ok "Karpenter SA annotation: $SA_ANNOTATION"
fi

# Restart Karpenter so it picks up any new IAM/annotation changes.
kubectl -n "${KARPENTER_NAMESPACE}" rollout restart deployment karpenter || true
echo "Waiting for Karpenter pod to be Ready (3 min)..."
kubectl -n "${KARPENTER_NAMESPACE}" wait \
    --for=condition=Ready pod -l app.kubernetes.io/name=karpenter \
    --timeout=180s \
    || die "Karpenter pod did not become Ready. Check: kubectl -n ${KARPENTER_NAMESPACE} logs -l app.kubernetes.io/name=karpenter"

# Verify required managed policies are attached to the controller role.
# Command: aws iam list-attached-role-policies --role-name <role>
# Output: {"AttachedPolicies":[{"PolicyName":"...","PolicyArn":"..."},...]}
# Parse:  --query "AttachedPolicies[].PolicyArn" --output text
CONTROLLER_ROLE="${CLUSTER_NAME}-karpenter"
ATTACHED=$(aws iam list-attached-role-policies \
    --role-name "$CONTROLLER_ROLE" \
    --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null || echo "")
for pol in \
    "KarpenterControllerInterruptionPolicy-${CLUSTER_NAME}" \
    "KarpenterControllerNodeLifecyclePolicy-${CLUSTER_NAME}" \
    "KarpenterControllerIAMIntegrationPolicy-${CLUSTER_NAME}" \
    "KarpenterControllerEKSIntegrationPolicy-${CLUSTER_NAME}" \
    "KarpenterControllerResourceDiscoveryPolicy-${CLUSTER_NAME}"; do
    POL_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/${pol}"
    if echo "$ATTACHED" | grep -q "$pol"; then
        echo "  ✓ $pol attached"
    else
        warn "Attaching missing policy $pol to $CONTROLLER_ROLE"
        aws iam attach-role-policy \
            --role-name "$CONTROLLER_ROLE" \
            --policy-arn "$POL_ARN" \
            || warn "Failed to attach $POL_ARN (may not exist yet)"
    fi
done

# Warn on subnet-not-found in logs (transient, but worth surfacing).
if kubectl -n "${KARPENTER_NAMESPACE}" logs \
        -l app.kubernetes.io/name=karpenter --since=2m 2>/dev/null \
        | grep -qi "no subnets found"; then
    warn "Karpenter logged 'no subnets found' — tags may not have propagated; waiting 30s"
    sleep 30
fi
ok "Karpenter controller verified"

echo ""

###################################################
## PHASE 4.1: KARPENTER NODECLASS + NODEPOOL     ##
###################################################
echo "============================================"
echo " Phase 4.1: Karpenter EC2NodeClass + NodePool"
echo "============================================"

# ── Render workload node userdata ─────────────────────────────────────────────
# The userdata script is rendered with its specific variables first, then
# injected into the EC2NodeClass template (which handles the remaining vars).
WORKLOAD_UD_TEMPLATE="$ROOT_DIR/userdata/workload-node.template.sh"
WORKLOAD_UD_OUT="${WORKLOAD_UD_TEMPLATE/.template/}"
echo "Rendering workload node userdata..."
envsubst '${ARTIFACTS_S3_BUCKET} ${EBS_IOPS} ${EBS_THROUGHPUT} ${EFS_ID} ${AWS_DEFAULT_REGION} ${AWS_ACCOUNT_ID} ${ECR_IMAGE_REGION}' \
    < "$WORKLOAD_UD_TEMPLATE" > "$WORKLOAD_UD_OUT"

# ── Apply EC2NodeClass ────────────────────────────────────────────────────────
# Process karpenter-nodeclass.template.yaml in two passes:
#   Pass 1: inject indented userdata in place of the __WORKLOAD_USERDATA__ marker
#   Pass 2: envsubst for all remaining template variables
NODECLASS_TEMPLATE="$ROOT_DIR/yamls/karpenter-nodeclass.template.yaml"
NODECLASS_RENDERED="${NODECLASS_TEMPLATE/.template/}"
echo "Rendering EC2NodeClass..."
# Indent userdata by 4 spaces so it embeds correctly under `userData: |`
INDENTED_UD=$(sed 's/^/    /' "$WORKLOAD_UD_OUT")
# Inject userdata: replace the placeholder line with the indented script
awk -v ud="$INDENTED_UD" '
    /^    __WORKLOAD_USERDATA__$/ { print ud; next }
    { print }
' "$NODECLASS_TEMPLATE" \
| envsubst '${CLUSTER_NAME} ${ALIAS_VERSION} ${EBS_IOPS} ${EBS_THROUGHPUT}' \
> "$NODECLASS_RENDERED"
kubectl apply -f "$NODECLASS_RENDERED"
ok "EC2NodeClass 'workload' applied"

# ── Generate and apply NodePool via update-nodepool-types.sh ──────────────────
echo "Generating Karpenter NodePool 'workload' with eligible instance types..."
"${ROOT_DIR}/update-nodepool-types.sh" "${ROOT_DIR}/env.variables" \
    || die "Failed to generate/apply Karpenter NodePool (see output above)"
ok "Karpenter NodePool 'workload' applied"

echo ""

###############
## PHASE 5: EFS (optional) ##
###############
echo "============================================"
echo " Phase 5: EFS shared storage (optional)"
echo "============================================"

if [ "${USE_EFS}" = "true" ]; then
    # ── Create EFS filesystem if EFS_ID not already set ───────────────────────
    if [ -z "${EFS_ID:-}" ]; then
        echo "Creating new EFS filesystem in VPC $VPC_ID..."
        # Command: aws efs create-file-system
        # Output: {"FileSystemId":"fs-...","LifeCycleState":"creating",...}
        # Parse:  --query FileSystemId --output text → "fs-..."
        EFS_ID=$(aws efs create-file-system \
            --region "$AWS_DEFAULT_REGION" \
            --creation-token "${CLUSTER_NAME}-efs" \
            --encrypted \
            --tags "Key=Name,Value=${CLUSTER_NAME}-efs" \
                   "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" \
            --query FileSystemId --output text)
        ok "EFS filesystem created: $EFS_ID"
        # Write EFS_ID back to env.variables for re-runs and the destroy script.
        sed -i "s|^EFS_ID=.*|EFS_ID=\"${EFS_ID}\"|" "$ROOT_DIR/env.variables"
        export EFS_ID
    else
        ok "Re-using existing EFS filesystem: $EFS_ID"
    fi

    # ── Install EFS CSI driver addon ──────────────────────────────────────────
    echo "Installing EFS CSI driver add-on..."
    # Command: aws eks create-addon (or update-addon if already installed)
    # --resolve-conflicts OVERWRITE ensures addon is always up-to-date.
    # Output: {"addon":{"addonName":"aws-efs-csi-driver","status":"CREATING",...}}
    aws eks create-addon \
        --cluster-name "${CLUSTER_NAME}" \
        --region "${AWS_DEFAULT_REGION}" \
        --addon-name aws-efs-csi-driver \
        --resolve-conflicts OVERWRITE 2>/dev/null || \
    aws eks update-addon \
        --cluster-name "${CLUSTER_NAME}" \
        --region "${AWS_DEFAULT_REGION}" \
        --addon-name aws-efs-csi-driver \
        --resolve-conflicts OVERWRITE

    # Poll addon status.
    # Command: aws eks describe-addon
    # Output: {"addon":{"status":"ACTIVE"|"CREATING"|"DEGRADED"|"FAILED",...}}
    # Parse:  --query 'addon.status' --output text
    ADDON_STATUS=""
    for i in $(seq 1 36); do
        ADDON_STATUS=$(aws eks describe-addon \
            --cluster-name "${CLUSTER_NAME}" \
            --region "${AWS_DEFAULT_REGION}" \
            --addon-name aws-efs-csi-driver \
            --query 'addon.status' --output text 2>/dev/null || echo "")
        [[ "$ADDON_STATUS" == "ACTIVE" ]] && { ok "EFS CSI Driver add-on ACTIVE"; break; }
        [[ "$ADDON_STATUS" == "FAILED" ]] && die "EFS CSI Driver add-on FAILED"
        echo "  attempt $i/36: addon status=$ADDON_STATUS — waiting 10s..."
        sleep 10
    done
    [[ "$ADDON_STATUS" == "ACTIVE" || "$ADDON_STATUS" == "DEGRADED" ]] \
        || warn "EFS CSI Driver status $ADDON_STATUS after wait; proceeding anyway"

    # Scale efs-csi-controller to 1 replica (the default of 2 exhausts the
    # single system node's CPU requests on a t4g.medium).
    kubectl patch deployment efs-csi-controller -n kube-system \
        -p '{"spec":{"replicas":1}}' 2>/dev/null || true

    # Apply EFS StorageClass, PV, and PVC from template.
    apply_template "$ROOT_DIR/yamls/efs-setup.template.yaml" \
        '${EFS_ID} ${TES_NAMESPACE}'
    ok "EFS StorageClass, PV, PVC created"

    # Apply efs-node-mount DaemonSet (mounts EFS on each worker node's host).
    apply_template "$ROOT_DIR/yamls/efs-node-mount.template.yaml" \
        '${EFS_ID} ${AWS_DEFAULT_REGION} ${TES_NAMESPACE}'
    ok "efs-node-mount DaemonSet applied"

    # ── EFS mount targets and security groups ─────────────────────────────────
    echo "Configuring EFS security groups and mount targets..."
    # Find Karpenter node security group (tagged at cluster creation).
    # Command: aws ec2 describe-security-groups
    # Filter:  karpenter.sh/discovery=<cluster>
    # Output:  {"SecurityGroups":[{"GroupId":"sg-...","VpcId":"vpc-..."},...]}
    # Parse:   --query 'SecurityGroups[0].GroupId' --output text
    NODE_SG=$(aws ec2 describe-security-groups \
        --region "${AWS_DEFAULT_REGION}" \
        --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
    [ -z "$NODE_SG" ] && die "Cannot find Karpenter node security group (tag: karpenter.sh/discovery=${CLUSTER_NAME})"

    # Create a dedicated EFS mount security group.
    # Command: aws ec2 create-security-group
    # Output:  {"GroupId":"sg-..."}
    # Parse:   --query 'GroupId' --output text
    # Note:    returns error if SG already exists (non-fatal; fetch existing).
    MOUNT_SG=$(aws ec2 create-security-group \
        --group-name "efs-mount-sg-${CLUSTER_NAME}" \
        --description "EFS mount targets for ${CLUSTER_NAME}" \
        --vpc-id "$VPC_ID" \
        --region "$AWS_DEFAULT_REGION" \
        --query 'GroupId' --output text 2>/dev/null || echo "")
    if [ -z "$MOUNT_SG" ]; then
        # Fetch existing SG.
        # Command: aws ec2 describe-security-groups
        # Filter:  group-name + vpc-id
        # Parse:   --query 'SecurityGroups[0].GroupId' --output text
        MOUNT_SG=$(aws ec2 describe-security-groups \
            --region "$AWS_DEFAULT_REGION" \
            --filters "Name=group-name,Values=efs-mount-sg-${CLUSTER_NAME}" \
                      "Name=vpc-id,Values=$VPC_ID" \
            --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
        [ -z "$MOUNT_SG" ] && MOUNT_SG="$NODE_SG" && \
            warn "Could not create/find EFS mount SG; falling back to node SG"
    fi

    # Allow NFS (TCP 2049) from NODE_SG to MOUNT_SG.
    # Command: aws ec2 authorize-security-group-ingress
    # Note:    returns error if rule already exists (non-fatal; || true).
    if [[ "$MOUNT_SG" != "$NODE_SG" ]]; then
        aws ec2 authorize-security-group-ingress \
            --region "${AWS_DEFAULT_REGION}" \
            --group-id "$MOUNT_SG" \
            --ip-permissions \
            "[{\"IpProtocol\":\"tcp\",\"FromPort\":2049,\"ToPort\":2049,\"UserIdGroupPairs\":[{\"GroupId\":\"$NODE_SG\"}]}]" \
            2>/dev/null || true

        # Also allow from the EKS cluster SG (covers the managed baseline nodegroup).
        # Command: aws ec2 describe-security-groups
        # Filter:  aws:eks:cluster-name=<cluster> + group-name=eks-cluster-sg-<cluster>-*
        CLUSTER_SG=$(aws ec2 describe-security-groups \
            --region "${AWS_DEFAULT_REGION}" \
            --filters "Name=tag:aws:eks:cluster-name,Values=${CLUSTER_NAME}" \
                      "Name=group-name,Values=eks-cluster-sg-${CLUSTER_NAME}-*" \
            --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
        if [ -n "$CLUSTER_SG" ] && [ "$CLUSTER_SG" != "None" ]; then
            aws ec2 authorize-security-group-ingress \
                --region "${AWS_DEFAULT_REGION}" \
                --group-id "$MOUNT_SG" \
                --ip-permissions \
                "[{\"IpProtocol\":\"tcp\",\"FromPort\":2049,\"ToPort\":2049,\"UserIdGroupPairs\":[{\"GroupId\":\"$CLUSTER_SG\"}]}]" \
                2>/dev/null || true
        fi
    fi

    # Create EFS mount targets in each private subnet.
    # Command: aws ec2 describe-subnets
    # Filter:  vpc-id=<vpc> + map-public-ip-on-launch=false
    # Output:  {"Subnets":[{"SubnetId":"subnet-..."},...]}
    # Parse:   --query 'Subnets[].[SubnetId]' --output text → one per line
    PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
        --region "$AWS_DEFAULT_REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" \
                  "Name=map-public-ip-on-launch,Values=false" \
        --query 'Subnets[].[SubnetId]' --output text 2>/dev/null || echo "")
    [ -z "$PRIVATE_SUBNETS" ] && die "No private subnets found in VPC $VPC_ID"

    for subnet in $PRIVATE_SUBNETS; do
        # Command: aws efs create-mount-target
        # Note:    non-fatal if mount target already exists in this subnet.
        aws efs create-mount-target \
            --file-system-id "$EFS_ID" \
            --subnet-id "$subnet" \
            --security-groups "$MOUNT_SG" \
            --region "$AWS_DEFAULT_REGION" 2>/dev/null \
            || echo "  ✓ Mount target for $subnet may already exist"
    done
    ok "EFS mount targets created"

    # Set EFS worker mount variables for configmap template rendering.
    export EFS_WORKER_MOUNT="
                - name: efs-data
                  mountPath: /mnt/efs"
    export EFS_WORKER_VOLUME="
              - name: efs-data
                persistentVolumeClaim:
                  claimName: efs-pvc"
    export EFS_NERDCTL_MOUNT="--volume /mnt/efs:/mnt/efs:rw "

else
    warn "USE_EFS is not 'true' — skipping EFS provisioning"
    export EFS_WORKER_MOUNT=""
    export EFS_WORKER_VOLUME=""
    export EFS_NERDCTL_MOUNT=""
fi

echo ""

###########################
## PHASE 6: LOAD BALANCER #
###########################
echo "============================================"
echo " Phase 6: AWS Load Balancer Controller"
echo "============================================"
# Install the AWS Load Balancer Controller for TES Ingress (ALB).
# Uses IRSA via eksctl iamserviceaccount.

# Apply LB controller CRDs from the eks-charts GitHub repo.
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"

# Create the IAM policy (idempotent — fetch ARN if it already exists).
# Command: aws iam create-policy
# Output: {"Policy":{"Arn":"arn:aws:iam::123456789012:policy/AWSLoadBalancerControllerIAMPolicy",...}}
# Parse:  --query 'Policy.Arn' --output text
LB_POLICY_ARN=$(aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://"${ROOT_DIR}/policies/AWSLoadBalancerControllerIAMPolicy.json" \
    --query 'Policy.Arn' --output text 2>/dev/null || echo "")
if [ -z "$LB_POLICY_ARN" ]; then
    # Policy already exists — fetch its ARN.
    # Command: aws iam list-policies
    # Output: {"Policies":[{"PolicyName":"...","Arn":"..."},...]}
    # Parse:  --query "Policies[?PolicyName=='...'].Arn" --output text
    LB_POLICY_ARN=$(aws iam list-policies \
        --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].Arn" \
        --output text 2>/dev/null || echo "")
    [ -z "$LB_POLICY_ARN" ] && die "Cannot retrieve ARN for AWSLoadBalancerControllerIAMPolicy"
    ok "AWSLoadBalancerControllerIAMPolicy already exists: $LB_POLICY_ARN"
else
    ok "AWSLoadBalancerControllerIAMPolicy created: $LB_POLICY_ARN"
fi

# Create IRSA service account for the LB controller.
# Command: eksctl create iamserviceaccount
# Note:    --approve skips the confirmation prompt.
eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" \
    --region "$AWS_DEFAULT_REGION" \
    --namespace kube-system \
    --name aws-load-balancer-controller \
    --attach-policy-arn "$LB_POLICY_ARN" \
    --approve

# Install the LB controller Helm chart.
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --version 3.0.0 \
    -n kube-system \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=false \
    --set region="$AWS_DEFAULT_REGION" \
    --set vpcId="$VPC_ID" \
    --set serviceAccount.name=aws-load-balancer-controller
# Command: kubectl wait deployment <name> --for=condition=Available
# Timeout: 600s (controller must download and start before proceeding)
kubectl -n kube-system wait deployment aws-load-balancer-controller \
    --for=condition=Available --timeout=600s
ok "AWS Load Balancer Controller installed"

echo ""

#########
## PHASE 7: TES / FUNNEL ##
#########
echo "============================================"
echo " Phase 7: TES / Funnel deployment"
echo "============================================"

# Update kubeconfig to ensure it is current.
# Command: aws eks update-kubeconfig --name <cluster> --region <region>
# Output: "Updated context <arn> in <kubeconfig path>"
aws eks update-kubeconfig \
    --name "$CLUSTER_NAME" \
    --region "$AWS_DEFAULT_REGION"

# ── IAM role for Funnel IRSA ───────────────────────────────────────────────────
# Resolve OIDC provider ID (last path component of the OIDC issuer URL).
# Command: aws eks describe-cluster --query 'cluster.identity.oidc.issuer'
# Output:  --output text → "https://oidc.eks.eu-north-1.amazonaws.com/id/ABCD1234"
# Parse:   cut -d'/' -f5 → "ABCD1234"
OIDC_ID=$(aws eks describe-cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_DEFAULT_REGION}" \
    --query 'cluster.identity.oidc.issuer' --output text \
    | cut -d'/' -f5)
export OIDC_ID
echo "OIDC provider ID: $OIDC_ID"

if aws iam get-role --role-name "${TES_ROLE_NAME}" >/dev/null 2>&1; then
    ok "IAM role already exists: ${TES_ROLE_NAME}"
else
    echo "Creating IAM role for Funnel IRSA..."
    mkdir -p "${ROOT_DIR}/tmp"
    # Render trust policy from template (no inline JSON in installer).
    envsubst '${AWS_PARTITION} ${AWS_ACCOUNT_ID} ${AWS_DEFAULT_REGION} ${OIDC_ID} ${TES_NAMESPACE}' \
        < "${ROOT_DIR}/policies/iam-trust-policy.template.json" \
        > "${ROOT_DIR}/tmp/tes-trust-policy.json"
    # Command: aws iam create-role
    # Output: {"Role":{"Arn":"arn:aws:iam::...","RoleName":"..."},...}
    aws iam create-role \
        --role-name "${TES_ROLE_NAME}" \
        --assume-role-policy-document file://"${ROOT_DIR}/tmp/tes-trust-policy.json"
    ok "IAM role created: ${TES_ROLE_NAME}"
fi

# ── S3 permissions for Funnel IRSA ────────────────────────────────────────────
# Build IAM policy statements dynamically based on TES_S3_BUCKET, READ_BUCKETS,
# and WRITE_BUCKETS, then render using the template.
echo "Attaching S3 permissions to ${TES_ROLE_NAME}..."
mkdir -p "${ROOT_DIR}/tmp"

# Helper: convert comma-separated bucket names to JSON ARN pairs.
# Input:  "foo,bar*"
# Output: "arn:aws:s3:::foo","arn:aws:s3:::foo/*","arn:aws:s3:::bar*","arn:aws:s3:::bar*/*"
bucket_arns_json() {
    local list="$1" first=true b
    local -a buckets
    IFS=',' read -ra buckets <<< "$list"
    for b in "${buckets[@]}"; do
        b="${b// /}"
        [[ -z "$b" ]] && continue
        $first || printf ','
        printf '"arn:%s:s3:::%s","arn:%s:s3:::%s/*"' \
            "$AWS_PARTITION" "$b" "$AWS_PARTITION" "$b"
        first=false
    done
}

# Statement 1 — TES bucket: full access always
TES_S3_STATEMENTS=$(cat <<-JSON
    {
      "Sid": "TESBucketFullAccess",
      "Effect": "Allow",
      "Action": ["s3:PutObject","s3:GetObject","s3:DeleteObject","s3:ListBucket"],
      "Resource": [
        "arn:${AWS_PARTITION}:s3:::${TES_S3_BUCKET}",
        "arn:${AWS_PARTITION}:s3:::${TES_S3_BUCKET}/*"
      ]
    }
JSON
)

# Statement 2 — optional extra read-only buckets
if [ -n "${READ_BUCKETS:-}" ]; then
    read_arns=$(bucket_arns_json "$READ_BUCKETS")
    TES_S3_STATEMENTS+=$(cat <<-JSON

    ,{
      "Sid": "AdditionalBucketsReadOnly",
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:ListBucket","s3:GetBucketLocation"],
      "Resource": [${read_arns}]
    }
JSON
    )
fi

# Statement 3 — optional extra write buckets
if [ -n "${WRITE_BUCKETS:-}" ]; then
    write_arns=$(bucket_arns_json "$WRITE_BUCKETS")
    TES_S3_STATEMENTS+=$(cat <<-JSON

    ,{
      "Sid": "AdditionalBucketsWrite",
      "Effect": "Allow",
      "Action": ["s3:PutObject","s3:GetObject","s3:DeleteObject","s3:ListBucket","s3:GetBucketLocation"],
      "Resource": [${write_arns}]
    }
JSON
    )
fi

export TES_S3_STATEMENTS
envsubst '${TES_S3_STATEMENTS}' \
    < "${ROOT_DIR}/policies/tes-s3-policy.template.json" \
    > "${ROOT_DIR}/tmp/tes-policy.json"
# Command: aws iam put-role-policy (idempotent inline policy)
aws iam put-role-policy \
    --role-name "${TES_ROLE_NAME}" \
    --policy-name "${CLUSTER_NAME}-tes-policy" \
    --policy-document file://"${ROOT_DIR}/tmp/tes-policy.json"
ok "S3 permissions attached"

# ── Create TES S3 bucket ───────────────────────────────────────────────────────
if aws s3 ls "s3://${TES_S3_BUCKET}" >/dev/null 2>&1; then
    ok "S3 bucket already exists: ${TES_S3_BUCKET}"
else
    echo "Creating S3 bucket: ${TES_S3_BUCKET}"
    # Command: aws s3 mb s3://<bucket> --region <region>
    # Output: "make_bucket: <bucket>"
    aws s3 mb "s3://${TES_S3_BUCKET}" --region "${AWS_DEFAULT_REGION}"
    # Block all public access.
    aws s3api put-public-access-block \
        --bucket "${TES_S3_BUCKET}" \
        --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    ok "S3 bucket created: ${TES_S3_BUCKET}"
fi

# ── Apply Funnel Kubernetes resources ─────────────────────────────────────────
# All resources are rendered from templates in yamls/ using envsubst.
# FUND_VARS lists all variables that appear in the Funnel templates.
# Variables NOT in this list (e.g. Go template syntax {{.TaskId}}) are left
# untouched, preventing accidental expansion of task-level variables.
FUND_VARS='${TES_NAMESPACE} ${TES_S3_BUCKET} ${AWS_DEFAULT_REGION} ${ECR_IMAGE_REGION} ${FUNNEL_IMAGE} ${FUNNEL_PORT} ${TES_ROLE_NAME} ${EFS_WORKER_MOUNT} ${EFS_WORKER_VOLUME} ${EFS_NERDCTL_MOUNT} ${BOOTSTRAP_NG} ${AWS_ACCOUNT_ID} ${AWS_PARTITION}'

for yaml in funnel-namespace funnel-serviceaccount funnel-rbac funnel-crds \
            funnel-deployment funnel-tes-service tes-ingress-alb \
            funnel-configmap ecr-auth-refresh; do
    echo "Applying $yaml..."
    in_yaml="$ROOT_DIR/yamls/${yaml}.template.yaml"
    out_yaml="${in_yaml/.template/}"
    # envsubst only expands the listed FUND_VARS; sed restores __DOLLAR__ escapes
    # used in templates to protect literal '$' chars from envsubst.
    envsubst "$FUND_VARS" < "$in_yaml" | sed 's/__DOLLAR__/\$/g' > "$out_yaml"
    kubectl apply -f "$out_yaml"
done

# ── Wait for Funnel pods ────────────────────────────────────────────────────────
echo "Waiting for Funnel pods to be Ready (10 min)..."
kubectl wait \
    --namespace "${TES_NAMESPACE}" \
    --for=condition=Ready pods \
    --all \
    --timeout=600s
ok "Funnel deployment complete"

# ── External access ────────────────────────────────────────────────────────────
if [ -n "${EXTERNAL_IP:-}" ]; then
    echo "EXTERNAL_IP=${EXTERNAL_IP} set — configuring security groups..."
    # Pass EXTERNAL_IP as UZA_PUBLIC_IP for the external access script.
    AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION" \
    CLUSTER_NAME="$CLUSTER_NAME" \
    UZA_PUBLIC_IP="$EXTERNAL_IP" \
    "$ROOT_DIR/setup_external_access.sh" \
        || warn "setup_external_access.sh failed — configure SGs manually"
else
    warn "EXTERNAL_IP not set — skipping security-group configuration"
fi

echo ""
ok "Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Retrieve the TES endpoint:"
echo "     kubectl -n ${TES_NAMESPACE} get ingress tes-ingress"
echo "  2. Configure Cromwell tes.conf to point at the TES endpoint"
echo "  3. Submit a test task: funnel task run hello.json"
