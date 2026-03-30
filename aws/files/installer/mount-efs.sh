#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# mount-efs.sh  — persistent EFS mount via the efs-ssh-mount pod
#
# Keeps a kubectl port-forward alive in a background loop, then
# mounts EFS via sshfs with --reconnect so it survives pod restarts
# and brief network blips.
#
# Usage:
#   ./mount-efs.sh              # mounts at /mnt/efs (default)
#   ./mount-efs.sh /my/path     # mounts at custom path
#   ./mount-efs.sh umount       # unmount
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

MOUNT_POINT="${1:-/mnt/efs}"
LOCAL_PORT=2222
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
NAMESPACE="funnel"
DEPLOYMENT="efs-ssh-mount"
PF_LOG="/tmp/efs-pf.log"
PF_PID_FILE="/tmp/efs-pf.pid"

if [[ "${1:-}" == "umount" || "${1:-}" == "unmount" ]]; then
    echo "Unmounting $MOUNT_POINT ..."
    fusermount -u "$MOUNT_POINT" 2>/dev/null || umount "$MOUNT_POINT" 2>/dev/null || true
    if [[ -f "$PF_PID_FILE" ]]; then
        kill "$(cat "$PF_PID_FILE")" 2>/dev/null || true
        rm -f "$PF_PID_FILE"
    fi
    pkill -f "port-forward.*${DEPLOYMENT}" 2>/dev/null || true
    echo "Done."
    exit 0
fi

# ── 1. Check dependencies ──────────────────────────────────────
for cmd in kubectl sshfs ssh; do
    command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
done

# ── 2. Check pod is running ────────────────────────────────────
echo "Checking efs-ssh-mount pod..."
kubectl get pod -n "$NAMESPACE" -l app="$DEPLOYMENT" --field-selector=status.phase=Running -o name \
    | grep -q "pod/" || { echo "ERROR: efs-ssh-mount pod not Running. Deploy it first."; exit 1; }

# ── 3. Create mount point ──────────────────────────────────────
mkdir -p "$MOUNT_POINT"

# ── 4. Kill any stale port-forward ────────────────────────────
pkill -f "port-forward.*${DEPLOYMENT}" 2>/dev/null || true
sleep 1

# ── 5. Start port-forward in a self-restarting background loop ─
echo "Starting port-forward loop (log: $PF_LOG) ..."
(
    while true; do
        kubectl port-forward -n "$NAMESPACE" "deployment/$DEPLOYMENT" \
            "${LOCAL_PORT}:22" --address=127.0.0.1 2>&1
        echo "[$(date)] port-forward exited, restarting in 5s..." >> "$PF_LOG"
        sleep 5
    done
) >> "$PF_LOG" 2>&1 &
echo $! > "$PF_PID_FILE"

# ── 6. Wait for port-forward to be ready ──────────────────────
echo -n "Waiting for port-forward..."
for i in $(seq 1 20); do
    sleep 1
    if timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/${LOCAL_PORT}" 2>/dev/null; then
        echo " ready."
        break
    fi
    echo -n "."
    if [[ $i -eq 20 ]]; then
        echo " TIMEOUT. Check $PF_LOG"
        exit 1
    fi
done

# ── 7. Mount via sshfs ─────────────────────────────────────────
if mountpoint -q "$MOUNT_POINT"; then
    echo "Already mounted at $MOUNT_POINT, remounting..."
    fusermount -u "$MOUNT_POINT" 2>/dev/null || umount "$MOUNT_POINT" 2>/dev/null
fi

echo "Mounting EFS at $MOUNT_POINT ..."
sshfs root@127.0.0.1:/mnt/efs "$MOUNT_POINT" \
    -p "$LOCAL_PORT" \
    -o reconnect \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=no \
    -o IdentityFile="$SSH_KEY" \
    -o follow_symlinks

echo ""
echo "✓ EFS mounted at $MOUNT_POINT"
echo "  port-forward pid: $(cat $PF_PID_FILE)  log: $PF_LOG"
echo ""
echo "  To unmount:  $0 umount"
echo "  To browse:   ls $MOUNT_POINT"
df -h "$MOUNT_POINT"
