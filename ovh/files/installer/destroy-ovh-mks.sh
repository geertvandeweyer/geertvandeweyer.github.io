#!/bin/bash
# ============================================================
# OVHcloud MKS Teardown — destroys ALL infrastructure
# WARNING: This will permanently delete the cluster, all node
#          pools, Manila NFS share, private network,
#          S3 bucket, S3 credentials, MPR registry,
#          and Harbor users.
#          Prerequisite OVH cloud user is NOT deleted.
# ============================================================
# Usage:
#   micromamba activate ovh
#   cd OVH_installer/installer
#   ./destroy-ovh-mks.sh
# ============================================================
set -euo pipefail

export ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠  $*${NC}"; }
die()  { echo -e "${RED}❌ $*${NC}" >&2; exit 1; }

# OVH direct-API helpers — needed for Harbor user cleanup (no ovhcloud CLI subcommand).
ovh_api_sig() {
    local method="$1" full_url="$2" body="$3" app_secret="$4" consumer_key="$5" timestamp="$6"
    echo "\$1\$$(echo -n "${app_secret}+${consumer_key}+${method}+${full_url}+${body}+${timestamp}" | sha1sum | awk '{print $1}')"
}

ovh_api_call() {
    local method="$1" url_path="$2" body_file="$3" app_key="$4" app_secret="$5" consumer_key="$6" label="${7:-API call}"
    local timestamp
    timestamp=$(curl -s --max-time 5 https://api.ovh.com/1.0/auth/time 2>/dev/null || date +%s)
    local body=""
    if [ -f "$body_file" ]; then body=$(cat "$body_file"); fi
    local full_url="https://api.ovh.com/1.0${url_path}"
    local sig
    sig=$(ovh_api_sig "$method" "$full_url" "$body" "$app_secret" "$consumer_key" "$timestamp")
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
    local body_response
    body_response=$(echo "$response" | sed '$d')
    if [[ "$http_code" =~ ^(200|201|202|204)$ ]]; then
        echo "$body_response"
        return 0
    else
        die "$label failed with HTTP $http_code: $body_response"
    fi
}

load_ovh_credentials() {
    local conf_file="${HOME}/.ovh.conf"
    if [ ! -f "$conf_file" ]; then
        warn "OVH credentials not found at $conf_file — API-based cleanup steps will be skipped."
        OVH_APP_KEY="" OVH_APP_SECRET="" OVH_CONSUMER_KEY=""
        return
    fi
    OVH_APP_KEY=$(grep    -m1 'application_key'    "$conf_file" | awk -F'[= ]' '{for(i=NF;i>1;i--) if($i!="") {print $i; break}}' | tr -d '"')
    OVH_APP_SECRET=$(grep -m1 'application_secret' "$conf_file" | awk -F'[= ]' '{for(i=NF;i>1;i--) if($i!="") {print $i; break}}' | tr -d '"')
    OVH_CONSUMER_KEY=$(grep -m1 'consumer_key'     "$conf_file" | awk -F'[= ]' '{for(i=NF;i>1;i--) if($i!="") {print $i; break}}' | tr -d '"')
    export OVH_APP_KEY OVH_APP_SECRET OVH_CONSUMER_KEY
}

# Load env
set -a; source "$ROOT_DIR/env.variables"; set +a
load_ovh_credentials

echo -e "${RED}"
echo "=========================================================="
echo "  WARNING: This will PERMANENTLY DELETE:"
echo "    - MKS cluster:       ${K8S_CLUSTER_NAME} (${OVH_REGION})"
echo "    - Manila NFS share:  ${FILE_STORAGE_SHARE_NAME:-<see env.variables>}"
echo "    - Share network:     tes-share-network"
echo "    - Private network:   ${PRIV_NET_NAME:-tes-private-net}"
echo "    - S3 bucket:         ${OVH_S3_BUCKET}  (ALL CONTENTS)"
echo "    - S3 credentials:    for user ${KUBE_USER_ID:-<see env.variables>}"
echo "    - MPR registry:      ${MPR_REGISTRY_NAME:-<see env.variables>} (all Harbor users + images)"
echo "    - Kubeconfig:        ${KUBECONFIG_PATH}"
echo "  NOTE: Prerequisite OVH cloud user (${KUBE_USER_ID:-<see env.variables>})"
echo "        will NOT be deleted. Manage via OVH Manager → Users & Roles."
echo "=========================================================="
echo -e "${NC}"
read -rp "Type 'yes' to confirm full teardown: " CONFIRM
[ "$CONFIRM" != "yes" ] && die "Aborted."

# ── 1. Delete Funnel K8s resources (graceful before cluster delete)
if [ -f "${KUBECONFIG_PATH}" ]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
    echo "Deleting Funnel Kubernetes resources..."
    kubectl delete namespace "${TES_NAMESPACE}" --ignore-not-found --timeout=60s || true

    # Manila CSI: uninstall Helm releases + delete RBAC that blocks re-install
    echo "Uninstalling Manila CSI Helm releases..."
    helm uninstall manila-csi    -n kube-system 2>/dev/null || warn "manila-csi not installed via Helm or already removed"
    helm uninstall csi-driver-nfs -n kube-system 2>/dev/null || warn "csi-driver-nfs not installed via Helm or already removed"

    # Delete cloud-config Secret (contains clouds.yaml; safe to remove)
    kubectl delete secret cloud-config -n kube-system --ignore-not-found || true

    # Delete funnel-work-* PVCs + mount-holder pods (reclaimPolicy: Retain — must delete manually)
    echo "Deleting funnel-work disk-monitor pods and PVCs..."
    kubectl delete pods -n "${TES_NAMESPACE}" -l app=funnel-mount-holder --ignore-not-found || true
    kubectl delete pvc  -n "${TES_NAMESPACE}" -l app=funnel-disk-monitor  --ignore-not-found || true

    # Delete StorageClasses (manila-nfs is the only CSI-backed one; funnel-* are not created)
    kubectl delete storageclass manila-nfs --ignore-not-found || true

    # Delete manila-pvc PV + PVC (they use ReclaimPolicy: Retain — must delete manually)
    kubectl delete pvc manila-shared-pvc -n "${TES_NAMESPACE}" --ignore-not-found || true
    kubectl delete pv  manila-shared-pv  --ignore-not-found || true

    ok "Kubernetes resources deleted"
else
    warn "Kubeconfig not found at ${KUBECONFIG_PATH}; skipping K8s cleanup"
fi

# ── 2. Delete Manila access rule
if [ -n "${MANILA_ACCESS_ID:-}" ] && [ -n "${MANILA_SHARE_ID:-}" ]; then
    echo "Deleting Manila access rule ${MANILA_ACCESS_ID}..."
    openstack share access delete "${MANILA_SHARE_ID}" "${MANILA_ACCESS_ID}" 2>/dev/null \
        || warn "Manila access rule delete failed or already removed"
    ok "Manila access rule deleted"
else
    warn "MANILA_ACCESS_ID or MANILA_SHARE_ID not set; skipping access rule deletion"
fi

# ── 3. Delete Manila share
if [ -n "${MANILA_SHARE_ID:-}" ]; then
    echo "Deleting Manila share ${MANILA_SHARE_ID} (${FILE_STORAGE_SHARE_NAME:-})..."
    openstack share delete "${MANILA_SHARE_ID}" 2>/dev/null \
        || warn "Manila share delete failed or already removed"
    # Wait briefly for the share to be removed before deleting the share network
    echo "Waiting for share deletion..."
    for i in $(seq 1 20); do
        STATUS=$(openstack share show "${MANILA_SHARE_ID}" -c status -f value 2>/dev/null || echo "deleted")
        [ "${STATUS}" = "deleted" ] && break
        echo "  [${i}/20] Share status: ${STATUS} — waiting 10s..."
        sleep 10
    done
    ok "Manila share deleted (or already gone)"
else
    warn "MANILA_SHARE_ID not set; skipping share deletion"
fi

# ── 4. Delete Manila share network
SHARE_NET_NAME="tes-share-network"
EXISTING_SN=$(openstack share network list -c ID -c Name -f value 2>/dev/null \
    | awk -v n="${SHARE_NET_NAME}" '$0 ~ n {print $1}' | head -1 || true)
if [ -n "${EXISTING_SN:-}" ]; then
    echo "Deleting share network ${SHARE_NET_NAME} (${EXISTING_SN})..."
    openstack share network delete "${EXISTING_SN}" 2>/dev/null \
        || warn "Share network delete failed or already removed"
    ok "Share network deleted"
else
    warn "Share network '${SHARE_NET_NAME}' not found; skipping"
fi

# ── 5. Delete MPR Harbor users (explicit; OVH also removes them on registry deletion)
if [ -n "${MPR_REGISTRY_ID:-}" ] && [ -n "${OVH_APP_KEY:-}" ]; then
    echo "Listing Harbor users for registry '${MPR_REGISTRY_NAME:-}' (id: ${MPR_REGISTRY_ID})..."
    _harbor_users=""
    _harbor_users=$(ovh_api_call "GET" \
        "/cloud/project/${OVH_PROJECT_ID}/containerRegistry/${MPR_REGISTRY_ID}/users" \
        "" "${OVH_APP_KEY}" "${OVH_APP_SECRET}" "${OVH_CONSUMER_KEY}" \
        "List Harbor users" 2>/dev/null) || _harbor_users="[]"
    _user_lines=$(echo "${_harbor_users:-[]}" | python3 -c "
import sys, json
try:
    for u in json.load(sys.stdin):
        uid   = u.get('id','')
        uname = u.get('user','')
        if uid:
            print(uid, uname)
except Exception:
    pass
" 2>/dev/null || true)
    if [ -n "${_user_lines:-}" ]; then
        while IFS=" " read -r _uid _uname; do
            [ -z "${_uid}" ] && continue
            echo "  Deleting Harbor user '${_uname}' (id: ${_uid})..."
            ovh_api_call "DELETE" \
                "/cloud/project/${OVH_PROJECT_ID}/containerRegistry/${MPR_REGISTRY_ID}/users/${_uid}" \
                "" "${OVH_APP_KEY}" "${OVH_APP_SECRET}" "${OVH_CONSUMER_KEY}" \
                "Delete Harbor user ${_uname}" 2>/dev/null || \
                warn "  Could not delete user ${_uname} — may already be removed"
        done <<< "${_user_lines}"
        ok "Harbor users deleted"
    else
        warn "No Harbor users found — nothing to delete"
    fi
else
    warn "MPR_REGISTRY_ID or OVH API credentials not set; skipping Harbor user cleanup"
fi

# ── 6. Delete MPR registry
if [ -n "${MPR_REGISTRY_ID:-}" ]; then
    echo "Deleting MPR registry '${MPR_REGISTRY_NAME:-}' (id: ${MPR_REGISTRY_ID})..."
    ovhcloud cloud container-registry delete "${MPR_REGISTRY_ID}" \
        --cloud-project "${OVH_PROJECT_ID}" \
        2>/dev/null || warn "Registry delete failed or already removed"
    ok "MPR registry deleted"
else
    warn "MPR_REGISTRY_ID not set; skipping registry deletion"
fi

# ── 7. Delete MKS cluster (this also deletes all node pools and their instances)
if [ -n "${KUBE_ID:-}" ]; then
    echo "Deleting MKS cluster ${K8S_CLUSTER_NAME} (id: ${KUBE_ID})..."
    ovhcloud cloud kube delete "${KUBE_ID}" \
        --cloud-project "${OVH_PROJECT_ID}" \
        2>/dev/null || warn "Cluster delete failed or already deleted"
    ok "MKS cluster deletion triggered (may take a few minutes)"
else
    warn "KUBE_ID not set; skipping cluster deletion"
fi

# ── 8. Delete private Neutron network (must be done AFTER cluster is gone —
#       cluster deletion releases the network's port reservations)
# If PRIV_NET_ID is empty (OVH API sometimes omits the 'id' field at create
# time, leaving it blank in env.variables), look it up by name now.
if [ -z "${PRIV_NET_ID:-}" ] && [ -n "${PRIV_NET_NAME:-}" ]; then
    echo "PRIV_NET_ID not set — looking up private network by name '${PRIV_NET_NAME}'..."
    PRIV_NET_ID=$(ovhcloud cloud network private list \
        --cloud-project "${OVH_PROJECT_ID}" -o json 2>/dev/null \
        | python3 -c "
import sys, json
nets = json.load(sys.stdin)
if isinstance(nets, dict) and 'details' in nets: nets = nets.get('details', [])
if not isinstance(nets, list): nets = [nets]
for n in nets:
    if n.get('name') == '${PRIV_NET_NAME}':
        print(n.get('id',''))
        break
" 2>/dev/null || true)
    [ -n "${PRIV_NET_ID:-}" ] \
        && echo "  Found: ${PRIV_NET_ID}" \
        || warn "Network '${PRIV_NET_NAME}' not found via OVH API — may already be deleted"
fi

if [ -n "${PRIV_NET_ID:-}" ]; then
    echo "Waiting 60s for cluster instances to release network ports before deleting private network..."
    sleep 60

    # Resolve the OpenStack (Neutron) UUID of the network — needed to list ports/routers.
    # PRIV_NET_OPENSTACK_ID is the Neutron UUID; PRIV_NET_ID is the OVH 'pn-...' shorthand ID.
    _NET_OS_ID="${PRIV_NET_OPENSTACK_ID:-}"
    if [ -z "${_NET_OS_ID:-}" ]; then
        _NET_OS_ID=$(openstack network show "${PRIV_NET_NAME:-tes-private-net}" \
            -c id -f value 2>/dev/null || true)
    fi

    # Delete any OVHcloud Gateway (Neutron router) still attached to the network.
    # When a K8s LoadBalancer Service is created, OVH auto-provisions a Gateway router
    # and attaches it to the private subnet. Deleting the MKS cluster does NOT remove
    # this router — the lingering port blocks 'ovhcloud cloud network private delete'.
    if [ -n "${_NET_OS_ID:-}" ]; then
        echo "Checking for routers attached to network ${_NET_OS_ID}..."
        _ROUTER_IDS=$(openstack port list \
            --network "${_NET_OS_ID}" \
            -c device_id -c device_owner -f json 2>/dev/null \
            | python3 -c "
import sys, json
try:
    ports = json.load(sys.stdin)
    seen = set()
    for p in ports:
        owner = p.get('device_owner','')
        rid   = p.get('device_id','')
        if rid and owner.startswith('network:router'):
            seen.add(rid)
    for r in seen: print(r)
except Exception: pass
" 2>/dev/null || true)

        if [ -n "${_ROUTER_IDS:-}" ]; then
            echo "  Found router(s) still attached — removing before network delete:"
            while IFS= read -r _rid; do
                [ -z "${_rid}" ] && continue
                echo "  Removing router ${_rid}..."
                # Detach internal subnet interfaces first
                _SUBNET_IDS=$(openstack port list \
                    --network "${_NET_OS_ID}" \
                    --device-id "${_rid}" \
                    --device-owner network:router_interface \
                    -c "Fixed IP Addresses" -f json 2>/dev/null \
                    | python3 -c "
import sys, json, ast
try:
    ports = json.load(sys.stdin)
    for p in ports:
        fips = p.get('Fixed IP Addresses', p.get('fixed_ips', []))
        if isinstance(fips, str):
            try: fips = ast.literal_eval(fips)
            except: fips = []
        for fip in fips:
            sid = fip.get('subnet_id','')
            if sid: print(sid)
except Exception: pass
" 2>/dev/null || true)
                while IFS= read -r _sid; do
                    [ -z "${_sid}" ] && continue
                    echo "    Detaching subnet ${_sid}..."
                    openstack router remove subnet "${_rid}" "${_sid}" 2>/dev/null || true
                done <<< "${_SUBNET_IDS}"
                # Clear external gateway port before deletion
                openstack router unset --external-gateway "${_rid}" 2>/dev/null || true
                echo "    Deleting router ${_rid}..."
                openstack router delete "${_rid}" 2>/dev/null \
                    || warn "    Router ${_rid} delete failed — remove manually in OVH console"
            done <<< "${_ROUTER_IDS}"
            ok "Gateway router(s) removed"
        else
            echo "  No routers attached to network — proceeding"
        fi
    else
        warn "Could not resolve OpenStack network ID — skipping router cleanup"
        warn "If the delete fails, remove the Gateway manually: OVH console → Network → Gateways"
    fi

    echo "Deleting private network '${PRIV_NET_NAME:-tes-private-net}' (OVH id: ${PRIV_NET_ID})..."
    ovhcloud cloud network private delete "${PRIV_NET_ID}" \
        --cloud-project "${OVH_PROJECT_ID}" \
        2>/dev/null || warn "Private network delete failed or already removed (retry in OVH console if needed)"
    ok "Private network deleted"
else
    warn "PRIV_NET_ID not set and network '${PRIV_NET_NAME:-tes-private-net}' not found; skipping private network deletion"
fi

# ── 9. Delete S3 bucket (and all contents)
# The bucket was created via 'aws s3api create-bucket' using the cloud user's
# own RadosGW credentials (so the user owns it). Must delete the same way —
# ovhcloud CLI lists/deletes under a different identity and won't find it.
if [ -n "${OVH_S3_ACCESS_KEY:-}" ] && [ -n "${OVH_S3_SECRET_KEY:-}" ]; then
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
        echo "Deleting all objects in S3 bucket '${OVH_S3_BUCKET}'..."
        AWS_ACCESS_KEY_ID="${OVH_S3_ACCESS_KEY}" \
        AWS_SECRET_ACCESS_KEY="${OVH_S3_SECRET_KEY}" \
        AWS_DEFAULT_REGION="${OVH_S3_REGION}" \
        aws s3 --endpoint-url "${OVH_S3_ENDPOINT}" \
            rm "s3://${OVH_S3_BUCKET}" --recursive 2>/dev/null \
            || warn "Bucket may already be empty or recursive rm failed"
        echo "Deleting S3 bucket '${OVH_S3_BUCKET}'..."
        AWS_ACCESS_KEY_ID="${OVH_S3_ACCESS_KEY}" \
        AWS_SECRET_ACCESS_KEY="${OVH_S3_SECRET_KEY}" \
        AWS_DEFAULT_REGION="${OVH_S3_REGION}" \
        aws s3api --endpoint-url "${OVH_S3_ENDPOINT}" \
            delete-bucket --bucket "${OVH_S3_BUCKET}" 2>/dev/null \
            && ok "S3 bucket deleted" \
            || warn "Bucket delete failed or already removed"
    else
        warn "S3 bucket '${OVH_S3_BUCKET}' not found in user's bucket list; skipping"
    fi
else
    warn "OVH_S3_ACCESS_KEY / OVH_S3_SECRET_KEY not set; cannot delete S3 bucket"
    warn "Delete manually: OVH console → Public Cloud → Storage → Object Storage"
fi

# ── 10. Delete S3 credentials for the prereq user
# OVH limits the number of S3 credentials per user; deleting them here frees
# the slot for a clean re-install. The bucket is already gone at this point.
# If OVH_S3_ACCESS_KEY was not saved to env.variables (older installs), look
# it up from the OVH API (the secret is not re-exposed, only the access key).
if [ -z "${OVH_S3_ACCESS_KEY:-}" ] && [ -n "${KUBE_USER_ID:-}" ]; then
    echo "OVH_S3_ACCESS_KEY not in env — looking up from OVH API..."
    OVH_S3_ACCESS_KEY=$(ovhcloud cloud storage-s3 credentials list \
        "${KUBE_USER_ID}" \
        --cloud-project "${OVH_PROJECT_ID}" \
        -o json 2>/dev/null \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, dict) and 'details' in data: data = data['details']
if isinstance(data, list) and len(data) > 0:
    print(data[0].get('access',''))
elif isinstance(data, dict):
    print(data.get('access',''))
" 2>/dev/null || true)
    [ -n "${OVH_S3_ACCESS_KEY:-}" ] \
        && echo "  Found access key: ${OVH_S3_ACCESS_KEY:0:8}..." \
        || warn "Could not look up S3 credentials for user ${KUBE_USER_ID} — may already be deleted"
fi

if [ -n "${KUBE_USER_ID:-}" ] && [ -n "${OVH_S3_ACCESS_KEY:-}" ]; then
    echo "Deleting S3 credentials for user ${KUBE_USER_ID} (access: ${OVH_S3_ACCESS_KEY:0:8}...)..."
    ovhcloud cloud storage-s3 credentials delete \
        "${KUBE_USER_ID}" \
        "${OVH_S3_ACCESS_KEY}" \
        --cloud-project "${OVH_PROJECT_ID}" 2>/dev/null \
        && ok "S3 credentials deleted" \
        || warn "S3 credentials delete failed or already removed"
else
    warn "KUBE_USER_ID or OVH_S3_ACCESS_KEY not set; skipping S3 credential cleanup"
fi

# ── 11. Prerequisite OVH cloud user — intentionally NOT deleted
# KUBE_USER_ID is the user created in OVH Manager before installation.
# It owns the OpenStack + Keystone credentials; deleting it here would break
# any existing clouds.yaml the operator may still need.
warn "KUBE_USER_ID (${KUBE_USER_ID:-<not set>}) is the prerequisite OVH cloud user. Not deleted."
warn "To delete it manually: OVH Manager → Public Cloud → Users & Roles → delete the user"

# ── 12. Remove kubeconfig
rm -f "${KUBECONFIG_PATH}" && ok "Kubeconfig removed" || true

echo ""
ok "Teardown complete. Check OVH console to confirm all resources are gone."
echo ""
echo "Cost-incurring resources to verify in OVH console:"
echo "  - Public Cloud → Managed Kubernetes          (no cluster should remain)"
echo "  - Public Cloud → Storage → File Storage      (no Manila share should remain)"
echo "  - Public Cloud → Network → Private Networks  (tes-private-net deleted)"
echo "  - Public Cloud → Storage → Object Storage    (no bucket)"
echo "  - Public Cloud → Managed Private Registries  (no MPR should remain)"
echo "  - Public Cloud → Instances                   (none after cluster delete)"
echo "  - Public Cloud → Network → Load Balancers    (deleted with cluster, verify)"

