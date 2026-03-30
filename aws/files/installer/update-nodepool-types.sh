#!/usr/bin/env bash
# update-nodepool-types.sh — regenerate and apply the Karpenter 'workload' NodePool
#
# Run this whenever your AWS Spot quota changes, or after updating
# WORKER_INSTANCE_FAMILIES / WORKER_EXCLUDE_TYPES / WORKER_MAX_VCPU /
# WORKER_MAX_RAM_GIB / SPOT_QUOTA in env.variables.
#
# The script fetches available Spot-eligible instance types from EC2, applies
# the same family + generation + per-type filters as the main installer, and
# patches the live Karpenter NodePool without touching anything else.
#
# After applying: Karpenter reconciles within ~30s, automatically re-evaluating
# all pending pods against the updated instance-type list.
#
# Usage:
#   ./update-nodepool-types.sh [path/to/env.variables]
#
# Expected output from `aws ec2 describe-instance-types` (used internally):
#   JSON array: [{"Type":"c5.xlarge","VCPU":4,"MemoryMiB":8192}, ...]
#   Query used: InstanceTypes[*].{Type:InstanceType,VCPU:VCpuInfo.DefaultVCpus,MemoryMiB:MemoryInfo.SizeInMiB}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-${SCRIPT_DIR}/env.variables}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: env.variables not found at $ENV_FILE" >&2
    exit 1
fi

# shellcheck source=env.variables
source "$ENV_FILE"

# ── Resolve derived variables ─────────────────────────────────────────────────

# AWS_ACCOUNT_ID: read from env or resolve from STS
# Expected: aws sts get-caller-identity → {"Account":"123456789012",...}
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity \
    --query Account --output text 2>/dev/null || echo '')}"
[[ -z "$AWS_ACCOUNT_ID" ]] && { echo "ERROR: cannot resolve AWS_ACCOUNT_ID" >&2; exit 1; }

# SPOT_QUOTA: read from env or resolve from Service Quotas
# Expected: list-service-quotas → {"Quotas":[{...,"Value":100.0,...}]}
# Parse: --query "Quotas[...].Value" --output text → "100.0" (float) → awk int()
if [[ -z "${SPOT_QUOTA:-}" ]]; then
    SPOT_QUOTA=$(aws service-quotas list-service-quotas \
        --service-code ec2 \
        --region "${AWS_DEFAULT_REGION}" \
        --query "Quotas[?QuotaName=='All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests'].Value" \
        --output text 2>/dev/null | awk '{print int($1)}' || echo "100")
fi
SPOT_QUOTA="${SPOT_QUOTA:-100}"

# Required vars
: "${CLUSTER_NAME:?CLUSTER_NAME not set in env.variables}"
: "${AWS_DEFAULT_REGION:?AWS_DEFAULT_REGION not set in env.variables}"
: "${WORKER_INSTANCE_FAMILIES:?WORKER_INSTANCE_FAMILIES not set in env.variables}"

# Optional with defaults
WORKER_MIN_GENERATION="${WORKER_MIN_GENERATION:-3}"
WORKER_EXCLUDE_TYPES="${WORKER_EXCLUDE_TYPES:-metal,nano,micro,small,flex}"
WORKER_MAX_VCPU="${WORKER_MAX_VCPU:-0}"
WORKER_MAX_RAM_GIB="${WORKER_MAX_RAM_GIB:-0}"
WORKER_MIN_MEMORY_MIB="${WORKER_MIN_MEMORY_MIB:-4096}"
WORKER_ARCH="${WORKER_ARCH:-amd64}"          # amd64 | arm64/graviton | both
WORKER_CPU_VENDOR="${WORKER_CPU_VENDOR:-both}"  # intel | amd | both  (amd64 only)

echo "=== Karpenter NodePool instance-type refresh ==="
echo "  Families    : $WORKER_INSTANCE_FAMILIES"
echo "  Min gen     : >= $WORKER_MIN_GENERATION"
  echo "  Exclude     : $WORKER_EXCLUDE_TYPES"
  echo "  Max vCPU    : ${WORKER_MAX_VCPU} (0 = no cap)"
  echo "  Max RAM     : ${WORKER_MAX_RAM_GIB} GiB (0 = no cap)"
  echo "  Min memory  : ${WORKER_MIN_MEMORY_MIB} MiB"
  echo "  Architecture: ${WORKER_ARCH}  (amd64 | arm64/graviton | both)"
  echo "  CPU vendor  : ${WORKER_CPU_VENDOR}  (intel | amd | both — amd64 only)"
