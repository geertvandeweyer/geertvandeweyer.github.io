#!/usr/bin/env bash
# update-nodepool-flavors.sh — regenerate and apply the Karpenter 'workers' NodePool
#
# Run this whenever your OVH vCPU/RAM quota changes, or after updating
# WORKER_FAMILIES / WORKER_MAX_VCPU / WORKER_MAX_RAM_GB in env.variables.
#
# Usage:
#   ./update-nodepool-flavors.sh [env.variables path]
#
# The script re-fetches available flavors from the OVH API, applies the same
# family + per-flavor vCPU/RAM filters as the main installer, resolves UUIDs,
# and patches the live Karpenter NodePool without touching anything else.
#
# After applying: Karpenter reconciles within ~30s, automatically re-evaluating
# all pending pods against the updated instance-type list.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-${SCRIPT_DIR}/env.variables}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: env.variables not found at $ENV_FILE" >&2
    exit 1
fi

# shellcheck source=env.variables
source "$ENV_FILE"

# Required vars
: "${OVH_PROJECT_ID:?}"
: "${FLAVOR_LOOKUP_REGION:?}"
: "${WORKER_FAMILIES:?}"
: "${KUBECONFIG_PATH:?}"
WORKER_MAX_VCPU="${WORKER_MAX_VCPU:-0}"
WORKER_MAX_RAM_GB="${WORKER_MAX_RAM_GB:-0}"
OVH_VCPU_QUOTA="${OVH_VCPU_QUOTA:-100}"
OVH_RAM_QUOTA_GB="${OVH_RAM_QUOTA_GB:-400}"
export KUBECONFIG="$KUBECONFIG_PATH"

echo "=== Karpenter NodePool flavor refresh ==="
echo "  Families  : $WORKER_FAMILIES"
echo "  Max vCPU  : ${WORKER_MAX_VCPU:-unlimited} (per flavor)"
echo "  Max RAM   : ${WORKER_MAX_RAM_GB:-unlimited} GB (per flavor)"
echo "  vCPU quota: $OVH_VCPU_QUOTA total → NodePool limit $((OVH_VCPU_QUOTA - 2)) vCPU"
echo "  RAM quota : $OVH_RAM_QUOTA_GB GB total → NodePool limit $((OVH_RAM_QUOTA_GB - 4)) Gi"
echo ""

# ── 1. Fetch reference flavor list ───────────────────────────────────────────
echo "Fetching reference flavors (region: ${FLAVOR_LOOKUP_REGION})..."

# Prefer ovhcloud CLI if available; fall back to openstack CLI.
if command -v ovhcloud &>/dev/null; then
    FLAVORS_JSON=$(ovhcloud cloud reference list-flavors \
        --cloud-project "${OVH_PROJECT_ID}" \
        --region "${FLAVOR_LOOKUP_REGION}" \
        -o json 2>/dev/null)
    # ovhcloud returns ram as GB
    RAM_UNIT="GB"
elif command -v openstack &>/dev/null; then
    echo "  (ovhcloud CLI not found — using openstack CLI as fallback)"
    # openstack flavor list --all returns all flavors (including unlisted memory-optimised tiers).
    # Convert table output → JSON array with fields matching ovhcloud schema.
    FLAVORS_JSON=$(
        OS_AUTH_URL="${OS_AUTH_URL}" \
        OS_USERNAME="${OS_USERNAME}" \
        OS_PASSWORD="${OS_PASSWORD}" \
        OS_TENANT_ID="${OS_TENANT_ID}" \
        OS_REGION_NAME="${OS_REGION_NAME}" \
        OS_USER_DOMAIN_NAME="${OS_USER_DOMAIN_NAME:-Default}" \
        OS_PROJECT_DOMAIN_NAME="${OS_PROJECT_DOMAIN_NAME:-Default}" \
        OS_IDENTITY_API_VERSION=3 \
        openstack flavor list --all -f json 2>/dev/null \
        | python3 -c "
import json, sys
rows = json.load(sys.stdin)
out = []
for r in rows:
    out.append({'name': r.get('Name',''), 'vcpus': r.get('VCPUs',0), 'ram': r.get('RAM',0)})
print(json.dumps(out))
"
    )
    # openstack returns ram as MB
    RAM_UNIT="MB"
else
    echo "ERROR: Neither 'ovhcloud' nor 'openstack' CLI found. Install one and retry." >&2
    exit 1
fi

if [[ -z "$FLAVORS_JSON" || "$FLAVORS_JSON" == "[]" ]]; then
    echo "ERROR: Failed to fetch flavor list from OVH API" >&2
    exit 1
fi

# ── 3. Generate NodePool YAML ─────────────────────────────────────────────────
echo "Computing eligible flavors..."
# Write JSON data to a temp file to avoid heredoc variable-expansion issues.
FLAVORS_TMP=$(mktemp --suffix=.json)
printf '%s' "$FLAVORS_JSON" > "$FLAVORS_TMP"

