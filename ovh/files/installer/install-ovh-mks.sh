#!/bin/bash
# ============================================================
# OVHcloud MKS Installer — Cromwell + Funnel TES platform
# Region: GRA9 | MKS Free plan | Cluster Autoscaler built-in
# ============================================================
# Usage:
#   micromamba activate ovh   # or: micromamba run -n ovh bash
#   cd OVH_installer/installer
#   ./install-ovh-mks.sh
#
# Prerequisites in the 'ovh' micromamba environment:
#   ovhcloud   — OVHcloud CLI  (ovhcloud login done beforehand)
#   openstack  — OpenStack CLI (OS_* env vars sourced from RC file)
#   kubectl    — Kubernetes CLI
#   helm       — Helm 3
#   envsubst   — from gettext package
# ============================================================
set -euo pipefail

export ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
retry_kubectl() {
    local yaml_file="$1"
    local max_attempts=5
    local delay=10
    local attempt=1
    until kubectl apply -f "$yaml_file"; do
        if [ $attempt -ge $max_attempts ]; then
            die "Failed to apply $yaml_file after $max_attempts attempts"
        fi
        warn "Retrying $yaml_file in $delay seconds (attempt $attempt)..."
        sleep $delay
        attempt=$((attempt+1))
    done
}

# Poll ovhcloud for a resource status until it matches expected value.
# Usage: wait_for_status <poll_cmd> <expected_status> <timeout_sec> <label>
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