echo "  Spot quota  : $SPOT_QUOTA vCPU → NodePool cpu limit: $((SPOT_QUOTA - 2))"
echo ""

# ── 1. Fetch available spot instance types ────────────────────────────────────
#
# Command: aws ec2 describe-instance-types
# Filter:  supported-usage-class=spot  → only types available as Spot in this region
# Query:   projects to a flat list of {Type, VCPU, MemoryMiB} objects
# Output:  JSON array, e.g.
#   [{"Type":"c5.xlarge","VCPU":4,"MemoryMiB":8192}, ...]
# Note: the response is paginated; --output json fetches all pages automatically
#       when the query projects to a list (no --page-size needed for typical use).
#
echo "Fetching available Spot instance types (region: ${AWS_DEFAULT_REGION})..."
TYPES_JSON=$(aws ec2 describe-instance-types \
    --region "${AWS_DEFAULT_REGION}" \
    --filters "Name=supported-usage-class,Values=spot" \
    --query "InstanceTypes[*].{Type:InstanceType,VCPU:VCpuInfo.DefaultVCpus,MemoryMiB:MemoryInfo.SizeInMiB}" \
    --output json 2>/dev/null)

if [[ -z "$TYPES_JSON" || "$TYPES_JSON" == "[]" ]]; then
    echo "ERROR: Failed to fetch instance types from EC2 API (region: ${AWS_DEFAULT_REGION})" >&2
    exit 1
fi

# ── 2. Filter and generate NodePool YAML ──────────────────────────────────────
echo "Computing eligible instance types..."

TYPES_TMP=$(mktemp --suffix=.json)
printf '%s' "$TYPES_JSON" > "$TYPES_TMP"