NODEPOOL_YAML=$(WORKER_MAX_VCPU="$WORKER_MAX_VCPU" \
  WORKER_MAX_RAM_GB="$WORKER_MAX_RAM_GB" \
  OVH_VCPU_QUOTA="$OVH_VCPU_QUOTA" \
  OVH_RAM_QUOTA_GB="$OVH_RAM_QUOTA_GB" \
  EXCLUDE_TYPES="${EXCLUDE_TYPES:-a10,h100,rtx5000,i1,win,t1,t2,flex}" \
  python3 - "$WORKER_FAMILIES" "$FLAVORS_TMP" << 'PYEOF'
import json, sys, os

families_str = sys.argv[1]
# Read JSON from temp file (safe — no shell-expansion issues)
with open(sys.argv[2]) as fh:
    flavors_raw = json.load(fh)

data = flavors_raw
if isinstance(data, dict) and 'details' in data:
    data = data['details']
if not isinstance(data, list):
    data = [data]

families    = [f.strip() for f in families_str.split(',')]
# EXCLUDE_TYPES: comma-separated prefixes/substrings to exclude from flavor selection.
# Defaults cover OVH GPU (a10,h100,rtx5000), NVMe-backed (i1), Windows (win),
# Tesla GPU (t1,t2), and -flex variants.
# Override via EXCLUDE_TYPES in env.variables to add/remove entries.
_exclude_env = os.environ.get('EXCLUDE_TYPES', 'a10,h100,rtx5000,i1,win,t1,t2,flex')
skip        = [x.strip() for x in _exclude_env.split(',') if x.strip()]
max_vcpu    = int(os.environ.get('WORKER_MAX_VCPU',   '0') or '0')
max_ram_gb  = int(os.environ.get('WORKER_MAX_RAM_GB', '0') or '0')
vcpu_quota  = int(os.environ.get('OVH_VCPU_QUOTA',   '100') or '100')
ram_quota_gb= int(os.environ.get('OVH_RAM_QUOTA_GB', '400') or '400')
limit_cpu   = max(1, vcpu_quota    - 2)
limit_mem_gi= max(1, ram_quota_gb  - 4)

names = []
for item in data:
    name   = item.get('name', '')
    vcpus  = item.get('vcpus', 0)
    ram_gb = item.get('ram', 0)
    # Adjust RAM from MB → GB if needed (openstack CLI output)
    if os.environ.get('RAM_UNIT', 'GB') == 'MB':
        ram_gb = ram_gb / 1024
    name_lower = name.lower()
    if any(name.startswith(f + '-') for f in families) and vcpus > 0:
        if not any(name_lower.startswith(x) or name_lower.endswith('-' + x) for x in skip):
            if (max_vcpu   == 0 or vcpus  <= max_vcpu) and \
               (max_ram_gb == 0 or ram_gb <= max_ram_gb):
                names.append((name, vcpus, ram_gb))
names.sort()

if not names:
    print("ERROR: no matching flavors found!", file=sys.stderr)
    sys.exit(1)

print(f"  Found {len(names)} eligible flavors:", file=sys.stderr)
for n, v, r in names:
    print(f"    {n:20s}  {v:3d} vCPU  {r:.0f} GB RAM", file=sys.stderr)

# OVH Karpenter provider uses flavor NAMES (e.g. "c3-8") as InstanceType.Name.
# See: karpenter-provider-ovhcloud/pkg/cloudprovider/cloudprovider.go
values = [f'            - "{n}"  # {n} ({v}vCPU {r:.0f}GB)' for n, v, r in names]

print(f"""apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: workers
spec:
  template:
    metadata:
      labels:
        nodepool: workers
    spec:
      nodeClassRef:
        group: karpenter.ovhcloud.sh
        kind: OVHNodeClass
        name: default
      requirements:
        - key: "kubernetes.io/arch"
          operator: In
          values:
            - "amd64"
        - key: "node.kubernetes.io/instance-type"
          operator: In
          values:
{chr(10).join(values)}
  limits:
    cpu: "{limit_cpu}"
    memory: "{limit_mem_gi}Gi"
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 5m
""")
PYEOF
)
#rm -f "$FLAVORS_TMP"

# ── 4. Apply ──────────────────────────────────────────────────────────────────
echo ""
echo "Applying updated NodePool to cluster..."
echo "$NODEPOOL_YAML" | kubectl apply --server-side --force-conflicts -f -
echo ""
echo "=== Done. Karpenter will reconcile within ~30s. ==="
echo "  Monitor: kubectl get nodeclaim -w"
echo "  Logs   : kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter-karpenter-provider-ovhcloud -f"
