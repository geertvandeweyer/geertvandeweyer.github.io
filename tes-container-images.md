---
layout: default
title: "Container Images"
description: "Custom image management, builds, and dependencies"
permalink: /tes/container-images/
---

# Container Images Reference

**Last Updated**: March 12, 2026  
**Audience**: Platform maintainers, developers rebuilding containers

---

## Overview

This document details all container images used in the OVHcloud MKS + Cromwell + Funnel platform, their purposes, sources, and how to rebuild/update them.

### Image Categories

1. **Custom-Built**: Built from source in this repository; may be rebuilt if code changes
2. **Forked**: Maintained forks of upstream projects (with our branch/tags)
3. **Upstream Third-Party**: Published images we consume but don't maintain

---

## Custom-Built Images

### 1. funnel-disk-setup

**Purpose**: Kubernetes DaemonSet for per-worker-node Cinder volume management + NFS keepalive

**Responsibilities**:
- Mount Cinder volumes (labeled with OVH device ID)
- LUKS unlock (encrypted Cinder volumes)
- LVM auto-expansion (adds new volumes when disk fills)
- NFS mount in Funnel worker pod initContainers
- Keepalive loop (prevents OVH Manila idle timeout)

#### Source Code

**Location**: `OVH_installer/installer/disk-autoscaler/`

```
disk-autoscaler/
├── Dockerfile           # Multi-stage build
├── main.go              # Go binary: mount + expand logic
├── mount_utils.go       # Cinder device discovery
├── luks_utils.go        # LUKS unlock
├── lvm_utils.go         # LVM extend
└── keepalive.go         # NFS touchdowns
```

**Language**: Go 1.21+

**Base Image**: `golang:1.21-alpine` (build) → `alpine:3.18` (runtime)

**Binary**: `/usr/local/bin/disk-setup`

#### Build Instructions

```bash
cd OVH_installer/installer/disk-autoscaler

# Build locally
docker build \
  --build-arg GO_VERSION=1.21 \
  -t docker.io/cmgantwerpen/funnel-disk-setup:v18 \
  .

# Push to registry
docker push docker.io/cmgantwerpen/funnel-disk-setup:v18

# Update env.variables
sed -i 's/FUNNEL_DISK_SETUP_IMAGE=.*/FUNNEL_DISK_SETUP_IMAGE="docker.io\/cmgantwerpen\/funnel-disk-setup:v18"/' \
  OVH_installer/installer/env.variables
```

#### Dockerfile Details

```dockerfile
# Stage 1: Build
FROM golang:1.21-alpine AS builder
RUN apk add --no-cache git make
WORKDIR /app
COPY . .
RUN go mod download
RUN CGO_ENABLED=1 GOOS=linux go build -o disk-setup .

# Stage 2: Runtime
FROM alpine:3.18
RUN apk add --no-cache \
    e2fsprogs \
    lvm2 \
    cryptsetup \
    nfs-utils \
    openstack-clients
COPY --from=builder /app/disk-setup /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/disk-setup"]
```

#### Container Startup

**DaemonSet container entries**:

```yaml
containers:
- name: holder
  image: docker.io/cmgantwerpen/funnel-disk-setup:v17
  command:
  - sh
  - -c
  - |
    # Mount Cinder volume
    disk-setup mount-cinder \
      --volume-size=${WORK_DIR_INITIAL_GB}Gi \
      --mount-point=/var/funnel-work \
      --luks-passphrase=${LUKS_PASSPHRASE}
    
    # Start auto-expander loop
    disk-setup expand-loop \
      --mount-point=/var/funnel-work \
      --threshold=${WORK_DIR_EXPAND_THRESHOLD} \
      --min-free-gb=${WORK_DIR_MIN_FREE_GB} \
      --expand-gb=${WORK_DIR_EXPAND_GB}
  
  - name: nfs-keepalive
    # Part of holder container init; runs in background
    disk-setup nfs-keepalive \
      --mount-point=/mnt/shared \
      --interval=${NFS_KEEPALIVE_INTERVAL}
```

#### Environment Variables (from configmap)

| Variable | Source | Used For |
|----------|--------|----------|
| `WORK_DIR_INITIAL_GB` | env.variables | Initial Cinder volume size |
| `WORK_DIR_EXPAND_THRESHOLD` | env.variables | Disk usage % trigger |
| `WORK_DIR_MIN_FREE_GB` | env.variables | Free space trigger (AND condition) |
| `WORK_DIR_EXPAND_GB` | env.variables | GB to add per expansion |
| `LUKS_PASSPHRASE` | env.variables | Decrypt LUKS volumes |
| `NFS_MOUNT_PATH` | env.variables | NFS mount point (/mnt/shared) |
| `NFS_KEEPALIVE_INTERVAL` | env.variables | Keepalive touch interval (30s) |
| `OS_AUTH_URL`, `OS_USERNAME`, `OS_PASSWORD`, `OS_PROJECT_ID` | env.variables | OpenStack Cinder API access |

