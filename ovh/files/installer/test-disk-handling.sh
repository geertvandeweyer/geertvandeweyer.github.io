#!/bin/bash
# =============================================================================
# test-disk-handling.sh
#
# End-to-end disk-handling test suite.
#
# What it does:
#   0. Records current Cinder volumes (baseline)
#   1. Temporarily reduces Karpenter consolidateAfter to 1m (test mode)
#   2. Submits 3 small Funnel tasks (quick, low resources):
#        A. hello        — basic pull + run (confirms containerd works)
#        B. disk-write   — writes 5GB, confirms Cinder LV is the data disk
#        C. nfs-check    — reads /mnt/shared, confirms NFS keepalive works
#   3. Waits for all tasks to complete
#   4. On the live worker node (via kubectl exec into funnel-disk-setup pod):
#        - Checks /var/lib/containerd is a symlink → /var/funnel-work/containerd
#        - Reports df for /var/funnel-work and /dev/sda1
#        - Checks autoscaler service status
#   5. Waits for Karpenter to reclaim the node (consolidateAfter=1m)
#   6. Checks that the node is gone and all Cinder volumes are deleted
#   7. Restores consolidateAfter to 5m
#
# Usage:
#   ./test-disk-handling.sh [--no-restore]
#
# Requirements:
#   - KUBECONFIG set or ~/.kube/ovh-tes.yaml present
#   - funnel CLI installed and reachable on $FUNNEL_SERVER
#   - openstack CLI available + creds in env.variables
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLES_DIR="${SCRIPT_DIR}/funnel_examples"
ENV_FILE="${SCRIPT_DIR}/env.variables"

# ─── Config ─────────────────────────────────────────────────────────────────
KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/ovh-tes.yaml}"
export KUBECONFIG

# NOTE: The OVH Octavia LB passes GET requests fine but silently drops the body
# on POST requests (connection reset after upload), so task submission fails
# through the external IP.  Use a kubectl port-forward to localhost instead.
# Override by setting FUNNEL_SERVER in your environment before running.
FUNNEL_PF_PORT="18000"
FUNNEL_SERVER="${FUNNEL_SERVER:-http://localhost:${FUNNEL_PF_PORT}}"
FUNNEL_NAMESPACE="funnel"
NODEPOOL_NAME="workers"

TEST_CONSOLIDATE_AFTER="1m"    # reduced for testing
PROD_CONSOLIDATE_AFTER="5m"    # restored afterwards

TASK_TIMEOUT_SEC=600           # 10 min max per task
NODE_DRAIN_WAIT_SEC=480        # 8 min: 1m consolidateAfter + drain ~30s + up to 360s Karpenter
                               # Cinder cleanup + OVH delete ~30s + margin
CLEANUP_WAIT_SEC=60            # 1 min extra wait after node gone (volumes deleted before VM now)

NO_RESTORE="${1:-}"

# ─── Colours ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; }
info() { echo -e "        $*"; }

# ─── Cleanup trap ────────────────────────────────────────────────────────────
FUNNEL_PF_PID=""
cleanup() {
  # Kill port-forward
  if [[ -n "$FUNNEL_PF_PID" ]]; then
    kill "$FUNNEL_PF_PID" 2>/dev/null || true
  fi
  # Restore Karpenter
  if [[ "$NO_RESTORE" != "--no-restore" ]]; then
    echo ""
    echo "Restoring consolidateAfter to ${PROD_CONSOLIDATE_AFTER}..."
    kubectl patch nodepool "${NODEPOOL_NAME}" --type=merge \
      -p "{\"spec\":{\"disruption\":{\"consolidateAfter\":\"${PROD_CONSOLIDATE_AFTER}\"}}}" \
      2>/dev/null || warn "Could not restore consolidateAfter — do it manually!"
    ok "consolidateAfter restored to ${PROD_CONSOLIDATE_AFTER}"
  fi
}
trap cleanup EXIT

# ─── OpenStack auth ──────────────────────────────────────────────────────────
load_openstack() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    export OS_AUTH_URL OS_TENANT_ID OS_USERNAME OS_PASSWORD OS_REGION_NAME \
           OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_NAME
    export OS_IDENTITY_API_VERSION=3
  else
    warn "env.variables not found — Cinder checks will be skipped"
  fi
}

