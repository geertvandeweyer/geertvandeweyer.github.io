#!/usr/bin/env bash
# redeploy-funnel-configmap.sh
#
# Re-renders and applies funnel-configmap from the template, then does a
# rolling restart of the funnel deployment.
#
# Use this whenever you need to update the configmap outside of a full
# install run — e.g. after changing:
#   - TES_VERSION / FUNNEL_IMAGE
#   - DriverCommand (nerdctl vs nerdctl-wrap)
#   - EFS config
#   - nerdctl RunCommand flags
#
# IMPORTANT — three common mistakes this script guards against:
#   1. Missing `sed 's/__DOLLAR__/\$/g'` step: the RunCommand in
#      funnel-worker.yaml uses {{range $k, $v := .Env}} which must be
#      written as __DOLLAR__k/__DOLLAR__v in the template to survive envsubst.
#      Omitting sed leaves literal __DOLLAR__k in the configmap and causes
#      "function __DOLLAR__k not defined" errors at task runtime.
#
#   2. Missing EFS_WORKER_MOUNT / EFS_WORKER_VOLUME / EFS_NERDCTL_MOUNT:
#      These three multi-line vars are derived from EFS_ID in env.variables.
#      If they are empty the worker pods have no /mnt/efs volumeMount, the
#      nerdctl RunCommand gets no --volume /mnt/efs:/mnt/efs:rw, and tasks
#      that read reference files from EFS (elprep, BWA, GATK …) will fail
#      with "file does not exist".
#
#   3. Wrong DriverCommand: must be "nerdctl-wrap" (not plain "nerdctl").
#      Plain nerdctl passes all bind-mounts directly to containerd, which
#      hits the 4096-byte label limit on tasks with many inputs and returns
#      "label key and value length > maximum size (4096 bytes)".
#
# Usage:
#   source installer/env.variables   # sets all required vars incl. EFS_*
#   bash installer/redeploy-funnel-configmap.sh
#
# Or run standalone (sources env.variables automatically):
#   bash installer/redeploy-funnel-configmap.sh
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source env.variables if not already sourced (idempotent — all vars are
# guarded with ${VAR:-...} or just set, so re-sourcing is safe)
# shellcheck source=env.variables
source "${SCRIPT_DIR}/env.variables"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
export ECR_IMAGE_REGION="${ECR_IMAGE_REGION:-eu-west-1}"
export FUNNEL_IMAGE="${AWS_ACCOUNT_ID}.dkr.ecr.${ECR_IMAGE_REGION}.amazonaws.com/funnel:${TES_VERSION}"
export TES_ROLE_NAME="${TES_ROLE_NAME:-}"
export BOOTSTRAP_NG="${BOOTSTRAP_NG:-}"

# Verify the three EFS vars were populated (env.variables computes them from
# EFS_ID, so this catches the case where someone sources a stripped-down env)
if [ -n "${EFS_ID:-}" ] && [ -z "${EFS_NERDCTL_MOUNT:-}" ]; then
  echo "ERROR: EFS_ID is set but EFS_NERDCTL_MOUNT is empty." >&2
  echo "       Source installer/env.variables before running this script." >&2
  exit 1
fi

TEMPLATE="${SCRIPT_DIR}/yamls/funnel-configmap.template.yaml"
FUND_VARS='${TES_NAMESPACE} ${TES_S3_BUCKET} ${AWS_DEFAULT_REGION} ${ECR_IMAGE_REGION} ${FUNNEL_IMAGE} ${FUNNEL_PORT} ${TES_ROLE_NAME} ${EFS_WORKER_MOUNT} ${EFS_WORKER_VOLUME} ${EFS_NERDCTL_MOUNT} ${BOOTSTRAP_NG} ${AWS_ACCOUNT_ID} ${AWS_PARTITION}'

echo "Deploying funnel configmap..."
echo "  IMAGE  : ${FUNNEL_IMAGE}"
echo "  EFS_ID : ${EFS_ID:-<none>}"
echo "  EFS mount in nerdctl : ${EFS_NERDCTL_MOUNT:-<none>}"
echo ""

envsubst "$FUND_VARS" < "$TEMPLATE" \
  | sed 's/__DOLLAR__/\$/g' \
  | kubectl apply -f -

# Verify key settings in the live configmap
echo ""
echo "--- Verify configmap ---"
kubectl -n "${TES_NAMESPACE}" get configmap funnel-config \
  -o jsonpath='{.data.funnel-worker\.yaml}' \
  | grep -E "DriverCommand|RunCommand|mnt/efs" \
  | sed 's/^/  /'

echo ""
echo "--- Rolling restart funnel deployment ---"
kubectl -n "${TES_NAMESPACE}" rollout restart deployment/funnel
kubectl -n "${TES_NAMESPACE}" rollout status deployment/funnel --timeout=120s

echo ""
echo "Done. New funnel pod:"
kubectl -n "${TES_NAMESPACE}" get pods -l app=funnel --no-headers | grep -v worker