#### Testing Locally

```bash
# Build and test locally (requires Docker)
cd OVH_installer/installer/disk-autoscaler
docker build -t test-disk-setup .

# Run in container (dry-run)
docker run --rm -it \
  -e WORK_DIR_INITIAL_GB=100 \
  -e WORK_DIR_EXPAND_THRESHOLD=80 \
  -e WORK_DIR_MIN_FREE_GB=75 \
  test-disk-setup \
  disk-setup --help
```

#### Version History

| Version | Date | Changes |
|---------|------|---------|
| v17 | Mar 12, 2026 | Added NFS keepalive to prevent idle timeout |
| v16 | Mar 10, 2026 | Fixed LVM extend logic for multiple volumes |
| v15 | Mar 05, 2026 | Initial LUKS + auto-expansion implementation |

---

## Forked/Maintained Images

### 1. Funnel TES

**Purpose**: Task Execution Service — REST API, gRPC, nerdctl task executor

**Repository**: **Upstream** → https://github.com/ohsu-comp-bio/funnel  
**Our Fork** → https://github.com/cmgantwerpen/funnel  
**Branch**: `feat/k8s-ovh-improvements`

#### Our Customizations

**Commits**:
- `be2fbce`: S3 fix for OVH endpoint (path-style addressing)
- `a4c3d92`: nerdctl executor integration
- `c8f2e1a`: Karpenter pod template support

**Changes to Upstream**:

1. **S3 Endpoint Configuration**:
   ```go
   // In worker/run.go
   // Support OVH S3 "path-style" addressing (non-virtual-hosted style)
   s3Config := &aws.Config{
     Region:           aws.String("gra"),
     Endpoint:         aws.String("https://s3.gra.io.cloud.ovh.net"),
     S3ForcePathStyle: aws.Bool(true),  // <- OVH requirement
   }
   ```

2. **nerdctl Container Driver**:
   ```go
   // In executor/container.go
   // Use containerd's nerdctl instead of Docker CLI
   driver := NewNerdctlDriver()  // Custom driver for nerdctl
   ```

3. **Kubernetes WorkerTemplate Support**:
   ```yaml
   # Allow dynamic pod template rendering via Karpenter labels
   {{range .Volumes}}--volume {{.HostPath}}:{{.ContainerPath}}:rw{{end}}
   ```

#### Docker Image Details

**Image**: `docker.io/cmgantwerpen/funnel:multiarch-revbe2fbce-s3fix`

**Build Command** (in upstream Funnel CI):

```bash
# Build binary
cd funnel
go build -o funnel-server ./cmd/server
go build -o funnel-worker ./cmd/worker

# Build Docker image (multi-arch)
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag docker.io/cmgantwerpen/funnel:multiarch-revbe2fbce-s3fix \
  --push \
  .
```

#### Container Entrypoints

**Funnel Server** (Kubernetes Deployment):

```bash
CMD ["server", "--config", "/etc/config/funnel.yaml"]
```

**Funnel Worker** (Kubernetes Job pod):

```bash
CMD ["worker", "run", "--config", "/etc/config/funnel-worker.yaml", "--taskID", "<task-id>"]
```

#### Updating to Newer Funnel Version

```bash
# 1. Check upstream releases
git clone https://github.com/ohsu-comp-bio/funnel.git
cd funnel
git tag -l | grep "v0\." | tail -10

# 2. Merge upstream changes
git checkout -b merge/upstream-vX.Y.Z
git merge origin/develop

# 3. Re-apply our patches (manually or via git format-patch)
# (S3 fix, nerdctl driver, Karpenter template)

# 4. Rebuild Docker image
docker buildx build --platform linux/amd64,linux/arm64 \
  --tag docker.io/cmgantwerpen/funnel:multiarch-rev<NEW-COMMIT>-s3fix \
  --push .

# 5. Update env.variables
FUNNEL_IMAGE="docker.io/cmgantwerpen/funnel:multiarch-rev<NEW-COMMIT>-s3fix"
```

#### Testing Locally

```bash
# Run Funnel server locally
cd funnel-src/cromwell
go run ./cmd/server --config cromwell-tes.conf --port 8001

# Check it's accepting task submissions
curl http://localhost:8001/v1/tasks
```

---

### 2. Karpenter OVHcloud Provider

**Purpose**: Node autoscaler — creates/terminates OVHcloud compute instances dynamically