# ─── Helper: submit a Funnel TES task, return task ID ───────────────────────
submit_task() {
  local task_file="$1"
  local task_name="$2"
  curl -sf -X POST "${FUNNEL_SERVER}/v1/tasks" \
    -H "Content-Type: application/json" \
    -d @"${task_file}" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])"
}

# ─── Helper: poll until task reaches terminal state ─────────────────────────
wait_for_task() {
  local task_id="$1"
  local timeout="$2"
  local elapsed=0
  local state=""
  while [[ $elapsed -lt $timeout ]]; do
    state=$(curl -sf "${FUNNEL_SERVER}/v1/tasks/${task_id}?view=MINIMAL" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])" 2>/dev/null || echo "UNKNOWN")
    case "$state" in
      COMPLETE)             return 0 ;;
      EXECUTOR_ERROR|SYSTEM_ERROR|CANCELED) return 1 ;;
    esac
    sleep 10
    elapsed=$((elapsed + 10))
  done
  warn "Task ${task_id} timed out after ${timeout}s (state: ${state})"
  return 2
}

# ─── Helper: get Cinder volume IDs (funnel-* only) ──────────────────────────
list_cinder_volumes() {
  openstack volume list --format value -c ID -c Name -c Status 2>/dev/null \
    | grep "funnel-" | awk '{print $1, $2, $3}'
}

# =============================================================================
echo ""
echo "================================================================="
echo "  Funnel Disk-Handling Test Suite"
echo "  $(date)"
echo "================================================================="
echo ""

# ─── Start port-forward ───────────────────────────────────────────────────────
# The OVH Octavia LoadBalancer silently drops POST request bodies (connection
# reset after upload completes), so task submission through the external IP
# always fails. We port-forward to localhost instead.
echo "── Port-forward: localhost:${FUNNEL_PF_PORT} → funnel svc :8000 ─"
kubectl port-forward -n "${FUNNEL_NAMESPACE}" svc/tes-service \
  "${FUNNEL_PF_PORT}:8000" &>/tmp/funnel-pf.log &
FUNNEL_PF_PID=$!
# Wait until the port-forward is accepting connections (max 15s)
PF_WAIT=0
until curl -sf "http://localhost:${FUNNEL_PF_PORT}/v1/tasks" >/dev/null 2>&1; do
  PF_WAIT=$((PF_WAIT+1))
  if [[ $PF_WAIT -ge 15 ]]; then
    fail "Port-forward failed to start after 15s. Check kubectl connectivity."
    cat /tmp/funnel-pf.log
    exit 1
  fi
  sleep 1
done
ok "Port-forward ready (pid ${FUNNEL_PF_PID}) — using ${FUNNEL_SERVER}"
echo ""


# ─── Step 0: Baseline Cinder volumes ─────────────────────────────────────────
echo "── Step 0: Baseline Cinder volumes ──────────────────────────────"
load_openstack
BASELINE_VOLUMES=""
if command -v openstack &>/dev/null; then
  BASELINE_VOLUMES=$(list_cinder_volumes || true)
  if [[ -n "$BASELINE_VOLUMES" ]]; then
    BASELINE_COUNT=$(echo "$BASELINE_VOLUMES" | wc -l)
    warn "${BASELINE_COUNT} pre-existing funnel Cinder volume(s) found:"
    echo "$BASELINE_VOLUMES" | while read -r line; do info "  $line"; done
    echo ""
    echo "  These are LEFTOVER volumes from previous runs (cleanup bug)."
    echo "  Test will track NEW volumes created during this run."
  else
    ok "No pre-existing funnel Cinder volumes — clean baseline."
  fi
else
  warn "openstack CLI not available — Cinder tracking skipped"
fi
echo ""

# ─── Step 1: Reduce consolidateAfter for testing ─────────────────────────────
echo "── Step 1: Set Karpenter consolidateAfter=${TEST_CONSOLIDATE_AFTER} ──"
kubectl patch nodepool "${NODEPOOL_NAME}" --type=merge \
  -p "{\"spec\":{\"disruption\":{\"consolidateAfter\":\"${TEST_CONSOLIDATE_AFTER}\"}}}"