# Generate OVH API HMAC-SHA1 signature for direct API calls.
# Usage: ovh_api_sig <method> <full_url> <body> <app_secret> <consumer_key> <timestamp>
# Returns the X-Ovh-Signature header value (prefixed with '$1$' as required by OVH API).
ovh_api_sig() {
    local method="$1" full_url="$2" body="$3" app_secret="$4" consumer_key="$5" timestamp="$6"
    # OVH signature: "$1$" + SHA1(appSecret + '+' + consumerKey + '+' + METHOD + '+' + fullUrl + '+' + body + '+' + timestamp)
    local to_sign="${app_secret}+${consumer_key}+${method}+${full_url}+${body}+${timestamp}"
    local sig
    sig="\$1\$$(echo -n "$to_sign" | sha1sum | awk '{print $1}')"
    
    # Debug output
    echo "[DEBUG] OVH API Signature Construction:" >&2
    echo "[DEBUG]   Timestamp: $timestamp" >&2
    echo "[DEBUG]   Method: $method" >&2
    echo "[DEBUG]   Full URL: $full_url" >&2
    echo "[DEBUG]   Body length: ${#body}" >&2
    if [ ${#body} -lt 500 ]; then
        echo "[DEBUG]   Body: $body" >&2
    else
        echo "[DEBUG]   Body (first 500 chars): ${body:0:500}..." >&2
    fi
    echo "[DEBUG]   String to sign (first 200 chars): ${to_sign:0:200}..." >&2
    echo "[DEBUG]   Generated signature: $sig" >&2
    
    echo "$sig"
}

# Make a direct OVH API call (bypasses ovhcloud CLI to avoid default injection).
# Usage: ovh_api_call <method> <url_path> <body_file> <app_key> <app_secret> <consumer_key> [label]
# Returns the response body on success; dies on HTTP error.
ovh_api_call() {
    local method="$1" url_path="$2" body_file="$3" app_key="$4" app_secret="$5" consumer_key="$6" label="${7:-API call}"
    
    # Single timestamp — must be identical in both the signature and the header.
    # Use OVH server time to avoid issues when the local clock drifts; fall back to local.
    local timestamp
    timestamp=$(curl -s --max-time 5 https://api.ovh.com/1.0/auth/time 2>/dev/null || date +%s)
    
    local body=""
    if [ -f "$body_file" ]; then
        body=$(cat "$body_file")
    fi
    
    # OVH signs the full URL, not just the path.
    local full_url="https://api.ovh.com/1.0${url_path}"
    
    local sig
    sig=$(ovh_api_sig "$method" "$full_url" "$body" "$app_secret" "$consumer_key" "$timestamp")
    
    # Debug output for API call
    echo "[DEBUG] OVH API Call Details:" >&2
    echo "[DEBUG]   Full URL: $full_url" >&2
    echo "[DEBUG]   App Key: ${app_key:0:10}..." >&2
    echo "[DEBUG]   Consumer Key: ${consumer_key:0:10}..." >&2
    echo "[DEBUG]   X-Ovh-Timestamp: $timestamp" >&2
    echo "[DEBUG]   X-Ovh-Signature: $sig" >&2
    
    local response http_code
    response=$(curl -s --max-time 30 -w "\n%{http_code}" -X "$method" \
        "$full_url" \
        -H "X-Ovh-Application: $app_key" \
        -H "X-Ovh-Consumer: $consumer_key" \
        -H "X-Ovh-Timestamp: $timestamp" \
        -H "X-Ovh-Signature: $sig" \
        -H "Content-Type: application/json" \
        $([ -f "$body_file" ] && echo "-d @$body_file" || true) 2>&1)
    
    http_code=$(echo "$response" | tail -n1)
    local body_response=$(echo "$response" | sed '$d')
    
    echo "[DEBUG] HTTP Response Code: $http_code" >&2
    echo "[DEBUG] Response Body: $body_response" >&2
    
    if [[ "$http_code" =~ ^(200|201|202)$ ]]; then
        echo "$body_response"
        return 0
    else
        die "$label failed with HTTP $http_code: $body_response"
    fi
}

# Load OVH API credentials from ~/.ovh.conf (created by 'ovhcloud login' in prerequisites).
# The ovhcloud CLI stores credentials in INI format; parse the [default] section.
load_ovh_credentials() {
    local conf_file="${HOME}/.ovh.conf"
    if [ ! -f "$conf_file" ]; then
        die "OVH credentials not found at $conf_file. Run: ovhcloud login"
    fi
    
    # Extract credentials from [default] section
    OVH_APP_KEY=$(grep -A10 '^\[default\]' "$conf_file" | grep '^application_key' | cut -d'=' -f2 | xargs)
    OVH_APP_SECRET=$(grep -A10 '^\[default\]' "$conf_file" | grep '^application_secret' | cut -d'=' -f2 | xargs)
    OVH_CONSUMER_KEY=$(grep -A10 '^\[default\]' "$conf_file" | grep '^consumer_key' | cut -d'=' -f2 | xargs)
    
    if [ -z "$OVH_APP_KEY" ] || [ -z "$OVH_APP_SECRET" ] || [ -z "$OVH_CONSUMER_KEY" ]; then
        die "Failed to parse OVH credentials from $conf_file. Ensure [default] section has application_key, application_secret, and consumer_key."
    fi
    
    export OVH_APP_KEY OVH_APP_SECRET OVH_CONSUMER_KEY
    ok "OVH API credentials loaded from $conf_file"
}

############################
## PHASE 0: ENV + PREREQS ##
############################
echo "============================================"
echo " Phase 0: Environment check & prerequisites"
echo "============================================"

# Load env variables
if [ ! -f "$ROOT_DIR/env.variables" ]; then
    die "env.variables file not found at $ROOT_DIR/env.variables"
fi
set -a
source "$ROOT_DIR/env.variables"
set +a

# Load OVH API credentials from ~/.ovh.conf (prerequisite: ovhcloud login)
load_ovh_credentials

# Verify required variables
REQUIRED_VARS=(
    OVH_PROJECT_ID
    OVH_REGION
    K8S_CLUSTER_NAME
    K8S_VERSION
    SYSTEM_FLAVOR
    WORKER_FAMILIES
    FLAVOR_LOOKUP_REGION
    OVH_VCPU_QUOTA
    OVH_RAM_QUOTA_GB
    WORKER_MAX_VCPU
    WORKER_MAX_RAM_GB
    TES_NAMESPACE
    FUNNEL_IMAGE
    FUNNEL_PORT
    KARPENTER_OVH_IMAGE
    KARPENTER_OVH_TAG
    OVH_S3_ENDPOINT
    OVH_S3_REGION
    OVH_S3_BUCKET
    FILE_STORAGE_SIZE
    FILE_STORAGE_SHARE_NAME
    FILE_STORAGE_SHARE_TYPE
    NFS_MOUNT_PATH
    EXTERNAL_IP
    READ_BUCKETS
    WORK_DIR_INITIAL_GB
    WORK_DIR_EXPAND_GB
    WORK_DIR_EXPAND_THRESHOLD
    WORK_DIR_MIN_FREE_GB
    WORK_DIR_POLL_INTERVAL_SEC
    CINDER_VOLUME_TYPE
    CINDER_STORAGE_CLASS
)
for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR:-}" ]; then
        die "$VAR is not set. Check env.variables."
    fi
done

# Verify required CLI tools
for tool in ovhcloud kubectl helm envsubst openstack; do
    if ! command -v "$tool" &>/dev/null; then
        die "'$tool' not found in PATH. Run: micromamba activate ovh"
    fi
done
ok "All CLI tools found"

# Verify ovhcloud is authenticated (will error if not logged in)
ovhcloud cloud project list -o json >/dev/null 2>&1 \
    || die "ovhcloud is not authenticated. Run: ovhcloud login"
ok "ovhcloud authenticated"

# Verify OpenStack credentials are available (required for Manila NFS in Phase 3)
if [ -z "${OS_CLOUD:-}" ]; then
    die "No OpenStack credentials found. Manila NFS (Phase 3) requires:
  export OS_CLOUD=ovh-gra9      (uses ~/.config/openstack/clouds.yaml)"
fi
ok "OpenStack credentials detected"

echo ""

###############################
## PHASE 1: CREATE MKS CLUSTER
###############################
echo "============================================"
echo " Phase 1: Create MKS cluster"
echo "============================================"

# ── 1a. Create private Neutron network (required for MKS cluster + Manila NFS)
# The private network MUST exist before cluster creation; it is immutable after.
# All Karpenter-created node pools automatically inherit it — no extra config needed.
PRIV_NET_NAME="${PRIV_NET_NAME:-tes-private-net}"

echo "Checking for existing private network '${PRIV_NET_NAME}'..."
# The list response is a flat array: each element has top-level 'region',
# 'status', 'openstackId' and 'id' fields (NOT a nested 'regions' sub-array).
# [{"id":"pn-...","name":"...","openstackId":"...","region":"GRA9","status":"ACTIVE",...}]
EXISTING_NET=$(ovhcloud cloud network private list \
    --cloud-project "${OVH_PROJECT_ID}" -o json 2>/dev/null \
    | python3 -c "
import sys, json
nets = json.load(sys.stdin)
if isinstance(nets, dict) and 'details' in nets: nets = nets.get('details', [])
if not isinstance(nets, list): nets = [nets]
for n in nets:
    if n.get('name') == '${PRIV_NET_NAME}' \
            and n.get('region') == '${OVH_REGION}' \
            and n.get('status') in ('ACTIVE', 'CREATED'):
        print(n.get('openstackId',''), n.get('id',''))
        break
" 2>/dev/null || true)

if [ -n "${EXISTING_NET:-}" ]; then
    PRIV_NET_OPENSTACK_ID=$(echo "${EXISTING_NET}" | awk '{print $1}')
    PRIV_NET_ID=$(echo "${EXISTING_NET}"           | awk '{print $2}')
    warn "Private network '${PRIV_NET_NAME}' already exists (OpenStack ID: ${PRIV_NET_OPENSTACK_ID})"
else
    echo "Creating private network '${PRIV_NET_NAME}' in ${OVH_REGION}..."
    # --wait blocks until the operation completes; -o json returns only {"name":"..."}
    # (no id/openstackId in the create response). Re-list immediately after to get IDs.
    ovhcloud cloud network private create "${OVH_REGION}" \
        --cloud-project "${OVH_PROJECT_ID}" \
        --name "${PRIV_NET_NAME}" \
        --wait 2>/dev/null \
        || die "Failed to create private network '${PRIV_NET_NAME}'"

    # Fetch IDs from the list endpoint (same query used for existing-network detection above)
    _NEW_NET=$(ovhcloud cloud network private list \
        --cloud-project "${OVH_PROJECT_ID}" -o json 2>/dev/null \
        | python3 -c "
import sys, json
nets = json.load(sys.stdin)
if isinstance(nets, dict) and 'details' in nets: nets = nets.get('details', [])
if not isinstance(nets, list): nets = [nets]
for n in nets:
    if n.get('name') == '${PRIV_NET_NAME}' \
            and n.get('region') == '${OVH_REGION}' \
            and n.get('status') in ('ACTIVE', 'CREATED'):
        print(n.get('openstackId',''), n.get('id',''))
        break
" 2>/dev/null || true)
    [ -z "${_NEW_NET:-}" ] && die "Network '${PRIV_NET_NAME}' created but could not be found in list (unexpected state)"
    PRIV_NET_OPENSTACK_ID=$(echo "${_NEW_NET}" | awk '{print $1}')
    PRIV_NET_ID=$(echo "${_NEW_NET}"           | awk '{print $2}')

    # openstackId may not be assigned immediately after creation (OVH provisioning lag).
    # Retry the list until we get a proper UUID in openstackId (max ~2 min).
    if [ -z "${PRIV_NET_OPENSTACK_ID:-}" ] || echo "${PRIV_NET_OPENSTACK_ID}" | grep -qvE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
        echo "openstackId not yet available — waiting for OVH to assign UUID to network..."
        for _i in $(seq 1 24); do
            sleep 5
            _RETRY=$(ovhcloud cloud network private list \
                --cloud-project "${OVH_PROJECT_ID}" -o json 2>/dev/null \
                | python3 -c "
import sys, json
nets = json.load(sys.stdin)
if isinstance(nets, dict) and 'details' in nets: nets = nets.get('details', [])
if not isinstance(nets, list): nets = [nets]
for n in nets:
    if n.get('name') == '${PRIV_NET_NAME}' \
            and n.get('region') == '${OVH_REGION}':
        oid = n.get('openstackId') or ''
        print(oid, n.get('id',''))
        break
" 2>/dev/null || true)
            _RETRY_UUID=$(echo "${_RETRY}" | awk '{print $1}')
            if echo "${_RETRY_UUID:-}" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
                PRIV_NET_OPENSTACK_ID="${_RETRY_UUID}"
                PRIV_NET_ID=$(echo "${_RETRY}" | awk '{print $2}')
                break
            fi
            echo "  [${_i}/24] openstackId not yet set — retrying in 5s..."
        done
        echo "${PRIV_NET_OPENSTACK_ID:-}" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
            || die "openstackId never became a valid UUID for network '${PRIV_NET_NAME}'. Got: '${PRIV_NET_OPENSTACK_ID:-<empty>}'"
    fi
    ok "Private network created: ${PRIV_NET_OPENSTACK_ID}"

    # Create subnet as a separate step — ovhcloud network private create does not
    # support --subnet-* flags; subnet creation is a distinct API call.
    # The subnet create command uses the region-based OVH API which requires the
    # OpenStack UUID (openstackId) as the network ID — NOT the pn-... OVH ID.
    # Do NOT use --enable-gateway-ip: gateway is set manually to .253 below so
    # the OVH CCM uses the correct address.
    echo "Creating subnet 'tes-private-subnet' in network ${PRIV_NET_OPENSTACK_ID}..."
    SUBNET_JSON=$(ovhcloud cloud network private subnet create "${PRIV_NET_OPENSTACK_ID}" \
        --cloud-project "${OVH_PROJECT_ID}" \
        --region "${OVH_REGION}" \
        --name "tes-private-subnet" \
        --cidr "192.168.100.0/24" \
        --ip-version 4 \
        --enable-dhcp \
        -o json 2>/dev/null)
    # subnet create response: { "details": { "id": "<uuid>", "cidr": "...", ... } }
    PRIV_SUBNET_FROM_CREATE=$(echo "${SUBNET_JSON}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if isinstance(d, dict) and 'details' in d: d = d['details']
print(d.get('id',''))
" 2>/dev/null || true)
    [ -n "${PRIV_SUBNET_FROM_CREATE:-}" ] \
        && ok "Subnet created: ${PRIV_SUBNET_FROM_CREATE}" \
        || warn "Subnet creation may have failed — will fall back to OpenStack CLI for subnet lookup"
fi

# intermediate export of what we have so far
export PRIV_NET_ID PRIV_NET_OPENSTACK_ID



# Get the subnet's OpenStack ID (needed for --nodes-subnet-id on cluster create)
# Priority:
#   1. Extracted from the create response (new network just created this run)
#   2. Already set in env.variables from a previous run (idempotent re-run)
#   3. Fall back to openstack CLI (requires OS_CLOUD / openstack auth)
if [ -n "${PRIV_SUBNET_FROM_CREATE:-}" ]; then
    PRIV_SUBNET_OPENSTACK_ID="${PRIV_SUBNET_FROM_CREATE}"
    ok "Subnet resolved from create response: ${PRIV_SUBNET_OPENSTACK_ID}"
elif [ -n "${PRIV_SUBNET_OPENSTACK_ID:-}" ]; then
    ok "Subnet resolved from env.variables: ${PRIV_SUBNET_OPENSTACK_ID}"
else
    echo "Resolving subnet for private network ${PRIV_NET_OPENSTACK_ID}..."
    PRIV_SUBNET_OPENSTACK_ID=$(openstack subnet list \
        --network "${PRIV_NET_OPENSTACK_ID}" \
        -c ID -f value 2>/dev/null | head -1 || true)
    [ -z "${PRIV_SUBNET_OPENSTACK_ID:-}" ] && die "Cannot resolve subnet for private network ${PRIV_NET_OPENSTACK_ID}. Check clouds.yaml / openstack auth."
    ok "Subnet resolved via OpenStack CLI: ${PRIV_SUBNET_OPENSTACK_ID}"
fi
# export the subnet id
export PRIV_SUBNET_OPENSTACK_ID

# Ensure the subnet has a gateway_ip reserved for the OVH Octavia LoadBalancer.
# OVHcloud's CCM requires a gateway_ip on the cluster subnet to auto-provision
# an OVHcloud Gateway (OpenStack router) and attach a Floating IP to any
# LoadBalancer service. Without it, all LoadBalancer services stay <pending>.
#
# `ovhcloud cloud network private subnet create` (without --enable-gateway-ip)
# creates the subnet without a gateway_ip (gateway_ip: None). We fix this
# post-creation using the OpenStack CLI by reserving the last usable IP (.253)
# as the gateway and shrinking the DHCP allocation pool to .1-.252. The CCM
# will auto-create the OVHcloud Gateway at this IP the first time a
# LoadBalancer service is created.

echo "Checking if subnet ${PRIV_SUBNET_OPENSTACK_ID} has a gateway_ip..."
SUBNET_GW=$(openstack subnet show "${PRIV_SUBNET_OPENSTACK_ID}" \
    -f value -c gateway_ip 2>/dev/null || echo "")
if [ -z "${SUBNET_GW:-}" ] || [ "${SUBNET_GW}" = "None" ]; then
    warn "Subnet has no gateway_ip — reserving 192.168.100.253 for OVHcloud Gateway (required for LoadBalancer)..."
    # Clear the allocation pool first (can't set gateway if .253 is in pool)
    openstack subnet set --no-allocation-pool "${PRIV_SUBNET_OPENSTACK_ID}" 2>/dev/null || true
    openstack subnet set --gateway 192.168.100.253 "${PRIV_SUBNET_OPENSTACK_ID}" 2>/dev/null \
        || die "Failed to set gateway_ip on subnet ${PRIV_SUBNET_OPENSTACK_ID}"
    # Restore the allocation pool excluding the reserved gateway IP
    openstack subnet set \
        --allocation-pool start=192.168.100.1,end=192.168.100.252 \
        "${PRIV_SUBNET_OPENSTACK_ID}" 2>/dev/null \
        || die "Failed to restore allocation pool on subnet ${PRIV_SUBNET_OPENSTACK_ID}"
    ok "Subnet gateway_ip set to 192.168.100.253 (DHCP pool: .1-.252)"
else
    ok "Subnet already has gateway_ip: ${SUBNET_GW}"
fi

# Persist private network IDs to env.variables for idempotency on re-runs and
# so the destroy script can reference them without live API calls.
sed -i "s|^PRIV_NET_ID=.*|PRIV_NET_ID=\"${PRIV_NET_ID}\"|"  "$ROOT_DIR/env.variables"
sed -i "s|^PRIV_NET_OPENSTACK_ID=.*|PRIV_NET_OPENSTACK_ID=\"${PRIV_NET_OPENSTACK_ID}\"|" "$ROOT_DIR/env.variables"
sed -i "s|^PRIV_SUBNET_OPENSTACK_ID=.*|PRIV_SUBNET_OPENSTACK_ID=\"${PRIV_SUBNET_OPENSTACK_ID}\"|" "$ROOT_DIR/env.variables"
sed -i "s|^PRIV_NET_NAME=.*|PRIV_NET_NAME=\"${PRIV_NET_NAME}\"|" "$ROOT_DIR/env.variables"
ok "Private network IDs persisted to env.variables"

echo ""

# ── 1b. Create or reuse MKS cluster
# Check if cluster already exists
EXISTING_ID=$(ovhcloud cloud kube list \
    --cloud-project "${OVH_PROJECT_ID}" -o json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, dict) and 'details' in data: data = data['details']
if not isinstance(data, list):
    data = [data]
for c in data:
    if c.get('name') == '${K8S_CLUSTER_NAME}':
        print(c['id'])
        break
" 2>/dev/null || true)

if [ -n "${EXISTING_ID:-}" ]; then
    warn "Cluster '${K8S_CLUSTER_NAME}' already exists (id: ${EXISTING_ID}). Skipping creation."
    KUBE_ID="$EXISTING_ID"
else
    echo "Creating MKS cluster '${K8S_CLUSTER_NAME}' in ${OVH_REGION} (K8s ${K8S_VERSION})..."
    KUBE_ID=$(ovhcloud cloud kube create \
        --cloud-project "${OVH_PROJECT_ID}" \
        --name "${K8S_CLUSTER_NAME}" \
        --region "${OVH_REGION}" \
        --version "${K8S_VERSION}" \
        --private-network-id "${PRIV_NET_OPENSTACK_ID}" \
        --nodes-subnet-id "${PRIV_SUBNET_OPENSTACK_ID}" \
        -o json 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
# CLI may return top-level id OR wrap it under 'details'
print(d.get('id','') or d.get('details', {}).get('id',''))
" \
        || true)

    if [ -z "${KUBE_ID:-}" ]; then
        die "Failed to create cluster or retrieve cluster ID"
    fi
    ok "Cluster created: ${KUBE_ID}"
fi

export KUBE_ID

# Persist KUBE_ID back to env.variables for future runs
sed -i "s|^KUBE_ID=.*|KUBE_ID=\"${KUBE_ID}\"|" "$ROOT_DIR/env.variables"

# Wait for cluster to be READY
wait_for_status \
    "ovhcloud cloud kube get --cloud-project ${OVH_PROJECT_ID} ${KUBE_ID} -o status" \
    "READY" 900 "MKS cluster"

# Download kubeconfig
echo "Downloading kubeconfig to ${KUBECONFIG_PATH}..."
mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
ovhcloud cloud kube kubeconfig generate "${KUBE_ID}" \
    --cloud-project "${OVH_PROJECT_ID}" \
    -o json 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
# kubeconfig YAML is in 'message' field (CLI wraps it in {message:..., details:...})
kube = d.get('message','') or d.get('details',{}).get('content','')
sys.stdout.write(kube if kube.endswith('\n') else kube+'\n')
" > "${KUBECONFIG_PATH}"
export KUBECONFIG="${KUBECONFIG_PATH}"
ok "Kubeconfig saved: ${KUBECONFIG_PATH}"

# Basic connectivity test
kubectl cluster-info --request-timeout=30s >/dev/null \
    || die "kubectl cannot connect to cluster. Check kubeconfig."
ok "kubectl connected to cluster"

echo ""

###############################
## PHASE 2: CREATE NODE POOLS
###############################
echo "============================================"
echo " Phase 2: Create node pools"
echo "============================================"

create_nodepool_if_absent() {
    local name="$1" flavor="$2" desired="$3" min="$4" max="$5" autoscale="$6" label="${7:-$1}" required="${8:-false}"

    local exists
    exists=$(ovhcloud cloud kube nodepool list "${KUBE_ID}" \
        --cloud-project "${OVH_PROJECT_ID}" \
        -o json 2>/dev/null \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, dict) and 'details' in data: data = data['details']
if not isinstance(data, list): data = [data]
print('yes' if any(p.get('name') == '${name}' for p in data) else '')
" 2>/dev/null || echo "")

    if [ -n "$exists" ]; then
        warn "Node pool '${name}' already exists. Skipping."
        return
    fi

    echo "Creating node pool '${name}' (flavor: ${flavor}, min: ${min}, max: ${max})..."

    # Render nodepool.template.json via envsubst and make direct OVH API call.
    # This bypasses the ovhcloud CLI entirely, avoiding the cobra defaults injection
    # issue that causes "attachFloatingIps must be null or unset" 422 errors.
    # Direct API call only sends the exact JSON we build — no defaults injected.
    local tmp_params
    tmp_params=$(mktemp --suffix=.json)
    POOL_NAME="${name}" \
    POOL_FLAVOR="${flavor}" \
    POOL_DESIRED="${desired}" \
    POOL_MIN="${min}" \
    POOL_MAX="${max}" \
    POOL_AUTOSCALE="$([ "${autoscale}" = "true" ] && echo true || echo false)" \
    POOL_LABEL="${label}" \
    envsubst '${POOL_NAME} ${POOL_FLAVOR} ${POOL_DESIRED} ${POOL_MIN} ${POOL_MAX} ${POOL_AUTOSCALE} ${POOL_LABEL}' \
        < "$ROOT_DIR/yamls/nodepool.template.json" > "$tmp_params"
    
    # Minify JSON to compact format (no unnecessary whitespace).
    # OVH API signature verification requires the exact bytes being sent,
    # so we need consistent compact JSON for both signing and transmission.
    python3 -m json.tool --compact "$tmp_params" > "${tmp_params}.compact" 2>/dev/null || \
        python3 -c "import json, sys; json.dump(json.load(open('$tmp_params')), sys.stdout)" > "${tmp_params}.compact"
    mv "${tmp_params}.compact" "$tmp_params"

    local create_out
    local api_path="/cloud/project/${OVH_PROJECT_ID}/kube/${KUBE_ID}/nodepool"
    
    create_out=$(ovh_api_call "POST" "$api_path" "$tmp_params" \
        "${OVH_APP_KEY}" "${OVH_APP_SECRET}" "${OVH_CONSUMER_KEY}" \
        "Create node pool '${name}'" 2>&1) || {
        rm -f "$tmp_params"
        if echo "$create_out" | grep -qi 'UnavailableFlavor'; then
            warn "Skipping pool '${name}': flavor '${flavor}' is not available in this region."
        elif [ "${required}" = "true" ]; then
            die "Failed to create required node pool '${name}': ${create_out}"
        else
            warn "Skipping pool '${name}' (non-fatal): ${create_out}"
        fi
        return
    }
    rm -f "$tmp_params"
    ok "Node pool '${name}' created"
}

# Fetch the full flavor list once — Phase 2.2 (Karpenter NodePool generation)
# re-uses this variable so we avoid a duplicate API call.
echo "Fetching available flavors (region: ${FLAVOR_LOOKUP_REGION})..."
FLAVORS_JSON=$(ovhcloud cloud reference list-flavors \
    --cloud-project "${OVH_PROJECT_ID}" \
    --region "${FLAVOR_LOOKUP_REGION}" \
    -o json 2>/dev/null)
if [ -z "${FLAVORS_JSON:-}" ]; then
    die "Failed to fetch flavor list from OVH API (region: ${FLAVOR_LOOKUP_REGION})"
fi

#############################################
## PHASE 2.1: KARPENTER SYSTEM NODE        ##
#############################################
echo "============================================"
echo " Phase 2.1: Karpenter system node"
echo "============================================"

# system pool: fixed 1 node — hosts kube-system + Funnel server pod.
# Worker nodes are managed entirely by Karpenter ; no per-flavor
# nodepools are pre-created here.
create_nodepool_if_absent "system" "${SYSTEM_FLAVOR}" 1 1 1 "false" "system" "true"

# Wait for system node to be Ready (Funnel pod needs somewhere to land)
echo "Waiting for system node pool to scale up (1 node)..."
for i in $(seq 1 40); do
    READY=$(kubectl get nodes -l nodepool=system --no-headers 2>/dev/null \
        | grep -c " Ready " || true)
    if [ "${READY}" -ge 1 ]; then
        ok "System node is Ready"
        break
    fi
    echo "  [attempt $i/40] Waiting for system node..."
    sleep 15
done

echo ""

#############################################
## PHASE 2.2: KARPENTER NODE AUTOSCALER    ##
#############################################
echo "============================================"
echo " Phase 2.2: Karpenter node autoscaler"
echo "============================================"

# Auto-provision Karpenter OVH API credentials if not already set.
# Strategy:
#   1. Read the app_key + app_secret that ovhcloud CLI already stored locally
#      (tries YAML and INI config formats across common locations).
#   2. POST to OVH /auth/credential with scoped access rules → gets a
#      pending consumerKey + a one-time browser validation URL.
#   3. Pause and wait for the user to open the URL and click Authorise.
#   4. Persist all three values to env.variables — future runs skip this block.
# On re-runs with credentials already set, they are validated via a live OVH API call.
# A 403 response (consumer key not yet browser-validated or expired) causes the
# credentials to be cleared automatically so the provisioning block re-runs below.
if [ -n "${KARPENTER_APP_KEY:-}" ] && [ -n "${KARPENTER_APP_SECRET:-}" ] && [ -n "${KARPENTER_CONSUMER_KEY:-}" ]; then
    echo "Validating existing Karpenter API credentials against OVH API..."
    _KARP_VALIDATE=$(python3 - \
            "${KARPENTER_APP_KEY}" \
            "${KARPENTER_APP_SECRET}" \
            "${KARPENTER_CONSUMER_KEY}" \
            "${OVH_PROJECT_ID}" \
            "${KUBE_ID}" <<'KARP_VAL_EOF'
import hashlib, time, urllib.request, urllib.error, sys

app_key, app_secret, consumer_key, project_id, kube_id = sys.argv[1:]
api_root = 'https://eu.api.ovh.com/1.0'
url      = f'{api_root}/cloud/project/{project_id}/kube/{kube_id}/nodepool'
# Use OVH server time to avoid clock-skew signature rejections
try:
    svr = urllib.request.urlopen(f'{api_root}/auth/time', timeout=5).read()
    now = svr.decode().strip()
except Exception:
    now = str(int(time.time()))

sig_str   = "+".join([app_secret, consumer_key, "GET", url, "", now])
signature = "$1$" + hashlib.sha1(sig_str.encode("utf-8")).hexdigest()
req = urllib.request.Request(url, headers={
    "X-Ovh-Application": app_key,
    "X-Ovh-Consumer":    consumer_key,
    "X-Ovh-Timestamp":   now,
    "X-Ovh-Signature":   signature,
})
try:
    urllib.request.urlopen(req, timeout=10)
    print("OK")
except urllib.error.HTTPError as e:
    print("INVALID" if e.code == 403 else f"ERROR:{e.code}")
except Exception as e:
    print(f"ERROR:{e}")
KARP_VAL_EOF
    ) || _KARP_VALIDATE="ERROR:python"
    if [ "${_KARP_VALIDATE}" = "INVALID" ]; then
        warn "Karpenter consumer key is invalid (403 — not yet browser-validated or expired)."
        warn "Clearing credentials and re-provisioning..."
        KARPENTER_APP_KEY=""
        KARPENTER_APP_SECRET=""
        KARPENTER_CONSUMER_KEY=""
        sed -i 's|^KARPENTER_APP_KEY=.*|KARPENTER_APP_KEY=""|'           "$ROOT_DIR/env.variables"
        sed -i 's|^KARPENTER_APP_SECRET=.*|KARPENTER_APP_SECRET=""|'     "$ROOT_DIR/env.variables"
        sed -i 's|^KARPENTER_CONSUMER_KEY=.*|KARPENTER_CONSUMER_KEY=""|' "$ROOT_DIR/env.variables"
    elif echo "${_KARP_VALIDATE}" | grep -q '^ERROR:'; then
        warn "Could not validate Karpenter credentials (${_KARP_VALIDATE}) — proceeding with existing values."
    else
        ok "Karpenter API credentials validated successfully."
    fi
fi
if [ -z "${KARPENTER_APP_KEY:-}" ] || [ -z "${KARPENTER_APP_SECRET:-}" ] || [ -z "${KARPENTER_CONSUMER_KEY:-}" ]; then
    echo "Karpenter credentials not set — auto-provisioning from ovhcloud CLI config..."

    KARP_CREDS=$(python3 - "${OVH_PROJECT_ID}" "${KUBE_ID}" <<'PYEOF'
import json, os, sys, urllib.request, urllib.error, configparser, re

project_id = sys.argv[1]
kube_id    = sys.argv[2]

def find_credentials():
    """Return (app_key, app_secret, endpoint) by scanning ovhcloud CLI config files."""

    # ── YAML configs (newer ovhcloud CLI, stores appKey / appSecret) ──────────
    yaml_paths = [
        os.path.expanduser("~/.config/ovhcloud/ovhcloud.yaml"),
        os.path.expanduser("~/.config/ovhcloud/config.yaml"),
        os.path.expanduser("~/.ovhcloud.yaml"),
    ]
    for path in yaml_paths:
        if not os.path.exists(path):
            continue
        cfg = {}
        try:
            with open(path) as f:
                for line in f:
                    m = re.match(r'^(\w+)\s*:\s*["\']?([^"\'#\n]+)["\']?\s*$', line.strip())
                    if m:
                        cfg[m.group(1).lower()] = m.group(2).strip()
        except OSError:
            continue
        ak  = cfg.get('appkey')    or cfg.get('app_key')    or cfg.get('application_key')
        ase = cfg.get('appsecret') or cfg.get('app_secret') or cfg.get('application_secret')
        ep  = cfg.get('endpoint', 'ovh-eu')
        if ak and ase:
            return ak, ase, ep

    # ── INI configs (go-ovh SDK / legacy ~/.ovh.conf) ─────────────────────────
    ini_paths = [
        os.path.expanduser("~/.ovh.conf"),
        os.path.expanduser("~/.config/ovh/ovh.conf"),
        "/etc/ovh.conf",
    ]
    for path in ini_paths:
        if not os.path.exists(path):
            continue
        cfg = configparser.RawConfigParser()
        try:
            cfg.read(path)
        except configparser.Error:
            continue
        for section in (['default'] + cfg.sections()):
            if not cfg.has_section(section):
                continue
            ak  = cfg.get(section, 'application_key',    fallback=None)
            ase = cfg.get(section, 'application_secret', fallback=None)
            ep  = cfg.get(section, 'endpoint',           fallback='ovh-eu')
            if ak and ase:
                return ak, ase, ep

    return None, None, 'ovh-eu'

app_key, app_secret, endpoint = find_credentials()
if not app_key:
    print("NOTFOUND")
    sys.exit(1)

api_root = {
    'ovh-eu': 'https://eu.api.ovh.com/1.0',
    'ovh-ca': 'https://ca.api.ovh.com/1.0',
    'ovh-us': 'https://us.api.ovh.com/1.0',
}.get(endpoint, 'https://eu.api.ovh.com/1.0')

access_rules = [
    {"method": "GET",    "path": f"/cloud/project/{project_id}/kube/{kube_id}"},
    {"method": "GET",    "path": f"/cloud/project/{project_id}/kube/{kube_id}/nodepool"},
    {"method": "GET",    "path": f"/cloud/project/{project_id}/kube/{kube_id}/nodepool/*"},
    {"method": "POST",   "path": f"/cloud/project/{project_id}/kube/{kube_id}/nodepool"},
    {"method": "PUT",    "path": f"/cloud/project/{project_id}/kube/{kube_id}/nodepool/*"},
    {"method": "DELETE", "path": f"/cloud/project/{project_id}/kube/{kube_id}/nodepool/*"},
    {"method": "GET",    "path": f"/cloud/project/{project_id}/kube/{kube_id}/flavors"},
    {"method": "GET",    "path": f"/cloud/project/{project_id}/kube/{kube_id}/node"},
    {"method": "GET",    "path": f"/cloud/project/{project_id}/capabilities/kube/regions"},
    {"method": "GET",    "path": f"/cloud/project/{project_id}/capabilities/kube/flavors"},
    {"method": "GET",    "path": f"/cloud/project/{project_id}/flavor"},
]

body = json.dumps({"accessRules": access_rules}).encode()
req  = urllib.request.Request(
    f"{api_root}/auth/credential",
    data=body,
    headers={"Content-Type": "application/json", "X-Ovh-Application": app_key},
    method="POST",
)
try:
    resp = json.loads(urllib.request.urlopen(req, timeout=15).read())
except urllib.error.HTTPError as e:
    print(f"APIERROR: HTTP {e.code} — {e.read().decode()}")
    sys.exit(1)
except Exception as e:
    print(f"APIERROR: {e}")
    sys.exit(1)

print(f"APP_KEY={app_key}")
print(f"APP_SECRET={app_secret}")
print(f"CONSUMER_KEY={resp['consumerKey']}")
print(f"VALIDATION_URL={resp['validationUrl']}")
PYEOF
    ) || true

    # Detect failure modes from the Python script
    if [ -z "${KARP_CREDS:-}" ] || echo "${KARP_CREDS}" | grep -qE '^(NOTFOUND|APIERROR)'; then
        die "Could not auto-provision Karpenter credentials.
  The ovhcloud CLI config was not found or did not contain app_key/app_secret.
  Create a token manually (set validity to 'Unlimited') at:
    https://api.ovh.com/createToken/?GET=/cloud/project/${OVH_PROJECT_ID}/kube/${KUBE_ID}&GET=/cloud/project/${OVH_PROJECT_ID}/kube/${KUBE_ID}/nodepool&GET=/cloud/project/${OVH_PROJECT_ID}/kube/${KUBE_ID}/nodepool/*&POST=/cloud/project/${OVH_PROJECT_ID}/kube/${KUBE_ID}/nodepool&PUT=/cloud/project/${OVH_PROJECT_ID}/kube/${KUBE_ID}/nodepool/*&DELETE=/cloud/project/${OVH_PROJECT_ID}/kube/${KUBE_ID}/nodepool/*&GET=/cloud/project/${OVH_PROJECT_ID}/kube/${KUBE_ID}/flavors&GET=/cloud/project/${OVH_PROJECT_ID}/kube/${KUBE_ID}/node&GET=/cloud/project/${OVH_PROJECT_ID}/capabilities/kube/regions&GET=/cloud/project/${OVH_PROJECT_ID}/capabilities/kube/flavors&GET=/cloud/project/${OVH_PROJECT_ID}/flavor
  Then set KARPENTER_APP_KEY, KARPENTER_APP_SECRET, KARPENTER_CONSUMER_KEY in env.variables and re-run."
    fi

    KARPENTER_APP_KEY=$(echo "${KARP_CREDS}"     | grep '^APP_KEY='        | cut -d= -f2-)
    KARPENTER_APP_SECRET=$(echo "${KARP_CREDS}"  | grep '^APP_SECRET='     | cut -d= -f2-)
    KARPENTER_CONSUMER_KEY=$(echo "${KARP_CREDS}"| grep '^CONSUMER_KEY='   | cut -d= -f2-)
    KARP_VALIDATION_URL=$(echo "${KARP_CREDS}"   | grep '^VALIDATION_URL=' | cut -d= -f2-)

    echo ""
    echo "  ┌──────────────────────────────────────────────────────────────────┐"
    echo "  │  Karpenter API token created — one browser step required:        │"
    echo "  │                                                                  │"
    printf "  │  %s\n  │\n" "${KARP_VALIDATION_URL}"
    echo "  │  1. Open the URL above in your browser                           │"
    echo "  │  2. Log in with your OVH account and click  Authorise            │"
    echo "  │  3. Come back here and press Enter                               │"
    echo "  └──────────────────────────────────────────────────────────────────┘"
    echo ""
    read -r -p "  Press Enter once you have authorised in the browser... "

    # Persist to env.variables — future runs will see keys already set and skip
    sed -i "s|^KARPENTER_APP_KEY=.*|KARPENTER_APP_KEY=\"${KARPENTER_APP_KEY}\"|"         "$ROOT_DIR/env.variables"
    sed -i "s|^KARPENTER_APP_SECRET=.*|KARPENTER_APP_SECRET=\"${KARPENTER_APP_SECRET}\"|" "$ROOT_DIR/env.variables"
    sed -i "s|^KARPENTER_CONSUMER_KEY=.*|KARPENTER_CONSUMER_KEY=\"${KARPENTER_CONSUMER_KEY}\"|" "$ROOT_DIR/env.variables"
    ok "Karpenter API credentials provisioned and saved to env.variables"
fi

# Create karpenter namespace
kubectl create namespace karpenter --dry-run=client -o yaml | kubectl apply -f -

# Install Karpenter core CRDs (NodePool + NodeClaim) from the upstream project.
# These are the standard types used by all Karpenter providers.
echo "Applying Karpenter core CRDs..."
KARPENTER_CRD_BASE="https://raw.githubusercontent.com/kubernetes-sigs/karpenter/main/pkg/apis/crds"
kubectl apply -f "${KARPENTER_CRD_BASE}/karpenter.sh_nodepools.yaml"
kubectl apply -f "${KARPENTER_CRD_BASE}/karpenter.sh_nodeclaims.yaml"
ok "Karpenter core CRDs applied"

# Create the OVH API credentials Secret in the karpenter namespace.
# The Karpenter controller reads applicationKey/applicationSecret/consumerKey
# from this secret to manage nodepools via the OVH API.
echo "Creating ovh-credentials Secret..."
kubectl create secret generic ovh-credentials \
    -n karpenter \
    --from-literal=applicationKey="${KARPENTER_APP_KEY}" \
    --from-literal=applicationSecret="${KARPENTER_APP_SECRET}" \
    --from-literal=consumerKey="${KARPENTER_CONSUMER_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f -
ok "ovh-credentials Secret applied"

# Install Karpenter OVH provider via Helm.
# The chart is not published to a Helm registry so we download the repo archive.
# We use helm upgrade --install (not install) so re-runs work even when a
# previous attempt left the release in 'failed' state.
# --wait is intentionally omitted here: on a fresh cluster the image pull can
# take longer than any reasonable --timeout, causing a spurious INSTALLATION
# FAILED even though the pod is still starting. We do our own readiness wait
# with kubectl rollout status below.
KARPENTER_RELEASE_STATUS=$(helm status karpenter -n karpenter \
    --kubeconfig "${KUBECONFIG_PATH}" -o json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('info',{}).get('status',''))" \
    2>/dev/null || true)

if [ "${KARPENTER_RELEASE_STATUS}" = "deployed" ]; then
    warn "Karpenter Helm release already deployed. Skipping."
else
    echo "Downloading karpenter-provider-ovhcloud chart from GitHub..."
    KARPENTER_TMP=$(mktemp -d)
    curl -sL \
        "https://github.com/antonin-a/karpenter-provider-ovhcloud/archive/refs/heads/main.tar.gz" \
        | tar xz --strip-components=1 -C "${KARPENTER_TMP}"

    echo "Installing Karpenter OVH provider (Helm)..."
    helm upgrade --install karpenter "${KARPENTER_TMP}/charts" \
        --kubeconfig "${KUBECONFIG_PATH}" \
        --namespace karpenter \
        --set ovh.serviceName="${OVH_PROJECT_ID}" \
        --set ovh.kubeId="${KUBE_ID}" \
        --set ovh.region="${OVH_REGION}" \
        --set ovh.endpoint="ovh-eu" \
        --set "nodeSelector.nodepool=system" \
        --set image.repository="${KARPENTER_OVH_IMAGE}" \
        --set image.tag="${KARPENTER_OVH_TAG}"
    rm -rf "${KARPENTER_TMP}"
    ok "Karpenter Helm chart applied"
fi

# Wait for the Karpenter deployment to become available (separate from Helm --wait
# so a slow image pull never poisons the Helm release status).
echo "Waiting for Karpenter deployment to be Ready (timeout 10m)..."
kubectl rollout status deployment \
    -n karpenter \
    --timeout=600s \
    || die "Karpenter deployment did not become ready. Check: kubectl describe pods -n karpenter"
ok "Karpenter installed in namespace 'karpenter'"

# Apply OVHNodeClass — describes the OVH-specific config (project, cluster, region).
# The OVHNodeClass CRD is installed automatically by the Helm chart above.
echo "Applying OVHNodeClass 'default'..."
envsubst '${OVH_PROJECT_ID} ${KUBE_ID} ${OVH_REGION}' \
    < "$ROOT_DIR/yamls/karpenter-nodeclass.template.yaml" \
    | kubectl apply -f -
ok "OVHNodeClass 'default' applied"

# Generate and apply Karpenter NodePool — delegate to the standalone utility script
# (single source of truth for flavor filtering + NodePool generation).
echo "Generating Karpenter NodePool 'workers' with available flavors..."
"${ROOT_DIR}/update-nodepool-flavors.sh" "${ROOT_DIR}/env.variables" \
    || die "Failed to generate/apply Karpenter NodePool (see output above)"
ok "Karpenter NodePool 'workers' applied"

# Disable MKS Cluster Autoscaler on worker nodepools.
# Karpenter is now the sole autoscaler; leaving MKS CA enabled would cause
# conflicts (both would try to scale the same nodepools simultaneously).
echo "Disabling MKS Cluster Autoscaler on worker nodepools..."
WORKER_POOL_DATA=$(ovhcloud cloud kube nodepool list "${KUBE_ID}" \
    --cloud-project "${OVH_PROJECT_ID}" \
    -o json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, dict) and 'details' in data: data = data['details']
if not isinstance(data, list): data = [data]
for p in data:
    if p.get('name','').startswith('workers-') and p.get('autoscale', False):
        print(p['id'], p['name'])
" 2>/dev/null || true)

if [ -z "${WORKER_POOL_DATA:-}" ]; then
    warn "No worker pools with autoscale=true found (already disabled or none exist)."
else
    while IFS=" " read -r pool_id pool_name; do
        [ -z "${pool_id:-}" ] && continue
        # nodepool edit has no --from-file flag; pass --autoscale=false directly
        ovhcloud cloud kube nodepool edit "${KUBE_ID}" "${pool_id}" \
            --cloud-project "${OVH_PROJECT_ID}" \
            --autoscale=false 2>&1 \
            && ok "  Autoscale disabled: ${pool_name}" \
            || warn "  Could not disable autoscale on '${pool_name}' (id: ${pool_id}) — disable manually via OVH console or API"
    done <<< "$WORKER_POOL_DATA"
fi
ok "Worker pool autoscale check complete"

echo ""


###############################
## PHASE 3: MANILA NFS SHARED STORAGE
###############################
echo "============================================"
echo " Phase 3: Manila NFS shared storage"
echo "============================================"
#
# OVHcloud Manila (File Storage) provides a managed NFS server backed by a
# Ceph cluster.  Share type 'standard-1az' uses DHSS=True — the NFS server is
# provisioned on the private Neutron network created in Phase 1.  The CSI
# driver (openstack-manila-csi) mounts the share read-write-many into every
# Funnel server pod and every Karpenter worker pod.
#
# Prerequisites (all satisfied by the time we reach Phase 3):
#   • Private Neutron network: ${PRIV_NET_OPENSTACK_ID}
#   • Subnet: ${PRIV_SUBNET_OPENSTACK_ID}
#   • OpenStack creds via OS_CLOUD=ovh-gra9 (clouds.yaml)

# ── 3a. Create 'cloud-config' Secret in kube-system from clouds.yaml
# The manila-csi controller + node pods mount this secret at /etc/openstack.
CLOUDS_YAML="${HOME}/.config/openstack/clouds.yaml"
[ ! -f "${CLOUDS_YAML}" ] && die "clouds.yaml not found at ${CLOUDS_YAML}. Cannot install Manila CSI."

# Verify python-manilaclient OSC plugin is installed (provides 'openstack share' commands)
if ! python3 -c "import manilaclient" 2>/dev/null; then
    die "python-manilaclient is not installed in this Python environment.
  The 'openstack share' commands (Manila NFS) require it.
  Install with:  pip install python-manilaclient
  Then retry Phase 3."
fi
ok "python-manilaclient OSC plugin found"

echo "Creating cloud-config Secret in kube-system..."
kubectl create secret generic cloud-config \
    --namespace kube-system \
    --from-file=clouds.yaml="${CLOUDS_YAML}" \
    --dry-run=client -o yaml \
    | kubectl apply -f -
ok "cloud-config Secret applied"

# ── 3a.1 Create manila-csi-secrets in kube-system (OpenStack credentials for
#         static PV nodePublishSecretRef — Manila CSI won't mount without them)
python3 - <<'PYEOF'
import yaml, os, subprocess, json
cloud_name = os.environ.get("OS_CLOUD", "ovh-gra9")
with open(os.path.expanduser("~/.config/openstack/clouds.yaml")) as f:
    clouds = yaml.safe_load(f)
c = clouds["clouds"][cloud_name]
a = c["auth"]
secret_data = {
    "os-authURL":    a.get("auth_url", ""),
    "os-region":     c.get("region_name", ""),
    "os-userName":   a.get("username", ""),
    "os-password":   a.get("password", ""),
    "os-projectID":  a.get("project_id", ""),
    "os-domainName": a.get("user_domain_name", "Default"),
}
args = ["kubectl", "create", "secret", "generic", "manila-csi-secrets",
        "--namespace", "kube-system", "--dry-run=client", "-o", "yaml"]
for k, v in secret_data.items():
    args += ["--from-literal", f"{k}={v}"]
manifest = subprocess.check_output(args)
subprocess.run(["kubectl", "apply", "-f", "-"], input=manifest, check=True)
print("manila-csi-secrets applied in kube-system")
PYEOF
ok "manila-csi-secrets Secret applied"

# ── 3b. Install standalone csi-driver-nfs (NFS node plugin for Manila proxy)
# The openstack-manila-csi chart is a Manila-to-NFS proxy: it forwards actual
# NFS mount/unmount operations to the STANDALONE csi-driver-nfs DaemonSet via
# the Unix socket at /var/lib/kubelet/plugins/csi-nfsplugin/csi.sock.
# IMPORTANT: do NOT use cloud-provider-openstack/openstack-manila-csi here —
# that chart creates the same CSIDriver as the manila-csi release and will
# conflict. Use the official csi-driver-nfs chart from kubernetes-csi.
echo "Adding Helm repos for CSI drivers..."
helm repo add csi-driver-nfs \
    https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts 2>/dev/null || true
helm repo add cloud-provider-openstack \
    https://kubernetes.github.io/cloud-provider-openstack 2>/dev/null || true
helm repo update 2>/dev/null || true

# Uninstall any previous csi-driver-nfs release — earlier installer versions
# may have used the wrong chart (cloud-provider-openstack/openstack-manila-csi).
helm uninstall csi-driver-nfs -n kube-system 2>/dev/null || true

echo "Installing csi-driver-nfs (standalone NFS CSI node plugin)..."
helm upgrade --install csi-driver-nfs \
    csi-driver-nfs/csi-driver-nfs \
    --kubeconfig "${KUBECONFIG_PATH}" \
    -n kube-system \
    --set node.livenessProbe.resources.requests.cpu=5m \
    --set node.livenessProbe.resources.requests.memory=10Mi \
    --set node.livenessProbe.resources.limits.memory=32Mi \
    --set node.nodeDriverRegistrar.resources.requests.cpu=5m \
    --set node.nodeDriverRegistrar.resources.requests.memory=10Mi \
    --set node.nodeDriverRegistrar.resources.limits.memory=32Mi \
    --set node.nfs.resources.requests.cpu=5m \
    --set node.nfs.resources.requests.memory=10Mi \
    --set node.nfs.resources.limits.memory=64Mi \
    --wait --timeout 5m
ok "csi-driver-nfs installed (socket: /var/lib/kubelet/plugins/csi-nfsplugin/csi.sock)"

# ── 3c. Install openstack-manila-csi Helm chart
# This is the Manila CSI controller+node proxy. It translates Manila NFS share
# operations into actual NFS mounts by forwarding to the csi-nfsplugin socket
# installed above. Disable the embedded csi-nfs subchart since we use the
# standalone csi-driver-nfs release instead.
echo "Installing openstack-manila-csi Helm chart..."
# Remove stale/failed manila-csi release and conflicting cluster-scoped resources
# so the install starts from a clean slate (idempotent).
helm uninstall manila-csi -n kube-system 2>/dev/null || true
kubectl delete csidriver nfs.manila.csi.openstack.org 2>/dev/null || true
kubectl delete clusterrole    openstack-manila-csi-controllerplugin \
    openstack-manila-csi-nodeplugin 2>/dev/null || true
kubectl delete clusterrolebinding openstack-manila-csi-controllerplugin \
    openstack-manila-csi-nodeplugin 2>/dev/null || true

# fill csi-values.template.yaml with actual values from env.variables and install the chart
yaml_in=${ROOT_DIR}/yamls/manila-csi-values.template.yaml
yaml_out=${yaml_in/.template.yaml/.yaml}
envsubst < "$yaml_in" > "$yaml_out" || die "Failed to render manila-csi-values.yaml"

helm upgrade --install manila-csi \
    cloud-provider-openstack/openstack-manila-csi \
    --kubeconfig "${KUBECONFIG_PATH}" \
    -n kube-system \
    --set csi-nfs.enabled=false \
    -f "$yaml_out" \
    --wait --timeout 8m
ok "Manila CSI driver installed"

# Patch Manila CSI nodeplugin DaemonSet to add an init container that waits for
# the NFS CSI socket before starting. This eliminates the race condition where
# the Manila nodeplugin crashes (exit 255) on fresh nodes because the NFS CSI
# plugin socket (/var/lib/kubelet/plugins/csi-nfsplugin/csi.sock) does not yet
# exist. The volume nfs-fwd-plugin-dir is already defined in the DaemonSet.
echo "Patching Manila nodeplugin to wait for NFS CSI socket on node startup..."
kubectl patch daemonset -n kube-system manila-csi-openstack-manila-csi-nodeplugin \
  --type=json -p='[{
    "op": "add",
    "path": "/spec/template/spec/initContainers",
    "value": [{
      "name": "wait-for-nfs-csi-socket",
      "image": "busybox:1.36",
      "command": ["sh", "-c", "until [ -S /var/lib/kubelet/plugins/csi-nfsplugin/csi.sock ]; do echo \"$(date) waiting for NFS CSI socket...\"; sleep 2; done; echo \"$(date) NFS CSI socket ready.\""],
      "volumeMounts": [{"name": "nfs-fwd-plugin-dir", "mountPath": "/var/lib/kubelet/plugins/csi-nfsplugin"}]
    }]
  }]' \
  || warn "Manila nodeplugin patch failed (may already be applied)"
ok "Manila nodeplugin patched: init container will wait for NFS CSI socket"

# Apply Manila StorageClass
# Render template (substitutes FILE_STORAGE_SHARE_TYPE) then apply.
envsubst '${FILE_STORAGE_SHARE_TYPE}' \
    < "$ROOT_DIR/yamls/manila-storageclass.template.yaml" \
    | kubectl apply -f -
ok "StorageClass applied (manila-nfs)"

# ── 3d. Create share network (ties Manila to our private Neutron network)
SHARE_NET_NAME="tes-share-network"
echo "Checking for existing share network '${SHARE_NET_NAME}'..."
EXISTING_SHARE_NET=$(openstack share network list -c ID -c Name -f value 2>/dev/null \
    | awk -v n="${SHARE_NET_NAME}" '$0 ~ n {print $1}' | head -1 || true)

if [ -n "${EXISTING_SHARE_NET:-}" ]; then
    MANILA_SHARE_NET_ID="${EXISTING_SHARE_NET}"
    warn "Share network '${SHARE_NET_NAME}' already exists (${MANILA_SHARE_NET_ID})"
else
    echo "Creating share network '${SHARE_NET_NAME}'..."
    MANILA_SHARE_NET_ID=$(openstack share network create \
        --neutron-net-id    "${PRIV_NET_OPENSTACK_ID}" \
        --neutron-subnet-id "${PRIV_SUBNET_OPENSTACK_ID}" \
        --name "${SHARE_NET_NAME}" \
        -c id -f value || true)
    [ -z "${MANILA_SHARE_NET_ID:-}" ] && die "Failed to create share network"
    ok "Share network created: ${MANILA_SHARE_NET_ID}"
fi
export MANILA_SHARE_NET_ID
python3 - <<PYEOF
import re
path = '${ROOT_DIR}/env.variables'
val  = '${MANILA_SHARE_NET_ID}'
txt  = open(path).read()
txt  = re.sub(r'^MANILA_SHARE_NET_ID=.*', 'MANILA_SHARE_NET_ID="' + val + '"', txt, flags=re.MULTILINE)
open(path, 'w').write(txt)
PYEOF

# ── 3e. Create Manila NFS share (or reuse existing)
echo "Checking for existing Manila share '${FILE_STORAGE_SHARE_NAME}'..."
EXISTING_SHARE=$(openstack share list -c ID -c Name -f value 2>/dev/null \
    | awk -v n="${FILE_STORAGE_SHARE_NAME}" '$0 ~ n {print $1}' | head -1 || true)

if [ -n "${EXISTING_SHARE:-}" ]; then
    MANILA_SHARE_ID="${EXISTING_SHARE}"
    warn "Manila share '${FILE_STORAGE_SHARE_NAME}' already exists (${MANILA_SHARE_ID})"
else
    echo "Creating Manila NFS share '${FILE_STORAGE_SHARE_NAME}' (${FILE_STORAGE_SIZE} GiB, type: ${FILE_STORAGE_SHARE_TYPE})..."
    MANILA_SHARE_ID=$(openstack share create NFS "${FILE_STORAGE_SIZE}" \
        --name         "${FILE_STORAGE_SHARE_NAME}" \
        --share-type   "${FILE_STORAGE_SHARE_TYPE}" \
        --share-network "${MANILA_SHARE_NET_ID}" \
        -c id -f value 2>/dev/null || true)
    [ -z "${MANILA_SHARE_ID:-}" ] && die "Failed to create Manila share"
    ok "Manila share created: ${MANILA_SHARE_ID} (waiting for 'available' status...)"
fi
export MANILA_SHARE_ID
sed -i "s|^MANILA_SHARE_ID=.*|MANILA_SHARE_ID=\"${MANILA_SHARE_ID}\"|" "$ROOT_DIR/env.variables"

# Wait for share to reach 'available'
echo "Waiting for Manila share ${MANILA_SHARE_ID} to become available (max 10 min)..."
SHARE_READY=false
for i in $(seq 1 40); do
    SHARE_STATUS=$(openstack share show "${MANILA_SHARE_ID}" -c status -f value 2>/dev/null || echo "error")
    if [ "${SHARE_STATUS}" = "available" ]; then
        ok "Manila share is available"
        SHARE_READY=true
        break
    fi
    if [ "${SHARE_STATUS}" = "error" ]; then
        die "Manila share entered error state. Check: openstack share show ${MANILA_SHARE_ID}"
    fi
    echo "  [${i}/40] Share status: ${SHARE_STATUS} — waiting 15s..."
    sleep 15
done
${SHARE_READY} || die "Manila share did not become available within 10 minutes"

# ── 3f. Get NFS export path
# NOTE: the correct subcommand is 'share export location list' (space-separated,
# not hyphenated). Older docs show 'export-location list' which no longer works.
echo "Retrieving NFS export path..."
NFS_EXPORT_PATH=$(openstack share export location list "${MANILA_SHARE_ID}" \
    -c Path -f value 2>/dev/null | grep -v '^$' | head -1 || true)
# Validate: must look like a real NFS path (non-empty, not an error message)
if [ -z "${NFS_EXPORT_PATH:-}" ] || echo "${NFS_EXPORT_PATH}" | grep -qi 'openstack\|error\|not found'; then
    die "Cannot retrieve NFS export path for share ${MANILA_SHARE_ID}. Got: ${NFS_EXPORT_PATH:-<empty>}"
fi
# Strip any stray newlines/whitespace
NFS_EXPORT_PATH=$(echo "${NFS_EXPORT_PATH}" | tr -d '\n\r' | xargs)
ok "NFS export path: ${NFS_EXPORT_PATH}"
export NFS_EXPORT_PATH
# Use python to write the value safely — avoids sed breaking on special chars
python3 -c "
import re, sys
path = '$ROOT_DIR/env.variables'
val  = '''${NFS_EXPORT_PATH}'''
txt  = open(path).read()
txt  = re.sub(r'^NFS_EXPORT_PATH=.*', 'NFS_EXPORT_PATH=\"' + val + '\"', txt, flags=re.MULTILINE)
open(path, 'w').write(txt)
"

# ── 3g. Create access rule (allow all cluster nodes)
echo "Checking for existing access rule on share ${MANILA_SHARE_ID}..."
EXISTING_ACCESS=$(openstack share access list "${MANILA_SHARE_ID}" \
    -c id -c "access to" -c state -f value 2>/dev/null \
    | awk '$0 ~ "0.0.0.0/0" {print $1}' | head -1 || true)

if [ -n "${EXISTING_ACCESS:-}" ]; then
    MANILA_ACCESS_ID="${EXISTING_ACCESS}"
    warn "Access rule already exists (${MANILA_ACCESS_ID})"
else
    echo "Creating IP access rule (0.0.0.0/0 → read-write)..."
    MANILA_ACCESS_ID=$(openstack share access create \
        "${MANILA_SHARE_ID}" ip "0.0.0.0/0" \
        --access-level rw \
        -c id -f value 2>/dev/null || true)
    [ -z "${MANILA_ACCESS_ID:-}" ] && die "Failed to create access rule for share ${MANILA_SHARE_ID}"
    ok "Access rule created: ${MANILA_ACCESS_ID}"
fi
export MANILA_ACCESS_ID
sed -i "s|^MANILA_ACCESS_ID=.*|MANILA_ACCESS_ID=\"${MANILA_ACCESS_ID}\"|" "$ROOT_DIR/env.variables"

ok "Manila NFS phase complete (share: ${MANILA_SHARE_ID}, export: ${NFS_EXPORT_PATH})"
echo ""


###############################
## PHASE 4: S3 BUCKET + CREDS
###############################
echo "============================================"
echo " Phase 4: OVH S3 bucket + credentials"
echo "============================================"

# NOTE: Bucket creation is intentionally done AFTER credential resolution (below).
# On OVH Ceph RadosGW, `ovhcloud cloud storage-s3 create` creates the bucket under the
# OVH management API's authenticated user identity, which is DIFFERENT from the prereq
# cloud user (KUBE_USER_ID) whose S3 credentials are used at runtime. This causes a
# bucket ownership mismatch: the prereq user's credentials get 403 on all object ops.
#
# Fix: create the bucket using the prereq user's own S3 credentials via `aws s3api
# create-bucket`. The user that creates the bucket via the S3 API becomes its RadosGW
# owner and gets full access. Bucket creation is therefore deferred to after credentials.

# Resolve the prereq OVH cloud user for S3 credential generation.
# The prerequisite step creates a single OVH cloud user (with OpenStack + KeyManager
# roles) whose username is stored in clouds.yaml under OS_CLOUD. We reuse that same
# user for S3 credentials 
# S3 access keys (RadosGW credentials) are a separate credential type from OpenStack
# Keystone tokens, so using an admin-role user here carries no extra risk.

if [ -z "${KUBE_USER_ID:-}" ]; then
    echo "Resolving prereq cloud user from OS_CLOUD='${OS_CLOUD}'..."
    # Extract the OpenStack username from ~/.config/openstack/clouds.yaml
    _CLOUDS_FILE="${HOME}/.config/openstack/clouds.yaml"
    if [ ! -f "${_CLOUDS_FILE}" ]; then
        die "clouds.yaml not found at ${_CLOUDS_FILE}. Complete prerequisite step 8 first."
    fi
    OS_USERNAME_FROM_CLOUDS=$(python3 -c "
import sys, os, re
cloud = os.environ.get('OS_CLOUD', 'ovh-gra9')
clouds_file = os.path.expanduser('~/.config/openstack/clouds.yaml')
# Try yaml module first; fall back to regex if not available
try:
    import yaml
    with open(clouds_file) as f:
        data = yaml.safe_load(f)
    print(data['clouds'][cloud]['auth']['username'])
    sys.exit(0)
except ImportError:
    pass
# Regex fallback: find the cloud block, extract username
with open(clouds_file) as f:
    content = f.read()
idx = content.find(cloud + ':')
if idx == -1:
    sys.exit(1)
m = re.search(r'username:\s*(\S+)', content[idx:idx+2000])
if m:
    print(m.group(1))
    sys.exit(0)
sys.exit(1)
" 2>/dev/null || true)

    if [ -z "${OS_USERNAME_FROM_CLOUDS:-}" ]; then
        die "Could not extract OpenStack username from ${_CLOUDS_FILE} (OS_CLOUD=${OS_CLOUD})"
    fi

    # Match the OpenStack username against the OVH cloud user list to get the user ID
    KUBE_USER_ID=$(export OS_USERNAME_FROM_CLOUDS="${OS_USERNAME_FROM_CLOUDS}"; \
        ovhcloud cloud user list \
            --cloud-project "${OVH_PROJECT_ID}" \
            -o json 2>/dev/null \
        | python3 -c "
import sys, json, os
target = os.environ.get('OS_USERNAME_FROM_CLOUDS', '')
users = json.load(sys.stdin)
if isinstance(users, dict) and 'details' in users:
    users = users['details']
if not isinstance(users, list):
    sys.exit(0)
for u in users:
    if u.get('username','') == target:
        print(u.get('id',''))
        break
" || true)

    if [ -z "${KUBE_USER_ID:-}" ]; then
        die "Could not find OVH cloud user matching OpenStack username '${OS_USERNAME_FROM_CLOUDS}'. Ensure clouds.yaml is correct and the user exists in OVH Manager → Users & Roles."
    fi
    ok "Resolved prereq cloud user: ${KUBE_USER_ID} (username: ${OS_USERNAME_FROM_CLOUDS})"
    sed -i "s|^KUBE_USER_ID=.*|KUBE_USER_ID=\"${KUBE_USER_ID}\"|" "$ROOT_DIR/env.variables"
else
    warn "KUBE_USER_ID already set (${KUBE_USER_ID}). Skipping user lookup."
fi
export KUBE_USER_ID

# Helper: parse credentials create/list response and emit only when both
# access AND secret are present. This guards against API error responses
# (which are valid JSON dicts but lack credential fields) being accepted.
_parse_s3_creds() {
    python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, dict) and 'details' in d:
    d = d['details']
if isinstance(d, dict) and d.get('access') and d.get('secret'):
    print(json.dumps(d))
"
}

# Create S3 credentials for the user.
# NOTE: user_id is a POSITIONAL argument, not a --user-id flag.
# The response is a flat JSON object: {"access":"...","secret":"..."}
echo "Creating S3 credentials for user ${KUBE_USER_ID}..."
S3_CREDS=$(ovhcloud cloud storage-s3 credentials create \
    "${KUBE_USER_ID}" \
    --cloud-project "${OVH_PROJECT_ID}" \
    -o json 2>/dev/null \
    | _parse_s3_creds || true)

if [ -z "${S3_CREDS:-}" ]; then
    # Credentials may already exist , but the list endpoint only returns the
    # access key (OVH never re-exposes the secret). Delete any stale credentials
    # and create fresh ones so we can capture the secret.
    warn "Could not create new S3 credentials. Checking for existing credentials to rotate..."
    EXISTING_ACCESS=$(ovhcloud cloud storage-s3 credentials list \
        "${KUBE_USER_ID}" \
        --cloud-project "${OVH_PROJECT_ID}" \
        -o json 2>/dev/null \
        | python3 -c "
import sys,json
data=json.load(sys.stdin)
if isinstance(data, dict) and 'details' in data: data = data['details']
if isinstance(data, list) and len(data) > 0:
    print(data[0].get('access',''))
elif isinstance(data, dict):
    print(data.get('access',''))
" || true)

    if [ -n "${EXISTING_ACCESS:-}" ]; then
        warn "S3 credential already exists for user ${KUBE_USER_ID} (access: ${EXISTING_ACCESS:0:8}...)"
        warn "OVH never re-exposes existing S3 secrets. Two options:"
        echo ""
        echo "  [1] Rotate : delete & recreate credential (bucket access continues; existing env vars will be updated)"
        echo "  [2] Reuse  : enter the existing secret key manually"
        echo ""
        read -rp "Choose [1=rotate / 2=reuse]: " _S3_CHOICE
        case "${_S3_CHOICE}" in
            2)
                read -rsp "Enter existing S3 secret key for access ${EXISTING_ACCESS}: " _EXISTING_SECRET
                echo ""
                if [ -z "${_EXISTING_SECRET:-}" ]; then
                    die "No secret key provided. Cannot continue."
                fi
                S3_CREDS=$(python3 -c "import json,sys; print(json.dumps({'access': sys.argv[1], 'secret': sys.argv[2]}))" \
                    "${EXISTING_ACCESS}" "${_EXISTING_SECRET}")
                unset _EXISTING_SECRET
                ;;
            *)
                warn "Rotating: deleting stale S3 credential (access: ${EXISTING_ACCESS:0:8}...)..."
                ovhcloud cloud storage-s3 credentials delete \
                    "${KUBE_USER_ID}" \
                    "${EXISTING_ACCESS}" \
                    --cloud-project "${OVH_PROJECT_ID}" 2>/dev/null || true
                sleep 5
                ;;
        esac
    fi

    # Retry credential creation after clearing stale credentials
    S3_CREDS=$(ovhcloud cloud storage-s3 credentials create \
        "${KUBE_USER_ID}" \
        --cloud-project "${OVH_PROJECT_ID}" \
        -o json 2>/dev/null \
        | _parse_s3_creds || true)
fi

if [ -z "${S3_CREDS:-}" ]; then
    die "Could not obtain S3 credentials for user ${KUBE_USER_ID}"
fi

OVH_S3_ACCESS_KEY=$(echo "${S3_CREDS}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access',''))")
OVH_S3_SECRET_KEY=$(echo "${S3_CREDS}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('secret',''))")

if [ -z "${OVH_S3_ACCESS_KEY:-}" ] || [ -z "${OVH_S3_SECRET_KEY:-}" ]; then
    die "S3 credentials are empty. Cannot continue."
fi
export OVH_S3_ACCESS_KEY OVH_S3_SECRET_KEY
ok "S3 credentials obtained (access key: ${OVH_S3_ACCESS_KEY:0:8}...)"

# Persist credentials to env.variables so the destroy script can clean them up
# without needing the secret to be re-entered (OVH never re-exposes existing secrets).
sed -i "s|^OVH_S3_ACCESS_KEY=.*|OVH_S3_ACCESS_KEY=\"${OVH_S3_ACCESS_KEY}\"|" "$ROOT_DIR/env.variables"
sed -i "s|^OVH_S3_SECRET_KEY=.*|OVH_S3_SECRET_KEY=\"${OVH_S3_SECRET_KEY}\"|" "$ROOT_DIR/env.variables"
ok "S3 credentials persisted to env.variables"

# base64-encode for Kubernetes Secret
OVH_S3_ACCESS_KEY_B64=$(echo -n "${OVH_S3_ACCESS_KEY}" | base64 -w0)
OVH_S3_SECRET_KEY_B64=$(echo -n "${OVH_S3_SECRET_KEY}" | base64 -w0)
export OVH_S3_ACCESS_KEY_B64 OVH_S3_SECRET_KEY_B64

# Now create the S3 bucket using the cloud user's OWN S3 credentials.
# This makes the cloud user the RadosGW owner of the bucket, granting it full S3
# access. Creating the bucket via `ovhcloud cloud storage-s3 create` instead would
# create it under a different identity (the OVH management API user), causing 403s
# on all object operations by the cloud user credentials used at runtime.
BUCKET_EXISTS=$(AWS_ACCESS_KEY_ID="${OVH_S3_ACCESS_KEY}" \
    AWS_SECRET_ACCESS_KEY="${OVH_S3_SECRET_KEY}" \
    AWS_DEFAULT_REGION="${OVH_S3_REGION}" \
    aws s3api --endpoint-url "${OVH_S3_ENDPOINT}" \
    list-buckets 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
buckets = data.get('Buckets', [])
print('yes' if any(b.get('Name') == '${OVH_S3_BUCKET}' for b in buckets) else '')
" 2>/dev/null || echo "")

if [ -n "${BUCKET_EXISTS}" ]; then
    warn "S3 bucket '${OVH_S3_BUCKET}' already exists. Skipping creation."
else
    echo "Creating S3 bucket '${OVH_S3_BUCKET}' using cloud user S3 credentials..."
    AWS_ACCESS_KEY_ID="${OVH_S3_ACCESS_KEY}" \
    AWS_SECRET_ACCESS_KEY="${OVH_S3_SECRET_KEY}" \
    AWS_DEFAULT_REGION="${OVH_S3_REGION}" \
    aws s3api --endpoint-url "${OVH_S3_ENDPOINT}" \
        create-bucket --bucket "${OVH_S3_BUCKET}" 2>&1 \
        || die "Failed to create S3 bucket '${OVH_S3_BUCKET}'"
    ok "S3 bucket created (owned by prereq user ${KUBE_USER_ID})"
fi

echo ""

##########################################
## PHASE 5: MANAGED PRIVATE REGISTRY  ##
##########################################
echo "============================================"
echo " Phase 5: OVH Managed Private Registry"
echo "============================================"

# OVH MPR is a Harbor-based container registry for storing custom task images.
# URL format: <hash>.<region>.container-registry.ovh.net
# Creation via OVH API; users/projects managed via Harbor UI.
#
# Two levels of auth are needed:
#   (1) K8s imagePullSecrets — for pulling the Funnel worker pod image
#   (2) nerdctl Docker config — for pulling task container images from within workers
#
# This phase:
#   1. Discovers available plans and picks the configured one (S/M/L)
#   2. Creates the registry (or reuses existing one)
#   3. Generates Harbor admin credentials
#   4. Creates a K8s Secret (regcred) for imagePullSecrets
#   5. Creates a ConfigMap with Docker config for nerdctl auth

if [ -n "${MPR_REGISTRY_URL:-}" ] && [ "${MPR_REGISTRY_URL}" != "" ]; then
    warn "MPR_REGISTRY_URL already set (${MPR_REGISTRY_URL}). Skipping registry creation."
else
    # --- Step 1: Check for existing registry ---
    echo "Checking for existing '${MPR_REGISTRY_NAME}' registry..."
    EXISTING_REG=$(ovhcloud cloud container-registry list \
        --cloud-project "${OVH_PROJECT_ID}" -o json 2>/dev/null \
        | python3 -c "
import sys, json
try:
    raw = sys.stdin.read()
    regs = json.loads(raw) if raw.strip() else []
    if not isinstance(regs, list): regs = []
except (json.JSONDecodeError, ValueError):
    regs = []
for r in regs:
    if r.get('name') == '${MPR_REGISTRY_NAME}':
        print(json.dumps(r))
        break
" || echo "")

    if [ -n "${EXISTING_REG}" ]; then
        MPR_REGISTRY_ID=$(echo "${EXISTING_REG}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
        MPR_REGISTRY_URL=$(echo "${EXISTING_REG}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('url',''))" 2>/dev/null || echo "")
        ok "Reusing existing registry: ${MPR_REGISTRY_URL} (id: ${MPR_REGISTRY_ID})"
    else
        # --- Step 2: Get plan ID ---
        echo "Discovering available MPR plans for region ${OVH_REGION}..."
        # Container registry uses short region codes without trailing digits:
        # GRA9 -> GRA, GRA11 -> GRA, DE1 -> DE, BHS5 -> BHS, EU-WEST-PAR -> EU-WEST-PAR
        _REGISTRY_REGION=$(echo "${OVH_REGION}" | sed 's/[0-9]*$//')
        echo "  Container registry region: ${_REGISTRY_REGION}"
        # Map single-letter MPR_PLAN (S/M/L) to plan name keyword
        case "${MPR_PLAN:-S}" in
            S|s) _PLAN_TARGET="small" ;;
            M|m) _PLAN_TARGET="medium" ;;
            L|l) _PLAN_TARGET="large" ;;
            *)   _PLAN_TARGET="small" ;;
        esac
        PLAN_ID=$(ovhcloud cloud reference container-registry list-plans \
            --cloud-project "${OVH_PROJECT_ID}" -o json 2>/dev/null \
            | python3 -c "
import sys, json
try:
    raw = sys.stdin.read()
    plans = json.loads(raw) if raw.strip() else []
    if not isinstance(plans, list): plans = []
except (json.JSONDecodeError, ValueError):
    plans = []
region = '${_REGISTRY_REGION}'
target = '${_PLAN_TARGET}'
# Filter by region first, fall back to all plans if no region match
region_plans = [p for p in plans if p.get('region','').upper() == region.upper()]
if not region_plans:
    region_plans = plans
for p in region_plans:
    if target in p.get('name','').lower():
        print(p['id'])
        sys.exit(0)
# Fallback: first plan in region
if region_plans:
    print(region_plans[0]['id'])
" || echo "")

        if [ -z "${PLAN_ID:-}" ]; then
            die "Could not discover MPR plan ID. Check OVH API access and project ID."
        fi
        echo "  Using plan: ${MPR_PLAN} (id: ${PLAN_ID})"

        # --- Step 3: Create registry ---
        echo "Creating Managed Private Registry '${MPR_REGISTRY_NAME}' in ${_REGISTRY_REGION}..."
        REG_RESULT=$(ovhcloud cloud container-registry create \
            --cloud-project "${OVH_PROJECT_ID}" \
            --name "${MPR_REGISTRY_NAME}" \
            --region "${_REGISTRY_REGION}" \
            --plan-id "${PLAN_ID}" \
            -o json 2>/dev/null || echo "")

        if [ -z "${REG_RESULT:-}" ]; then
            die "Failed to create registry '${MPR_REGISTRY_NAME}'"
        fi

        MPR_REGISTRY_ID=$(echo "${REG_RESULT}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('details',{}).get('id',''))" 2>/dev/null || echo "")
        if [ -z "${MPR_REGISTRY_ID:-}" ]; then
            die "Registry creation failed — no ID in response. Response: ${REG_RESULT}"
        fi
        ok "Registry creation initiated (id: ${MPR_REGISTRY_ID})"

        # Wait for registry to become READY
        echo "Waiting for registry to become ready..."
        for i in $(seq 1 30); do
            REG_STATUS=$(ovhcloud cloud container-registry get "${MPR_REGISTRY_ID}" \
                --cloud-project "${OVH_PROJECT_ID}" -o json 2>/dev/null \
                | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','UNKNOWN'))" 2>/dev/null \
                || echo "UNKNOWN")
            if [ "${REG_STATUS}" = "READY" ] || [ "${REG_STATUS}" = "OK" ]; then
                break
            fi
            echo "  poll ${i}/30: status=${REG_STATUS}, waiting..."
            sleep 10
        done

        # Get the registry URL
        MPR_REGISTRY_URL=$(ovhcloud cloud container-registry get "${MPR_REGISTRY_ID}" \
            --cloud-project "${OVH_PROJECT_ID}" -o json 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('url',''))" 2>/dev/null \
            || echo "")

        if [ -z "${MPR_REGISTRY_URL:-}" ]; then
            die "Registry created but could not retrieve URL"
        fi
        ok "Registry ready: ${MPR_REGISTRY_URL}"
    fi

    # Save to env.variables
    sed -i "s|^MPR_REGISTRY_ID=.*|MPR_REGISTRY_ID=\"${MPR_REGISTRY_ID}\"|" "$ROOT_DIR/env.variables"
    sed -i "s|^MPR_REGISTRY_URL=.*|MPR_REGISTRY_URL=\"${MPR_REGISTRY_URL}\"|" "$ROOT_DIR/env.variables"
fi
export MPR_REGISTRY_ID MPR_REGISTRY_URL

# --- Step 4: Generate Harbor credentials (if not already set) ---
if [ -n "${MPR_HARBOR_USER:-}" ] && [ -n "${MPR_HARBOR_PASSWORD:-}" ]; then
    warn "MPR_HARBOR_USER and MPR_HARBOR_PASSWORD already set. Skipping credential generation."
else
    if [ -n "${MPR_HARBOR_USER:-}" ] && [ -z "${MPR_HARBOR_PASSWORD:-}" ]; then
        warn "MPR_HARBOR_USER is set but MPR_HARBOR_PASSWORD is missing — regenerating credentials."
        # List existing API users; if ours is there, delete it so we can re-create with a fresh password.
        # (OVH only returns the plain-text password at creation time; there is no "reset" endpoint.)
        _existing_users=""
        _existing_users=$(ovh_api_call "GET" \
            "/cloud/project/${OVH_PROJECT_ID}/containerRegistry/${MPR_REGISTRY_ID}/users" \
            "" "${OVH_APP_KEY}" "${OVH_APP_SECRET}" "${OVH_CONSUMER_KEY}" \
            "List Harbor users" 2>/dev/null) || _existing_users="[]"
        _del_id=$(echo "${_existing_users:-[]}" | python3 -c "
import sys, json
try:
    users = json.loads(sys.stdin.read())
    for u in users:
        if u.get('user','') == '${MPR_HARBOR_USER}':
            print(u.get('id',''))
            break
except Exception:
    pass
" 2>/dev/null || echo "")
        if [ -n "${_del_id}" ]; then
            echo "Deleting existing Harbor user '${MPR_HARBOR_USER}' (id: ${_del_id}) to regenerate password..."
            ovh_api_call "DELETE" \
                "/cloud/project/${OVH_PROJECT_ID}/containerRegistry/${MPR_REGISTRY_ID}/users/${_del_id}" \
                "" "${OVH_APP_KEY}" "${OVH_APP_SECRET}" "${OVH_CONSUMER_KEY}" \
                "Delete Harbor user" 2>/dev/null || true
        fi
    else
        echo "Generating Harbor credentials..."
    fi

    # POST with an empty body — OVH auto-generates the login and returns the password once.
    # Sending an explicit login causes HTTP 500 on OVH's backend (known OVH bug).
    _harbor_body_file=$(mktemp)
    echo '{}' > "$_harbor_body_file"
    HARBOR_CREDS=""
    HARBOR_CREDS=$(ovh_api_call "POST" \
        "/cloud/project/${OVH_PROJECT_ID}/containerRegistry/${MPR_REGISTRY_ID}/users" \
        "$_harbor_body_file" \
        "${OVH_APP_KEY}" "${OVH_APP_SECRET}" "${OVH_CONSUMER_KEY}" \
        "Harbor user create" 2>/dev/null) || HARBOR_CREDS=""
    rm -f "$_harbor_body_file"

    if [ -n "${HARBOR_CREDS}" ]; then
        MPR_HARBOR_USER=$(echo "${HARBOR_CREDS}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('user','') or d.get('login',''))" 2>/dev/null || echo "")
        MPR_HARBOR_PASSWORD=$(echo "${HARBOR_CREDS}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('password',''))" 2>/dev/null || echo "")
    fi

    if [ -z "${MPR_HARBOR_USER:-}" ] || [ -z "${MPR_HARBOR_PASSWORD:-}" ]; then
        warn "Could not auto-generate Harbor credentials."
        warn "Go to OVHcloud Manager → Managed Private Registry → ${MPR_REGISTRY_NAME}"
        warn "Click '...' → 'Generate identification details' to get credentials."
        warn "Then set MPR_HARBOR_USER and MPR_HARBOR_PASSWORD in env.variables and re-run."
    else
        ok "Harbor credentials generated (user: ${MPR_HARBOR_USER})"
        sed -i "s|^MPR_HARBOR_USER=.*|MPR_HARBOR_USER=\"${MPR_HARBOR_USER}\"|" "$ROOT_DIR/env.variables"
        sed -i "s|^MPR_HARBOR_PASSWORD=.*|MPR_HARBOR_PASSWORD=\"${MPR_HARBOR_PASSWORD}\"|" "$ROOT_DIR/env.variables"
    fi
fi
export MPR_HARBOR_USER MPR_HARBOR_PASSWORD

# --- Step 5: Create K8s Secret + ConfigMap for registry auth ---
if [ -n "${MPR_REGISTRY_URL:-}" ] && [ -n "${MPR_HARBOR_USER:-}" ] && [ -n "${MPR_HARBOR_PASSWORD:-}" ]; then
    # K8s imagePullSecret (for pulling Funnel worker image from private registry)
    if kubectl get secret regcred -n "${TES_NAMESPACE}" &>/dev/null; then
        warn "K8s secret 'regcred' already exists in ${TES_NAMESPACE}. Skipping."
    else
        kubectl create secret docker-registry regcred \
            -n "${TES_NAMESPACE}" \
            --docker-server="${MPR_REGISTRY_URL}" \
            --docker-username="${MPR_HARBOR_USER}" \
            --docker-password="${MPR_HARBOR_PASSWORD}" 2>/dev/null \
            && ok "K8s secret 'regcred' created in ${TES_NAMESPACE}" \
            || warn "Could not create K8s secret 'regcred' (namespace may not exist yet — will create in Phase 5)"
    fi

    # Docker config for nerdctl (for pulling task images on worker nodes)
    DOCKER_AUTH_B64=$(echo -n "${MPR_HARBOR_USER}:${MPR_HARBOR_PASSWORD}" | base64 -w0)
    DOCKER_CONFIG_JSON="{\"auths\":{\"${MPR_REGISTRY_URL}\":{\"auth\":\"${DOCKER_AUTH_B64}\"}}}"

    if kubectl get configmap docker-registry-config -n "${TES_NAMESPACE}" &>/dev/null; then
        warn "ConfigMap 'docker-registry-config' already exists. Skipping."
    else
        kubectl create configmap docker-registry-config \
            -n "${TES_NAMESPACE}" \
            --from-literal=config.json="${DOCKER_CONFIG_JSON}" 2>/dev/null \
            && ok "ConfigMap 'docker-registry-config' created for nerdctl auth" \
            || warn "Could not create ConfigMap (namespace may not exist yet — will create in Phase 5)"
    fi
else
    _missing_mpr=""
    [ -z "${MPR_REGISTRY_URL:-}" ] && _missing_mpr="${_missing_mpr} MPR_REGISTRY_URL"
    [ -z "${MPR_HARBOR_USER:-}" ]  && _missing_mpr="${_missing_mpr} MPR_HARBOR_USER"
    [ -z "${MPR_HARBOR_PASSWORD:-}" ] && _missing_mpr="${_missing_mpr} MPR_HARBOR_PASSWORD"
    warn "Skipping K8s secret/configmap creation — missing:${_missing_mpr}"
    warn "You can configure these manually after Phase 5 (see installation guide)."
fi

ok "Phase 5 complete — Private Registry configured"
echo ""

###############################
## PHASE 6: DEPLOY FUNNEL
###############################
echo "============================================"
echo " Phase 6: Deploy Funnel"
echo "============================================"

# Variables passed explicitly to envsubst.
# This prevents Go template variables ({{.TaskId}} etc.) from being touched,
# and avoids expanding $k/$v inside the nerdctl RunCommand.
FUND_VARS='${TES_NAMESPACE} ${OVH_S3_BUCKET} ${OVH_S3_REGION} ${OVH_S3_ENDPOINT} ${FUNNEL_IMAGE} ${FUNNEL_PORT} ${EXTERNAL_IP} ${OVH_S3_ACCESS_KEY_B64} ${OVH_S3_SECRET_KEY_B64} ${FILE_STORAGE_SIZE} ${READ_BUCKETS} ${WRITE_BUCKETS} ${WORK_DIR_INITIAL_GB} ${WORK_DIR_EXPAND_GB} ${WORK_DIR_EXPAND_THRESHOLD} ${WORK_DIR_MIN_FREE_GB} ${WORK_DIR_POLL_INTERVAL_SEC} ${WORK_DIR_EXPAND_COOLDOWN_SEC} ${WORK_DIR_MAX_VOLUMES} ${WORK_DIR_EXPAND_COOLDOWN_SEC} ${CINDER_VOLUME_TYPE} ${CINDER_STORAGE_CLASS} ${FUNNEL_DISK_SETUP_IMAGE} ${LUKS_PASSPHRASE} ${OS_AUTH_URL} ${OS_TENANT_ID} ${OS_USERNAME} ${OS_PASSWORD} ${OS_REGION_NAME} ${NFS_EXPORT_PATH} ${MANILA_SHARE_ID} ${OS_CLOUD} ${MANILA_ACCESS_ID} ${NFS_MOUNT_PATH} ${NFS_KEEPALIVE_INTERVAL} ${NODE_OVERHEAD_MI}'

render_and_apply() {
    local name="$1"
    local in_yaml="$ROOT_DIR/yamls/${name}.template.yaml"
    local out_yaml="$ROOT_DIR/yamls/${name}.yaml"

    # Static files (no template vars) are applied directly
    if [ ! -f "$in_yaml" ]; then
        in_yaml="$ROOT_DIR/yamls/${name}.yaml"
        echo "Applying (static) ${name}.yaml..."
        kubectl apply -f "$in_yaml"
        return
    fi

    echo "Rendering + applying ${name}..."
    # Render only known vars; restore __DOLLAR__ → $ (used to escape Go template $k/$v)
    envsubst "$FUND_VARS" < "$in_yaml" | sed 's/__DOLLAR__/\$/g' > "$out_yaml"
    retry_kubectl "$out_yaml"
}

render_and_apply "funnel-namespace"
render_and_apply "funnel-serviceaccount"
render_and_apply "funnel-rbac"
render_and_apply "s3-secret"

# --- Ensure MPR secrets/configmap exist in the namespace ---
# may have created these already; re-create here in case
# the namespace was not yet available.
if [ -n "${MPR_REGISTRY_URL:-}" ] && [ -n "${MPR_HARBOR_USER:-}" ] && [ -n "${MPR_HARBOR_PASSWORD:-}" ]; then
    if ! kubectl get secret regcred -n "${TES_NAMESPACE}" &>/dev/null; then
        kubectl create secret docker-registry regcred \
            -n "${TES_NAMESPACE}" \
            --docker-server="${MPR_REGISTRY_URL}" \
            --docker-username="${MPR_HARBOR_USER}" \
            --docker-password="${MPR_HARBOR_PASSWORD}" \
            && ok "K8s secret 'regcred' created in ${TES_NAMESPACE}" \
            || warn "Could not create K8s secret 'regcred'"
    fi
    if ! kubectl get configmap docker-registry-config -n "${TES_NAMESPACE}" &>/dev/null; then
        DOCKER_AUTH_B64=$(echo -n "${MPR_HARBOR_USER}:${MPR_HARBOR_PASSWORD}" | base64 -w0)
        DOCKER_CONFIG_JSON="{\"auths\":{\"${MPR_REGISTRY_URL}\":{\"auth\":\"${DOCKER_AUTH_B64}\"}}}"
        kubectl create configmap docker-registry-config \
            -n "${TES_NAMESPACE}" \
            --from-literal=config.json="${DOCKER_CONFIG_JSON}" \
            && ok "ConfigMap 'docker-registry-config' created for nerdctl auth" \
            || warn "Could not create ConfigMap 'docker-registry-config'"
    fi
else
    warn "MPR credentials not set : skipping private registry secrets."
    warn "Worker pods will only pull from public registries."
fi

render_and_apply "manila-pvc"            # Static PV + RWX PVC backed by OVH Manila NFS share
render_and_apply "funnel-db-pvc"         # RWO PVC for BoltDB — persists task DB across Funnel restarts
render_and_apply "funnel-configmap"
render_and_apply "funnel-deployment"
render_and_apply "funnel-tes-service"
render_and_apply "funnel-loadbalancer-service"


# Extract OpenStack credentials from clouds.yaml for the funnel-openstack-creds Secret.
# The disk-setup DaemonSet uses these to authenticate to Cinder for volume cleanup
# after each task. Without them the Secret has empty values and orphaned Cinder
# volumes accumulate, eventually exhausting the project's disk quota.
echo "Extracting OpenStack credentials from clouds.yaml (OS_CLOUD=${OS_CLOUD})..."
_OS_CREDS=$(python3 - "${OS_CLOUD}" <<'OS_CREDS_EOF'
import sys, os

cloud       = sys.argv[1]
clouds_file = os.path.expanduser("~/.config/openstack/clouds.yaml")

def extract_re(cloud, clouds_file):
    import re
    with open(clouds_file) as f:
        content = f.read()
    idx = content.find(cloud + ':')
    if idx == -1:
        raise ValueError(f"cloud '{cloud}' not found in clouds.yaml")
    block = content[idx:idx+4000]
    def get(key):
        m = re.search(rf'{key}:\s*(\S+)', block)
        return m.group(1) if m else ''
    return {
        'auth_url':    get('auth_url'),
        'username':    get('username'),
        'password':    get('password'),
        'project_id':  get('project_id') or get('tenant_id'),
        'region_name': get('region_name'),
    }

try:
    import yaml
    with open(clouds_file) as f:
        data = yaml.safe_load(f)
    cloud_cfg = data["clouds"][cloud]
    auth      = cloud_cfg.get("auth", {})
    vals = {
        'auth_url':    auth.get('auth_url', ''),
        'username':    auth.get('username', ''),
        'password':    auth.get('password', ''),
        'project_id':  auth.get('project_id', auth.get('tenant_id', '')),
        'region_name': cloud_cfg.get('region_name', ''),
    }
except ImportError:
    vals = extract_re(cloud, clouds_file)
except Exception as e:
    try:
        vals = extract_re(cloud, clouds_file)
    except Exception:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

print(f"OS_AUTH_URL={vals['auth_url']}")
print(f"OS_USERNAME={vals['username']}")
print(f"OS_PASSWORD={vals['password']}")
print(f"OS_TENANT_ID={vals['project_id']}")
print(f"OS_REGION_NAME={vals['region_name']}")
OS_CREDS_EOF
) || die "Failed to extract OpenStack credentials from clouds.yaml (OS_CLOUD=${OS_CLOUD})"

OS_AUTH_URL=$(echo    "${_OS_CREDS}" | grep '^OS_AUTH_URL='    | cut -d= -f2-)
OS_USERNAME=$(echo    "${_OS_CREDS}" | grep '^OS_USERNAME='    | cut -d= -f2-)
OS_PASSWORD=$(echo    "${_OS_CREDS}" | grep '^OS_PASSWORD='    | cut -d= -f2-)
OS_TENANT_ID=$(echo   "${_OS_CREDS}" | grep '^OS_TENANT_ID='   | cut -d= -f2-)
OS_REGION_NAME=$(echo "${_OS_CREDS}" | grep '^OS_REGION_NAME=' | cut -d= -f2-)

for _os_var in OS_AUTH_URL OS_USERNAME OS_TENANT_ID OS_REGION_NAME; do
    [[ -n "${!_os_var}" ]] || die "Could not extract ${_os_var} from clouds.yaml (OS_CLOUD=${OS_CLOUD})"
done
[[ -n "${OS_PASSWORD:-}" ]] || warn "OS_PASSWORD is empty in clouds.yaml — Cinder cleanup will not work"
export OS_AUTH_URL OS_USERNAME OS_PASSWORD OS_TENANT_ID OS_REGION_NAME
ok "OpenStack credentials extracted (user=${OS_USERNAME}, region=${OS_REGION_NAME})"

# Apply the OpenStack credentials secret (Secret template uses envsubst)
render_and_apply "funnel-disk-setup"    # ServiceAccount + ClusterRole + RBAC + Secret + DaemonSet

# Auto-calculate NODE_OVERHEAD_MI from a real worker node (capacity - allocatable).
# This is the OVH system reservation that Karpenter doesn't know about when
# estimating capacity of not-yet-provisioned nodes. The ghost DaemonSet uses
# this value so Karpenter's bin-packing simulation matches reality.
echo "Calculating node overhead (capacity - allocatable) for Karpenter simulation..."
CALC_OVERHEAD=$(kubectl get nodes -l karpenter.sh/nodepool=workers \
    -o jsonpath='{range .items[0]}{.status.capacity.memory}{" "}{.status.allocatable.memory}{end}' \
    2>/dev/null || echo "")
if [ -n "${CALC_OVERHEAD}" ]; then
    CAP_KI=$(echo "${CALC_OVERHEAD}" | awk '{print $1}' | tr -d 'Ki')
    ALLOC_KI=$(echo "${CALC_OVERHEAD}" | awk '{print $2}' | tr -d 'Ki')
    CALC_MI=$(( (CAP_KI - ALLOC_KI) / 1024 ))
    if [ "${CALC_MI}" -gt 0 ]; then
        NODE_OVERHEAD_MI="${CALC_MI}"
        sed -i "s|^NODE_OVERHEAD_MI=.*|NODE_OVERHEAD_MI=\"${NODE_OVERHEAD_MI}\"    # auto-calculated: ${CAP_KI}Ki - ${ALLOC_KI}Ki|" "${ROOT_DIR}/env.variables"
        ok "Node overhead auto-calculated: ${NODE_OVERHEAD_MI} Mi (capacity ${CAP_KI}Ki - allocatable ${ALLOC_KI}Ki)"
    fi
else
    warn "No worker node found yet — using NODE_OVERHEAD_MI=${NODE_OVERHEAD_MI} from env.variables"
fi
export NODE_OVERHEAD_MI

render_and_apply "karpenter-node-overhead"  # Ghost DaemonSet: makes Karpenter see real allocatable (not raw flavor RAM)

ok "All Funnel manifests applied"

# Wait for Funnel pod to be Ready
# Karpenter may need several minutes to provision a new node before the pod can
# be scheduled. progressDeadlineSeconds in the deployment is set to 1200s (20m)
# to match. We use || true so set -e does not kill the script on timeout;
# instead we check pod state and warn rather than die.
echo "Waiting for Funnel deployment to be Ready (timeout 20m)..."
if ! kubectl rollout status deployment/funnel \
    -n "${TES_NAMESPACE}" \
    --timeout=1200s; then
    warn "Funnel deployment did not become Ready within 20 minutes."
    warn "Current pod state:"
    kubectl get pods -n "${TES_NAMESPACE}" -l app=funnel -o wide 2>/dev/null || true
    kubectl describe pod -n "${TES_NAMESPACE}" -l app=funnel 2>/dev/null \
        | grep -A5 'Events:\|Conditions:\|Message:' | head -30 || true
    warn "The Funnel pod may still be starting (Karpenter node provisioning can be slow)."
    warn "Check status with: kubectl rollout status deployment/funnel -n ${TES_NAMESPACE}"
else
    ok "Funnel is running"
fi

# Reduce CoreDNS to a single replica for cost efficiency on small clusters.
# The kube-dns-autoscaler would otherwise fight any manual scale-down, so we
# patch its ConfigMap first to disable preventSinglePointFailure and set min=1.
echo "Patching kube-dns-autoscaler to allow single CoreDNS replica..."
kubectl patch configmap kube-dns-autoscaler -n kube-system \
  --type=merge \
  -p '{"data":{"linear":"{\"coresPerReplica\":256,\"nodesPerReplica\":16,\"preventSinglePointFailure\":false,\"min\":1}"}}' \
  || warn "kube-dns-autoscaler patch failed (may not exist)"
kubectl scale deploy coredns -n kube-system --replicas=1 \
  || warn "CoreDNS scale-down failed"
ok "CoreDNS scaled to 1 replica"

# Show LoadBalancer IP (may take a minute to be assigned)
echo ""
echo "Waiting for LoadBalancer IP to be assigned..."
for i in $(seq 1 30); do
    LB_IP=$(kubectl get svc funnel-lb -n "${TES_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "${LB_IP:-}" ]; then
        ok "LoadBalancer IP: ${LB_IP}"
        break
    fi
    echo "  [attempt $i/30] LoadBalancer IP not yet assigned..."
    sleep 10
done
[ -z "${LB_IP:-}" ] && warn "LoadBalancer IP not yet available. Check: kubectl get svc funnel-lb -n ${TES_NAMESPACE}"

# Persist LoadBalancer IP to env.variables if obtained
if [ -n "${LB_IP:-}" ]; then
    sed -i "s|^LB_ENDPOINT=.*|LB_ENDPOINT=\"${LB_IP}\"|" "$ROOT_DIR/env.variables"
    ok "LoadBalancer IP saved to env.variables: ${LB_IP}"
else
    warn "LoadBalancer IP not available yet — run the following after IP is assigned:"
    warn "  kubectl get svc funnel-lb -n ${TES_NAMESPACE}"
    warn "  then manually update env.variables: LB_ENDPOINT=<IP>"
fi

echo ""

##############################################
## PHASE 6: CONFIGURE CONDA ACTIVATION ENV  ##
##############################################
echo "============================================"
echo " Phase 6: Configure Conda activation env"
echo "============================================"
# Writes etc/conda/activate.d/ovh.sh into the active micromamba env so that
# 'micromamba activate ovh' automatically sets KUBECONFIG, sources env.variables,
# and defines aws_ovh() / kube_debug() helpers for this deployment.

if [ -z "${CONDA_PREFIX:-}" ]; then
    warn "CONDA_PREFIX not set — is the 'ovh' micromamba env active?"
    warn "Skipping activation script. Set these manually:"
    warn "  export KUBECONFIG=${KUBECONFIG_PATH}"
    warn "  source ${ROOT_DIR}/env.variables"
else
    _ACTIVATE_DIR="${CONDA_PREFIX}/etc/conda/activate.d"
    _DEACTIVATE_DIR="${CONDA_PREFIX}/etc/conda/deactivate.d"
    mkdir -p "${_ACTIVATE_DIR}" "${_DEACTIVATE_DIR}"

    cat > "${_ACTIVATE_DIR}/ovh.sh" << OVH_ACTIVATE_EOF
# OVH TES deployment — auto-generated by install-ovh-mks.sh
# Sourced automatically when 'micromamba activate ovh' is run.
# Re-run the installer or edit this file directly to update after changes.

# Point kubectl to the OVH MKS cluster kubeconfig
export KUBECONFIG="${KUBECONFIG_PATH}"

# Load all OVH installer variables (S3 keys, cluster IDs, endpoints, etc.)
source "${ROOT_DIR}/env.variables"

# OVH S3 wrapper — proxies any aws CLI command through the cluster's RadosGW credentials
# Usage: aws_ovh s3 ls   /   aws_ovh s3 cp myfile.txt s3://my-bucket/
aws_ovh() {
    AWS_ACCESS_KEY_ID="\$OVH_S3_ACCESS_KEY" \\
    AWS_SECRET_ACCESS_KEY="\$OVH_S3_SECRET_KEY" \\
    AWS_DEFAULT_REGION="\$OVH_S3_REGION" \\
    aws --endpoint-url "\$OVH_S3_ENDPOINT" "\$@"
}

# Debug a Kubernetes node by launching a privileged busybox pod
# Usage: kube_debug <node-name>
kube_debug() {
    if [ -z "\$1" ]; then
        echo "usage: kube_debug <node-name>"
        return 1
    fi
    kubectl debug node/"\$1" -it --image=busybox -- chroot /host
}
OVH_ACTIVATE_EOF
    chmod +x "${_ACTIVATE_DIR}/ovh.sh"

    # Deactivation script: undo KUBECONFIG and undefine helpers when leaving the env
    cat > "${_DEACTIVATE_DIR}/ovh.sh" << OVH_DEACTIVATE_EOF
# OVH TES deployment — auto-generated by install-ovh-mks.sh
# Sourced automatically when deactivating the 'ovh' micromamba environment.
unset KUBECONFIG
unset -f aws_ovh   2>/dev/null || true
unset -f kube_debug 2>/dev/null || true
OVH_DEACTIVATE_EOF
    chmod +x "${_DEACTIVATE_DIR}/ovh.sh"

    ok "Conda activation script:   ${_ACTIVATE_DIR}/ovh.sh"
    ok "Conda deactivation script: ${_DEACTIVATE_DIR}/ovh.sh"
    echo "  Re-activate the env to apply:"
    echo "    micromamba deactivate && micromamba activate ovh"
fi

###############################
## PHASE 7: CROMWELL CONFIG HINT
###############################
echo "============================================"
echo " Phase 7: Cromwell configuration"
echo "============================================"

LB_ENDPOINT="${LB_IP:-<LOADBALANCER_IP>}"

cat <<CROMWELL_CONF

Add the following to your cromwell-tes.conf (on your Cromwell server):

  backend {
    providers {
      TES {
        actor-factory = "cromwell.backend.impl.tes.TesBackendLifecycleActorFactory"
        config {
          endpoint = "http://${LB_ENDPOINT}/v1/tasks"
          root = "s3://${OVH_S3_BUCKET}/cromwell-executions"

          filesystems {
            s3 {
              auth = "default"
              endpoint = "${OVH_S3_ENDPOINT}"
            }
          }

          use_tes_11_preview_backend_parameters = true
          default-runtime-attributes {
            backoff_limit: "3"
          }
        }
      }
    }
  }

  aws {
    application-name = "cromwell"
    auths = [{
      name = "default"
      scheme = "custom_keys"
      access-key = "${OVH_S3_ACCESS_KEY}"
      secret-key = "${OVH_S3_SECRET_KEY}"
    }]
    region = "${OVH_S3_REGION}"
  }

CROMWELL_CONF




###############################
## PHASE 8: SMOKE TEST
###############################
echo "============================================"
echo " Phase 8: Smoke test"
echo "============================================"

if [ -z "${LB_IP:-}" ]; then
    warn "Skipping smoke test — LoadBalancer IP not yet available."
    warn "Re-run smoke test manually once IP is assigned:"
    warn "  curl -s http://<LB_IP>/v1/service-info | python3 -m json.tool"
else
    echo "Testing Funnel service-info endpoint..."
    for i in $(seq 1 10); do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            "http://${LB_IP}/v1/service-info" --max-time 5 || true)
        if [ "${HTTP_CODE}" = "200" ]; then
            ok "Funnel service-info returned 200 OK"
            curl -s "http://${LB_IP}/v1/service-info" | python3 -m json.tool | head -10
            break
        fi
        echo "  [attempt $i/10] HTTP ${HTTP_CODE} — waiting 10s..."
        sleep 10
    done
    if [ "${HTTP_CODE}" != "200" ]; then
        warn "Smoke test did not get 200. Check: kubectl logs -n ${TES_NAMESPACE} deploy/funnel"
    fi
fi

echo ""
echo "============================================"
ok "Installation complete!"
echo "============================================"
echo ""
echo "Summary:"
echo "  Cluster     : ${K8S_CLUSTER_NAME} (${OVH_REGION})"
echo "  Kubeconfig  : ${KUBECONFIG_PATH}"
echo "  Funnel LB   : ${LB_IP:-<pending>}"
echo "  S3 bucket   : ${OVH_S3_BUCKET}  (endpoint: ${OVH_S3_ENDPOINT})"
echo "  NFS storage : OVH Manila (${FILE_STORAGE_SIZE}Gi, type: ${FILE_STORAGE_SHARE_TYPE}, export: ${NFS_EXPORT_PATH:-<see env.variables>})"
echo ""
echo "Next steps:"
echo "  1. Copy Cromwell config snippet above to your cromwell-tes.conf"
echo "  2. Restart Cromwell"
echo "  3. Submit a test workflow"
echo ""
echo "To tear down all infrastructure, run:"
echo "  ./destroy-ovh-mks.sh"
echo ""
