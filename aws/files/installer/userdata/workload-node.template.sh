#!/bin/bash
set -ex

# ── ECR credential dir ─────────────────────────────────
mkdir -p /opt/ecr-auth/bin /opt/ecr-auth/.docker
# Placeholder — overwritten with real tokens after containerd starts below
echo '{"auths":{}}' > /opt/ecr-auth/.docker/config.json

# ── Wait for IMDSv2 ─────────────────────────────────────
for i in $(seq 1 20); do
    TOKEN=$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
        http://169.254.169.254/latest/api/token || true)
    [ -n "$TOKEN" ] && break
    echo "IMDSv2 not ready ($i/20)..."
    sleep 3
done
[ -n "$TOKEN" ] || { echo "IMDSv2 unavailable"; shutdown -h now; }

# ── Identify data disk ──────────────────────────────────
# Wait up to 3 minutes for the secondary EBS volume to attach before probing
ROOT_PART=$(findmnt -n -o SOURCE /)
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_PART")
DATA_DISK=""
for wait in $(seq 1 36); do
    for d in /dev/nvme*n1 /dev/xvd[b-z]; do
        [ -b "$d" ] || continue
        [ "$(basename "$d")" = "$ROOT_DISK" ] && continue
        DATA_DISK="$d"
        break
    done
    [ -n "$DATA_DISK" ] && break
    echo "Waiting for data disk (attempt $wait/36)..."
    sleep 5
done
[ -n "$DATA_DISK" ] || { echo "No data disk found after 3 min"; shutdown -h now; }

# ── Download amazon-ebs-autoscale with retries ─────────
MAX_RETRIES=5
for i in $(seq 1 $MAX_RETRIES); do
    echo "Downloading amazon-ebs-autoscale (attempt $i/$MAX_RETRIES)..."
    if aws s3 cp ${ARTIFACTS_S3_BUCKET}/amazon-ebs-autoscale.tgz /tmp/amazon-ebs-autoscale.tgz; then
        break
    fi
    sleep 15
done
[ -f /tmp/amazon-ebs-autoscale.tgz ] || { echo "Failed to download amazon-ebs-autoscale"; shutdown -h now; }

mkdir -p /opt/amazon-ebs-autoscale
tar -xzf /tmp/amazon-ebs-autoscale.tgz -C /opt/amazon-ebs-autoscale --strip-components=1
chmod +x /opt/amazon-ebs-autoscale/install.sh

# ── Install autoscale ──────────────────────────────────
/opt/amazon-ebs-autoscale/install.sh \
    --initial-device "$DATA_DISK" \
    --file-system lvm.ext4 \
    --mountpoint /var/funnel-work \
    --volume-type gp3 \
    --volume-iops ${EBS_IOPS} \
    --volume-throughput ${EBS_THROUGHPUT} \
    --imdsv2

# ── update mount options for performance ────────────────
systemctl stop ebs-autoscale || true
AUTOSCALE_DEV=$(awk '$2=="/var/funnel-work" {print $1}' /etc/fstab)
umount /var/funnel-work || true
mount -t ext4 -o noatime,data=writeback,barrier=0,commit=300 "$AUTOSCALE_DEV" /var/funnel-work
sed -i 's|ext4\tdefaults\t|ext4\tnoatime,data=writeback,barrier=0,commit=300\t|' /etc/fstab
systemctl daemon-reload
systemctl restart ebs-autoscale

# ── Relocate containerd for / to Autoscaled volume ───────────────
systemctl stop kubelet containerd || true
mkdir -p /var/funnel-work/containerd /var/lib/containerd
cp -a /var/lib/containerd/. /var/funnel-work/containerd/ 2>/dev/null || true
mount --bind /var/funnel-work/containerd /var/lib/containerd
systemctl start containerd kubelet

    # ── Pre-authenticate ECR: write static auth JSON to /opt/ecr-auth/.docker ──
    # docker-credential-ecr-login uses the Linux keychain inside containers,
    # which fails. Writing a static config.json avoids the helper entirely.
    ECR_EW1="${AWS_ACCOUNT_ID}.dkr.ecr.eu-west-1.amazonaws.com"
    ECR_EW2="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
    T1=$(aws ecr get-login-password --region eu-west-1)
    T2=$(aws ecr get-login-password --region "${AWS_DEFAULT_REGION}")
    A1=$(printf '%s' "AWS:${T1}" | base64 -w 0)
    A2=$(printf '%s' "AWS:${T2}" | base64 -w 0)
    printf '{"auths":{"%s":{"auth":"%s"},"%s":{"auth":"%s"}}}\n' \
        "$ECR_EW1" "$A1" "$ECR_EW2" "$A2" > /opt/ecr-auth/.docker/config.json
    echo "ECR credentials written at boot"

    # ── Refresh ECR credentials every 6 hours (tokens expire after 12h) ──
    cat > /etc/cron.d/ecr-auth-refresh << 'CRON'
0 */6 * * * root \
  R1="${AWS_ACCOUNT_ID}.dkr.ecr.eu-west-1.amazonaws.com"; \
  R2="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"; \
  T1=$(aws ecr get-login-password --region eu-west-1); \
  T2=$(aws ecr get-login-password --region ${AWS_DEFAULT_REGION}); \
  A1=$(printf '%s' "AWS:$T1" | base64 -w 0); \
  A2=$(printf '%s' "AWS:$T2" | base64 -w 0); \
  printf '{"auths":{"%s":{"auth":"%s"},"%s":{"auth":"%s"}}}\n' "$R1" "$A1" "$R2" "$A2" > /opt/ecr-auth/.docker/config.json
CRON
    chmod 644 /etc/cron.d/ecr-auth-refresh

    # ── Mount EFS at /mnt/efs if configured ────────────────
    if [ -n "${EFS_ID}" ]; then
      echo "Mounting EFS at /mnt/efs..."
      mkdir -p /mnt/efs
      mount -t nfs4 \
        -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport \
        ${EFS_ID}.efs.${AWS_DEFAULT_REGION}.amazonaws.com:/ /mnt/efs
      # persist across reboots
      echo "${EFS_ID}.efs.${AWS_DEFAULT_REGION}.amazonaws.com:/ /mnt/efs nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,_netdev 0 0" >> /etc/fstab
      echo "EFS mounted at /mnt/efs"
    fi
echo "Workload node userdata completed"