ok "consolidateAfter set to ${TEST_CONSOLIDATE_AFTER} (was ${PROD_CONSOLIDATE_AFTER})"
echo ""

# ─── Step 2: Submit test tasks ───────────────────────────────────────────────
echo "── Step 2: Submit tasks ─────────────────────────────────────────"

# Task A: Hello world — confirms basic Funnel/nerdctl/containerd path
TASK_A_FILE="${EXAMPLES_DIR}/hello.json"
TASK_A_ID=$(submit_task "$TASK_A_FILE" "hello")
ok "Task A (hello):      ${TASK_A_ID}"

# Task B: Disk write — confirms workdir goes to Cinder LV
TASK_B_FILE="${EXAMPLES_DIR}/disk-write-test.json"
TASK_B_ID=$(submit_task "$TASK_B_FILE" "disk-write")
ok "Task B (disk-write): ${TASK_B_ID}"

# Task C: NFS check — verifies that NFS is actually accessible INSIDE the
# nerdctl container (not just in the worker pod).
#
# IMPORTANT: "ls /mnt/shared" from inside the container is NOT sufficient —
# the hostPath bind creates an empty mountpoint, so ls always succeeds even
# without a real NFS mount.
#
# The correct check is the filesystem type in /proc/mounts.  The hostPath bind
# appears as the underlying disk fs (ext4/xfs) when NFS is absent; it becomes
# nfs/nfs4 once the DaemonSet holder has completed the mount.  We also list
# /mnt/shared top-level contents for informational purposes.
NFS_CHECK_JSON=$(mktemp /tmp/nfs-check-XXXXXX.json)
cat > "$NFS_CHECK_JSON" << 'NFS_EOF'
{
  "name": "nfs-check",
  "description": "Verifies NFS mount is real inside the nerdctl container (not just the worker pod).",
  "resources": { "cpu_cores": 1, "ram_gb": 0.5, "disk_gb": 1.0 },
  "executors": [{
    "image": "alpine:3.19",
    "command": ["/bin/sh", "-c",
      "set -e\n\necho '=== /proc/mounts type check ==='\nif grep -qE '^[^ ]+ /mnt/shared nfs' /proc/mounts; then\n  echo '[PASS] /mnt/shared is a real NFS mount inside the container:'\n  grep '/mnt/shared' /proc/mounts\nelse\n  echo '[FAIL] /mnt/shared is NOT an NFS mount inside the container!'\n  echo '  fs type seen (should be nfs/nfs4):'\n  grep '/mnt/shared' /proc/mounts || echo '  (no /mnt/shared entry at all)'\n  exit 1\nfi\n\necho ''\necho '=== Top-level contents (informational) ==='\nls /mnt/shared | head -20 || true\n\necho ''\necho '=== NFS check PASSED ==='"],
    "workdir": "/tmp"
  }],
  "volumes": ["/mnt/shared"]
}
NFS_EOF
TASK_C_ID=$(submit_task "$NFS_CHECK_JSON" "nfs-check")
rm -f "$NFS_CHECK_JSON"
ok "Task C (nfs-check):  ${TASK_C_ID}"
echo ""