**Repository**: **Upstream** → https://github.com/antonin-a/karpenter-provider-ovhcloud  
**Our Fork** → https://github.com/cmgantwerpen/karpenter-provider-ovhcloud  
**Branch**: `main`

#### Status

- **Upstream Maintained**: Active development by Antonin A
- **We Maintain**: OVHcloud-specific overrides for our use case
- **Differences**: Custom NodePool flavors + networking for MKS

#### Docker Image Details

**Image**: `docker.io/cmgantwerpen/karpenter-provider-ovhcloud:latest`

**Build Command**:

```bash
cd karpenter-provider-ovhcloud
docker build \
  --build-arg VERSION=$(git rev-parse --short HEAD) \
  -t docker.io/cmgantwerpen/karpenter-provider-ovhcloud:latest \
  .

docker push docker.io/cmgantwerpen/karpenter-provider-ovhcloud:latest
```

#### Helm Deployment

In `install-ovh-mks.sh`:

```bash
helm install karpenter-ovhcloud karpenter-community/karpenter-ovhcloud \
  --namespace karpenter \
  --set serviceAccount.annotations."iam\.gke\.io/gcp-service-account"=$KARPENTER_SA \
  --set image.repository="cmgantwerpen/karpenter-provider-ovhcloud:latest" \
  --set image.tag="latest"
```

#### Key Configuration

**OVHcloud API credentials** (stored in Kubernetes Secret):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: karpenter-ovhcloud
  namespace: karpenter
type: Opaque
stringData:
  OVH_APPLICATION_KEY: <KARPENTER_APP_KEY>
  OVH_APPLICATION_SECRET: <KARPENTER_APP_SECRET>
  OVH_CONSUMER_KEY: <KARPENTER_CONSUMER_KEY>
  OVH_PROJECT_ID: <OVH_PROJECT_ID>
  OVH_REGION: GRA9
```

#### Updating Karpenter Provider

```bash
# 1. Check upstream releases
git clone https://github.com/antonin-a/karpenter-provider-ovhcloud.git
cd karpenter-provider-ovhcloud
git fetch origin
git log --oneline -20 origin/main

# 2. Merge upstream (if significant changes)
git checkout main
git pull origin main

# 3. Rebuild image
docker build -t docker.io/cmgantwerpen/karpenter-provider-ovhcloud:latest .
docker push docker.io/cmgantwerpen/karpenter-provider-ovhcloud:latest

# 4. Redeploy
cd OVH_installer/installer
./install-ovh-mks.sh
# Choose Phase 2.5 to redeploy Karpenter
```

---

## Third-Party Upstream Images

These are published images we **do not maintain** — we just configure and use them.

### 1. Ubuntu Base (Task Container)

**Purpose**: Base image for genomics tasks (default in WDL workflows)

**Image**: `public.ecr.aws/lts/ubuntu:latest`

**Registry**: AWS ECR Public (Amazon-managed)

**What It Contains**: Ubuntu 22.04 LTS + essential packages

**Why AWS ECR**: OVH doesn't mirror AWS ECR Public; pulling from Amazon ensures latest updates

**Alternatives**:

```dockerfile
# If AWS ECR is unreachable, use OVH Nexus mirror (if available):
# docker.io/library/ubuntu:22.04

# Or build your own base image with custom tools:
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y \
    samtools bcftools bwa \
    python3 python3-pip \
    r-base
```

### 2. OpenStack Controllers (Cluster Init)

**Purpose**: CSI drivers, cloud controller, Barbican support

**Components**:
- `k8s.gcr.io/provider-os/openstack-cloud-controller-manager:v1.30`
- `k8s.gcr.io/provider-os/cinder-csi-plugin:v1.27`
- `k8s.gcr.io/provider-os/manila-csi-plugin:v1.27`
- `k8s.gcr.io/provider-os/magnum-auto-healer:v1.30`

**Deployment**: Auto-deployed by OVH when cluster is created (no manual action needed)

**Customization**: None (OVH-managed)

### 3. Karpenter Core

**Purpose**: Node autoscaling orchestrator (upstream Karpenter, not OVH-specific)

**Image**: `public.ecr.aws/karpenter/karpenter:v0.32.0`

**Registry**: AWS ECR Public

**Installed via**: Helm chart `karpenter-community/karpenter`

**Our OVH Provider** wraps this as a custom provider plugin.

### 4. Metrics Server (Optional)

**Purpose**: Kubernetes resource metrics (for `kubectl top`)

**Image**: `registry.k8s.io/metrics-server/metrics-server:v0.6.4`

**Installation** (if desired):

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.6.4/components.yaml
```

---

## Image Build Automation

### Local Registry Option

If you want to host images locally (not push to Docker Hub):