NODEPOOL_YAML=$(
    WORKER_MIN_GENERATION="$WORKER_MIN_GENERATION" \
    WORKER_EXCLUDE_TYPES="$WORKER_EXCLUDE_TYPES" \
    WORKER_MAX_VCPU="$WORKER_MAX_VCPU" \
    WORKER_MAX_RAM_GIB="$WORKER_MAX_RAM_GIB" \
    WORKER_MIN_MEMORY_MIB="$WORKER_MIN_MEMORY_MIB" \
    WORKER_ARCH="$WORKER_ARCH" \
    WORKER_CPU_VENDOR="$WORKER_CPU_VENDOR" \
    SPOT_QUOTA="$SPOT_QUOTA" \
    python3 - "$WORKER_INSTANCE_FAMILIES" "$TYPES_TMP" << 'PYEOF'
import json, sys, os, re

families_str = sys.argv[1]

# Read instance types from temp file (avoids shell heredoc expansion issues)
with open(sys.argv[2]) as fh:
    types_raw = json.load(fh)

# Parse configuration from environment
families    = [f.strip().lower() for f in families_str.split(',') if f.strip()]
exclude     = [x.strip().lower() for x in
               os.environ.get('WORKER_EXCLUDE_TYPES', 'metal,nano,micro,small,flex').split(',')
               if x.strip()]
min_gen     = int(os.environ.get('WORKER_MIN_GENERATION', '3') or '3')
max_vcpu    = int(os.environ.get('WORKER_MAX_VCPU',       '0') or '0')
max_ram_gib = int(os.environ.get('WORKER_MAX_RAM_GIB',    '0') or '0')
min_mem_mib = int(os.environ.get('WORKER_MIN_MEMORY_MIB', '4096') or '4096')
spot_quota  = int(os.environ.get('SPOT_QUOTA',            '100') or '100')
arch        = os.environ.get('WORKER_ARCH',       'amd64').lower()
cpu_vendor  = os.environ.get('WORKER_CPU_VENDOR', 'both').lower()
limit_cpu   = max(1, spot_quota - 2)

# EC2 instance type name pattern:
#   <family><generation>[<suffix>].<size>
#   Examples: c5.xlarge, m6i.2xlarge, r7g.metal, t3.nano, c6in.4xlarge
PATTERN = re.compile(r'^([a-z]+)(\d+)([a-z]*)\.(.+)$')

selected = []
for item in types_raw:
    itype   = item.get('Type', '')
    vcpus   = item.get('VCPU', 0) or 0
    mem_mib = item.get('MemoryMiB', 0) or 0

    m = PATTERN.match(itype)
    if not m:
        continue
    family  = m.group(1)   # e.g. "c", "m", "r", "t"
    gen_str = m.group(2)   # e.g. "5", "6"
    suffix  = m.group(3)   # e.g. "", "g", "i", "a", "gd", "n", "gn"
    gen     = int(gen_str)
    mem_gib = mem_mib / 1024.0

    # Processor architecture derived from instance suffix:
    #   'g' in suffix → Graviton (arm64), e.g. m6g, c7gn
    #   'a' in suffix (non-graviton) → AMD x86-64, e.g. m5a, c6a
    #   otherwise → Intel x86-64, e.g. c5, m6i
    is_graviton  = 'g' in suffix
    is_amd_cpu   = 'a' in suffix and not is_graviton
    is_intel_cpu = not is_graviton and not is_amd_cpu

    # Family filter: first letter of the type must be in the requested families
    if family[0] not in families:
        continue

    # Generation filter (inclusive: generation must be >= min_gen)
    if gen < min_gen:
        continue

    # Architecture / CPU-vendor filter
    if arch in ('arm64', 'graviton'):
        if not is_graviton:
            continue
    elif arch == 'amd64':
        if is_graviton:
            continue
        if cpu_vendor == 'intel' and not is_intel_cpu:
            continue
        if cpu_vendor == 'amd' and not is_amd_cpu:
            continue
    # arch == 'both'/'all': include everything

    # Exclude patterns: any substring match against the full type name
    if any(x in itype.lower() for x in exclude):
        continue

    # Minimum memory filter
    if mem_mib < min_mem_mib:
        continue

    # Per-type vCPU cap (0 = no cap)
    if max_vcpu > 0 and vcpus > max_vcpu:
        continue

    # Per-type RAM cap in GiB (0 = no cap)
    if max_ram_gib > 0 and mem_gib > max_ram_gib:
        continue

    selected.append((itype, vcpus, mem_gib))

selected.sort()

if not selected:
    print("ERROR: no matching instance types found for families "
          f"'{families_str}' in this region!", file=sys.stderr)
    sys.exit(1)

print(f"  Found {len(selected)} eligible instance types:", file=sys.stderr)
for t, v, r in selected:
    print(f"    {t:30s}  {v:4d} vCPU   {r:7.1f} GiB RAM", file=sys.stderr)

# Generate the instance-type value list with inline comments for readability
values = [f'            - "{t}"  # {v}vCPU {r:.1f}GiB' for t, v, r in selected]

# Resolve arch values for the NodePool requirement
if arch in ('arm64', 'graviton'):
    arch_values = '["arm64"]'
elif arch == 'amd64':
    arch_values = '["amd64"]'
else:  # both / all
    arch_values = '["amd64", "arm64"]'

# Emit NodePool YAML.  The NodePool uses explicit instance-type names so
# Karpenter's scheduling is deterministic and easy to audit.
# - weight: 50 gives priority parity with any future system pool
# - expireAfter: 24h recycles long-running nodes to pick up AMI patches
# - consolidateAfter: 10m avoids premature scale-in on bursty workloads
print(f"""apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: workload
spec:
  weight: 50
  template:
    metadata:
      labels:
        workload-type: jobs
        role: workflow
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: workload
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: {arch_values}
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values:
{chr(10).join(values)}
      expireAfter: 24h
  limits:
    # Cap total Spot vCPU at (quota - 2) to reserve headroom for the system node.
    cpu: "{limit_cpu}"
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 10m
""")
PYEOF
)

rm -f "$TYPES_TMP"

# ── 3. Apply ──────────────────────────────────────────────────────────────────
echo ""
echo "Applying updated NodePool to cluster..."
# --server-side --force-conflicts lets us update a NodePool that was previously
# applied by a different field manager (e.g. kubectl or helm) without errors.
echo "$NODEPOOL_YAML" | kubectl apply --server-side --force-conflicts -f -
echo ""
echo "=== Done. Karpenter will reconcile within ~30s. ==="