# Task D: NFS race-condition probe — submitted immediately after A/B/C, before
# the node is up, so if Karpenter provisions a NEW node for this batch we can
# confirm that wait-for-nfs actually blocks until the holder has the NFS mount.
# Uses the same NFS check but also prints the init-container timing via the
# Funnel task logs (stdout shows wall-clock time of when the task started).
NFS_RACE_JSON=$(mktemp /tmp/nfs-race-XXXXXX.json)
cat > "$NFS_RACE_JSON" << 'NFS_EOF'
{
  "name": "nfs-race-probe",
  "description": "Probes NFS availability timing on a potentially fresh node.",
  "resources": { "cpu_cores": 1, "ram_gb": 0.5, "disk_gb": 1.0 },
  "executors": [{
    "image": "alpine:3.19",
    "command": ["/bin/sh", "-c",
      "echo 'Container started at: '$(date -Iseconds)\nif grep -qE '^[^ ]+ /mnt/shared nfs' /proc/mounts; then\n  echo '[PASS] NFS confirmed (nfs/nfs4 type) inside container at container-start time.'\n  grep '/mnt/shared' /proc/mounts\nelse\n  echo '[FAIL] /mnt/shared is NOT an NFS mount inside the container!'\n  echo 'Race condition confirmed: wait-for-nfs did not block long enough.'\n  echo 'fs type seen (should be nfs/nfs4):'\n  grep '/mnt/shared' /proc/mounts || echo '(no /mnt/shared entry)'\n  exit 1\nfi"],
    "workdir": "/tmp"
  }],
  "volumes": ["/mnt/shared"]
}
NFS_EOF
TASK_D_ID=$(submit_task "$NFS_RACE_JSON" "nfs-race-probe")
rm -f "$NFS_RACE_JSON"
ok "Task D (nfs-race):   ${TASK_D_ID}"
echo ""

# ─── Step 3: Wait for node to appear ─────────────────────────────────────────
echo "── Step 3: Wait for worker node to appear ───────────────────────"
NODE_WAIT=0
WORKER_NODE=""
while [[ $NODE_WAIT -lt 300 ]]; do
  WORKER_NODE=$(kubectl get nodes -l "karpenter.sh/nodepool=${NODEPOOL_NAME}" \
    --no-headers -o name 2>/dev/null | head -1 || true)
  if [[ -n "$WORKER_NODE" ]]; then
    ok "Worker node appeared: ${WORKER_NODE}"
    break
  fi
  sleep 10
  NODE_WAIT=$((NODE_WAIT + 10))
done
if [[ -z "$WORKER_NODE" ]]; then
  fail "No worker node appeared within 5 minutes."
  exit 1
fi