```bash
# Set up a local registry
docker run -d -p 5000:5000 --name registry registry:2

# Build and tag for local registry
docker build -t localhost:5000/funnel-disk-setup:v18 OVH_installer/installer/disk-autoscaler/
docker push localhost:5000/funnel-disk-setup:v18

# Update image reference in env.variables
FUNNEL_DISK_SETUP_IMAGE="localhost:5000/funnel-disk-setup:v18"

# Make sure Kubernetes nodes can reach the local registry
# (requires network configuration or node-level /etc/hosts entry)
```

### CI/CD Integration

**GitHub Actions example** (for automatic rebuilds):

```yaml
# .github/workflows/build-images.yml
name: Build Container Images
on:
  push:
    branches: [main]
    paths:
      - 'OVH_installer/installer/disk-autoscaler/**'

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: docker/setup-buildx-action@v2
      - uses: docker/login-action@v2
        with:
          username: ${{ secrets.DOCKER_HUB_USERNAME }}
          password: ${{ secrets.DOCKER_HUB_PASSWORD }}
      
      - name: Build and push funnel-disk-setup
        uses: docker/build-push-action@v4
        with:
          context: ./OVH_installer/installer/disk-autoscaler
          platforms: linux/amd64,linux/arm64
          push: true
          tags: docker.io/cmgantwerpen/funnel-disk-setup:${{ github.sha }}
```

---

## Security & Best Practices

### Image Scanning

```bash
# Scan for vulnerabilities using Trivy
trivy image docker.io/cmgantwerpen/funnel-disk-setup:v18

# Example output:
# Found 2 MEDIUM vulnerabilities in node packages
# - CVE-2024-1234: Alpine apk package
# - CVE-2024-5678: OpenSSL in runtime

# Fix by updating base image:
# FROM alpine:3.18 -> FROM alpine:3.19
```

### Image Signing (Optional)

```bash
# Sign images with cosign (optional but recommended for production)
cosign sign --key cosign.key docker.io/cmgantwerpen/funnel-disk-setup:v18

# Verify signature
cosign verify --key cosign.pub docker.io/cmgantwerpen/funnel-disk-setup:v18
```

### Minimal Base Images

```dockerfile
# Good: Alpine (minimal)
FROM alpine:3.18
# 5 MB image size

# Avoid: Full OS distributions
FROM ubuntu:22.04
# 77 MB image size (15x larger)
```

---

## Image Dependency Graph

```
┌─────────────────────────────────────┐
│   OVH MKS Cluster (pre-deployed)    │
│   - OpenStack Cloud Controllers     │
│   - Cinder/Manila CSI drivers       │
└────────────┬────────────────────────┘
             │
   ┌─────────┴─────────┐
   │                   │
   ▼                   ▼
┌────────────────────┐ ┌──────────────────────────────┐
│ Karpenter          │ │ System Node (OVH d2-4)       │
│ karpenter-         │ │ - funnel-disk-setup DaemonSet │
│ provider-ovhcloud: │ │ - nfs-ssh-mount pod          │
│ cmgantwerpen/...   │ │ - karpenter controller       │
└────────────────────┘ └──────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────┐
│ Autoscaled Worker Nodes                  │
│ (c3-4, b2-7, r3-8, etc.)                 │
│ - funnel-disk-setup pod per node         │
│ - funnel-worker jobs (on-demand)         │
└──────────────────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────┐
│ Funnel TES Server                        │
│ docker.io/cmgantwerpen/funnel:           │
│ multiarch-revbe2fbce-s3fix               │
│ - REST API (:8000)                       │
│ - gRPC (:9090)                           │
└──────────────────────────────────────────┘
   │
   ▼
┌──────────────────────────────────────────┐
│ Task Container (nerdctl executor)        │
│ public.ecr.aws/lts/ubuntu:latest         │
│ (or custom image per WDL task)           │
└──────────────────────────────────────────┘
```

---

## Summary Table

| Image | Source | Maintained | Build | Registry |
|-------|--------|-----------|-------|----------|
| **funnel-disk-setup:v17** | Custom (Go) | 🔵 Ours | Local | docker.io |
| **funnel:multiarch-revbe2fbce-s3fix** | Fork (OHSU upstream) | 🟡 Partially | CI/CD | docker.io |
| **karpenter-provider-ovhcloud:latest** | Fork (Antonin A) | 🟡 Partially | Local | docker.io |
| **ubuntu:22.04** | Upstream | ⚪ AWS | N/A | ecr.aws |
| **metrics-server:v0.6.4** | Upstream | ⚪ K8s | N/A | registry.k8s.io |
| **OpenStack CSI drivers** | Upstream | ⚪ OVH | N/A | k8s.gcr.io |

---

**Last Updated**: March 12, 2026  
**Maintainer**: CMG UZA Platform Team