# Wait for the funnel-disk-setup DaemonSet pod to become Ready on this node.
# The pod starts in Init:0/1 (setup.sh running: creates + attaches Cinder volume)
# and only transitions to Running AFTER setup.sh exits 0, which guarantees:
#   • /var/lib/funnel-autoscaler-volumes has been written with the initial volume ID
#   • the autoscaler.sh systemd service has been started on the host
# The previous approach (sleep 15) was a race condition: the Node object can
# appear in Kubernetes minutes before setup.sh finishes, causing the state file
# to appear empty or missing when Step 5 reads it.
WORKER_NODE_NAME="${WORKER_NODE#node/}"
info "Waiting for funnel-disk-setup pod on ${WORKER_NODE_NAME} to become Ready..."
DS_POD=""
DS_PHASE=""
DS_INIT_EXIT=""
DS_WAIT=0
while [[ $DS_WAIT -lt 600 ]]; do
  DS_POD=$(kubectl get pods -n "${FUNNEL_NAMESPACE}" -l app=funnel-disk-setup \
    --field-selector "spec.nodeName=${WORKER_NODE_NAME}" \
    --no-headers -o name 2>/dev/null | head -1 || true)
  if [[ -n "$DS_POD" ]]; then
    DS_PHASE=$(kubectl get -n "${FUNNEL_NAMESPACE}" "${DS_POD}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    DS_INIT_EXIT=$(kubectl get -n "${FUNNEL_NAMESPACE}" "${DS_POD}" \
      -o jsonpath='{.status.initContainerStatuses[0].state.terminated.exitCode}' \
      2>/dev/null || echo "")
    if [[ "$DS_PHASE" == "Running" || "$DS_INIT_EXIT" == "0" ]]; then
      ok "funnel-disk-setup pod Ready: ${DS_POD} (phase=${DS_PHASE})"
      break
    fi
    info "  ${DS_POD}: phase=${DS_PHASE:-Pending} init-exit=${DS_INIT_EXIT:-running} — waiting..."
  else
    info "  no funnel-disk-setup pod on ${WORKER_NODE_NAME} yet — waiting..."
  fi
  sleep 10
  DS_WAIT=$((DS_WAIT + 10))
done
if [[ -z "$DS_POD" ]]; then
  fail "No funnel-disk-setup pod appeared on ${WORKER_NODE_NAME} within 10 min — aborting."
  exit 1
fi
if [[ "$DS_PHASE" != "Running" && "$DS_INIT_EXIT" != "0" ]]; then
  warn "funnel-disk-setup pod not Ready after 10 min — state file may be incomplete."
fi

# Informational: show newly provisioned volume(s) via OpenStack diff (for debugging).
# The authoritative volume list comes from the state file read in Step 5.
if command -v openstack &>/dev/null; then
  AFTER_PROVISION_VOLUMES=$(list_cinder_volumes || true)
  NEW_VOLUMES_INFO=$(comm -13 \
    <(echo "$BASELINE_VOLUMES" | awk '{print $1}' | sort) \
    <(echo "$AFTER_PROVISION_VOLUMES" | awk '{print $1}' | sort))
  if [[ -n "$NEW_VOLUMES_INFO" ]]; then
    ok "OpenStack: $(echo "$NEW_VOLUMES_INFO" | wc -l | tr -d ' ') new funnel-* volume(s) visible (informational)."
    echo "$NEW_VOLUMES_INFO" | while read -r vid; do info "  ${vid}"; done
  else
    info "OpenStack diff: no new funnel-* volumes visible yet (volume may still be attaching)."
  fi
fi
# TRACKED_VOLUMES is populated in Step 5 from the authoritative host state file.
TRACKED_VOLUMES=""
echo ""

# ─── Step 4: Wait for tasks to complete ──────────────────────────────────────
echo "── Step 4: Wait for tasks to complete ──────────────────────────"
TASK_A_OK=false; TASK_B_OK=false; TASK_C_OK=false; TASK_D_OK=false

wait_for_task "$TASK_A_ID" $TASK_TIMEOUT_SEC && TASK_A_OK=true || true
[[ "$TASK_A_OK" == "true" ]] && ok "Task A (hello)       COMPLETE" || fail "Task A (hello)       FAILED"

wait_for_task "$TASK_B_ID" $TASK_TIMEOUT_SEC && TASK_B_OK=true || true
[[ "$TASK_B_OK" == "true" ]] && ok "Task B (disk-write)  COMPLETE" || fail "Task B (disk-write)  FAILED"

wait_for_task "$TASK_C_ID" $TASK_TIMEOUT_SEC && TASK_C_OK=true || true
[[ "$TASK_C_OK" == "true" ]] && ok "Task C (nfs-check)   COMPLETE" || fail "Task C (nfs-check)   FAILED (see task logs — NFS not real inside container)"

wait_for_task "$TASK_D_ID" $TASK_TIMEOUT_SEC && TASK_D_OK=true || true
[[ "$TASK_D_OK" == "true" ]] && ok "Task D (nfs-race)    COMPLETE" || fail "Task D (nfs-race)    FAILED (wait-for-nfs race condition still present)"

# Print stderr/stdout for C and D to help diagnose NFS issues
for ID_LABEL in "${TASK_C_ID}:C-nfs-check" "${TASK_D_ID}:D-nfs-race"; do
  ID="${ID_LABEL%%:*}"; LABEL="${ID_LABEL##*:}"
  echo ""
  echo "  ── Task ${LABEL} logs ──"
  curl -sf "${FUNNEL_SERVER}/v1/tasks/${ID}?view=FULL" \
    | python3 -c "
import sys, json
t = json.load(sys.stdin)
for log in t.get('logs', []):
  for elog in log.get('logs', []):
    print('  STDOUT:', elog.get('stdout','').strip()[:800] or '(empty)')
    print('  STDERR:', elog.get('stderr','').strip()[:400] or '(empty)')
" 2>/dev/null || warn "Could not fetch logs for task ${ID}"
done
echo ""

# ─── Step 5: Inspect the live node via the DaemonSet pod ─────────────────────
echo "── Step 5: Inspect node disk layout ───────────────────────────"
# DS_POD was located and confirmed Ready in Step 3 — reuse it.
# Re-verify it is still Running in case of an unexpected pod restart between steps.
if [[ -n "$DS_POD" ]]; then
  _pod_phase=$(kubectl get -n "${FUNNEL_NAMESPACE}" "${DS_POD}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
  if [[ "$_pod_phase" != "Running" ]]; then
    warn "DS pod ${DS_POD} no longer Running (phase=${_pod_phase}) — re-querying..."
    DS_POD=$(kubectl get pods -n "${FUNNEL_NAMESPACE}" -l app=funnel-disk-setup \
      --field-selector "spec.nodeName=${WORKER_NODE_NAME}" \
      --no-headers -o name 2>/dev/null | head -1 || true)
  fi
fi

if [[ -n "$DS_POD" ]]; then
  info "DaemonSet pod: ${DS_POD}"
  echo ""
  echo "  ── df on host (via nsenter) ──"
  kubectl exec -n "${FUNNEL_NAMESPACE}" "${DS_POD}" -- \
    nsenter -t 1 --mount -- df -h /var/funnel-work /dev/sda1 2>/dev/null \
    | sed 's/^/    /' || warn "df failed"

  echo ""
  echo "  ── Cinder LV block device ──"
  LV_DEV=$(kubectl exec -n "${FUNNEL_NAMESPACE}" "${DS_POD}" -- \
    nsenter -t 1 --mount -- bash -c \
    "grep '/var/funnel-work' /proc/mounts | awk '{print \$1}'" 2>/dev/null || true)
  if [[ -n "$LV_DEV" ]]; then
    ok "Cinder LV mounted at /var/funnel-work: ${LV_DEV}"
  else
    fail "No Cinder LV mounted at /var/funnel-work — setup.sh failed"
  fi

  echo ""
  echo "  ── containerd symlink check ──"
  CONTAINERD_PATH=$(kubectl exec -n "${FUNNEL_NAMESPACE}" "${DS_POD}" -- \
    nsenter -t 1 --mount -- readlink -f /var/lib/containerd 2>/dev/null || echo "NOT_FOUND")
  if echo "$CONTAINERD_PATH" | grep -q "/var/funnel-work"; then
    ok "containerd is on Cinder LV: ${CONTAINERD_PATH}"
  else
    fail "containerd is NOT on Cinder LV — still at ${CONTAINERD_PATH} (v20 fix not active)"
  fi

  echo ""
  echo "  ── autoscaler + cleanup service status ──"
  # funnel-disk-cleanup is a systemd oneshot service invoked via preStop hook at
  # node shutdown. Seeing cleanup=inactive HERE is EXPECTED and correct — it means
  # the service has not run yet (node is still up).  Only cleanup=failed would
  # indicate a problem from a previous shutdown cycle.
  kubectl exec -n "${FUNNEL_NAMESPACE}" "${DS_POD}" -- \
    nsenter -t 1 --mount --pid -- systemctl is-active funnel-disk-autoscaler funnel-disk-cleanup 2>/dev/null \
    | paste - - | awk '{print "    autoscaler="$1"  cleanup="$2" (inactive=normal for oneshot)"}' \
    || warn "systemctl check failed"

  echo ""
  echo "  ── Volume state file (authoritative Cinder volume list) ──"
  # This is the DEFINITIVE list of volumes managed on this node.
  # setup.sh writes the initial volume ID here; autoscaler.sh appends extras.
  # cleanup.sh reads this to know what to detach+delete on shutdown.
  STATE_FILE_CONTENT=$(kubectl exec -n "${FUNNEL_NAMESPACE}" "${DS_POD}" -- \
    nsenter -t 1 --mount -- cat /var/lib/funnel-autoscaler-volumes 2>/dev/null || true)
  if [[ -n "$STATE_FILE_CONTENT" ]]; then
    VOL_COUNT=$(echo "$STATE_FILE_CONTENT" | grep -c '[a-f0-9-]' || true)
    ok "State file contains ${VOL_COUNT} volume ID(s) — these will be tracked for cleanup:"
    echo "$STATE_FILE_CONTENT" | while IFS= read -r vid; do
      [[ -z "$vid" ]] && continue
      # Cross-check each ID against OpenStack right now
      if command -v openstack &>/dev/null; then
        VOL_STATUS=$(openstack volume show "$vid" -f value -c status 2>/dev/null || echo "NOT_FOUND")
        info "  ${vid}  [OpenStack status: ${VOL_STATUS}]"
      else
        info "  ${vid}"
      fi
    done
    TRACKED_VOLUMES="$STATE_FILE_CONTENT"
  else
    fail "State file /var/lib/funnel-autoscaler-volumes is empty or missing — setup.sh did not complete!"
    TRACKED_VOLUMES=""
  fi
else
  warn "No funnel-disk-setup pod found — cannot inspect node"
fi
echo ""

# ─── Step 6: Wait for Karpenter to reclaim the node ──────────────────────────
echo "── Step 6: Wait for node drain + Karpenter Cinder cleanup ──────"
info "Waiting ${NODE_DRAIN_WAIT_SEC}s for Karpenter to reclaim node..."
info "(consolidateAfter=${TEST_CONSOLIDATE_AFTER} → drain → cleanupCinderVolumes() in Delete() → OVH delete)"
sleep $NODE_DRAIN_WAIT_SEC

echo ""
echo "  ── Node check ──"
REMAINING_NODE=$(kubectl get nodes -l "karpenter.sh/nodepool=${NODEPOOL_NAME}" \
  --no-headers -o name 2>/dev/null | head -1 || true)
if [[ -z "$REMAINING_NODE" ]]; then
  ok "Worker node is gone — Karpenter reclaimed it."
else
  warn "Worker node still present: ${REMAINING_NODE}"
  info "  Check Karpenter logs: kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter"
fi

echo ""
echo "  ── Cinder volume cleanup check ──"
sleep $CLEANUP_WAIT_SEC
# Gate on TRACKED_VOLUMES (read from the host state file in Step 5).
# This is authoritative: those exact IDs were managed by setup.sh/autoscaler.sh
# and should have been deleted by cleanup.sh before node shutdown.
ORPHANED=""
CLEANUP_OK=false
if [[ -z "$TRACKED_VOLUMES" ]]; then
  warn "No volumes were tracked (state file was empty/missing in Step 5) — cannot verify cleanup"
elif ! command -v openstack &>/dev/null; then
  warn "openstack CLI unavailable — cannot query volume status; volumes to check:"
  echo "$TRACKED_VOLUMES" | while IFS= read -r vid; do
    [[ -z "$vid" ]] && continue
    info "  ${vid} (status unknown)"
  done
else
  ORPHANED=""
  while IFS= read -r vid; do
    [[ -z "$vid" ]] && continue
    VOL_STATUS=$(openstack volume show "$vid" -f value -c status 2>/dev/null || echo "deleted")
    if [[ -z "$VOL_STATUS" || "$VOL_STATUS" == "deleted" || "$VOL_STATUS" == "NOT_FOUND" ]]; then
      ok "Volume ${vid} deleted — Karpenter cleanupCinderVolumes() succeeded"
    else
      ORPHANED="${ORPHANED}${vid} "
      fail "Volume ${vid} still exists (status: ${VOL_STATUS}) — Karpenter Cinder cleanup did NOT delete it!"
    fi
  done <<< "$TRACKED_VOLUMES"

  if [[ -z "$ORPHANED" ]]; then
    ok "ALL tracked Cinder volumes cleaned up — disk lifecycle is correct."
    CLEANUP_OK=true
  else
    fail "ORPHANED volumes remain: ${ORPHANED}"
    info "  To delete manually:"
    for vid in $ORPHANED; do
      info "    openstack volume delete ${vid}"
    done
  fi
fi

# ── Broad orphan scan: baseline diff catches funnel-* volumes NOT in state file ──
# Safety net for expand volumes created by autoscaler.sh whose IDs were never
# appended to the state file (e.g., autoscaler aborted before "echo $vol_id >>
# STATE_FILE" due to a prior curl/LVM error — see autoscaler.sh expand_disk()).
if command -v openstack &>/dev/null; then
  echo ""
  echo "  ── Broad orphan scan (all funnel-* volumes vs baseline) ──"
  FINAL_VOLUMES=$(list_cinder_volumes || true)
  EXTRA_VOLUMES=$(comm -13 \
    <(echo "$BASELINE_VOLUMES" | awk '{print $1}' | sort) \
    <(echo "$FINAL_VOLUMES" | awk '{print $1}' | sort))
  if [[ -z "$EXTRA_VOLUMES" ]]; then
    ok "Broad scan: zero extra funnel-* volumes vs baseline — fully clean."
  else
    UNTRACKED_COUNT=0
    while IFS= read -r vid; do
      [[ -z "$vid" ]] && continue
      VOL_NAME=$(openstack volume show "$vid" -f value -c name 2>/dev/null || echo "unknown")
      VOL_STATUS=$(openstack volume show "$vid" -f value -c status 2>/dev/null || echo "unknown")
      if echo "${TRACKED_VOLUMES}" | grep -qF "$vid" 2>/dev/null; then
        warn "Broad scan: tracked volume ${vid} (${VOL_NAME}, ${VOL_STATUS}) still present — already reported above."
      else
        fail "UNTRACKED ORPHAN: ${vid} (${VOL_NAME}, status=${VOL_STATUS})"
        info "  This volume was NOT in the state file — likely an expand volume whose ID was"
        info "  never written (autoscaler.sh aborted before appending to STATE_FILE)."
        info "  Delete manually: openstack volume delete ${vid}"
        UNTRACKED_COUNT=$((UNTRACKED_COUNT + 1))
        ORPHANED="${ORPHANED:-}${vid} "
        CLEANUP_OK=false
      fi
    done <<< "$EXTRA_VOLUMES"
    [[ $UNTRACKED_COUNT -eq 0 ]] && ok "Broad scan: all extra volumes were in the tracked set."
  fi
fi
echo ""

# ─── Summary ────────────────────────────────────────────────────────────────
echo "================================================================="
echo "  SUMMARY"
echo "================================================================="
echo ""
[[ "$TASK_A_OK" == "true" ]] && ok "Task A (hello):       PASS" || fail "Task A (hello):       FAIL"
[[ "$TASK_B_OK" == "true" ]] && ok "Task B (disk-write):  PASS" || fail "Task B (disk-write):  FAIL"
[[ "$TASK_C_OK" == "true" ]] && ok "Task C (nfs-check):   PASS" || fail "Task C (nfs-check):   FAIL — NFS not an actual nfs mount inside container"
[[ "$TASK_D_OK" == "true" ]] && ok "Task D (nfs-race):    PASS" || fail "Task D (nfs-race):    FAIL — race condition: NFS not mounted at container start"

if [[ -z "$TRACKED_VOLUMES" ]]; then
  warn "Cleanup E (volumes):  UNKNOWN — state file empty, setup.sh may not have completed"
elif [[ "$CLEANUP_OK" == "true" ]]; then
  ok "Cleanup E (volumes):  PASS — all Cinder volumes removed by Karpenter Delete()"
elif command -v openstack &>/dev/null; then
  fail "Cleanup E (volumes):  FAIL — orphaned volumes: ${ORPHANED}"
else
  warn "Cleanup E (volumes):  UNKNOWN — openstack CLI not available"
fi

ALL_TASKS_OK=false
[[ "$TASK_A_OK" == "true" && "$TASK_B_OK" == "true" && "$TASK_C_OK" == "true" && "$TASK_D_OK" == "true" ]] && ALL_TASKS_OK=true

echo ""
if [[ "$ALL_TASKS_OK" == "true" && "$CLEANUP_OK" == "true" ]]; then
  echo -e "${GREEN}ALL CHECKS PASSED${NC} — disk handling is working correctly."
  echo "Safe to run real Cromwell workflows."
elif [[ "$ALL_TASKS_OK" == "true" ]]; then
  echo -e "${YELLOW}TASKS PASSED, but cleanup could not be fully verified.${NC}"
  echo "Check Step 6 output above for details."
else
  echo -e "${RED}SOME CHECKS FAILED${NC} — investigate before running real workflows."
fi
echo ""
