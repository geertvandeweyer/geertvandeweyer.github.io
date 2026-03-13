---
layout: default
title: "Installation Guide"
description: "7-phase deployment guide for OVHcloud MKS + Funnel + Cromwell"
permalink: /ovh/installation-guide/
---

# OVHcloud MKS + Cromwell + Funnel Installation Guide

**Project:** CMG TES/UZA on OVHcloud MKS  
**Region:** GRA9 (Gravelines, France)  
**Last Updated:** March 12, 2026  
**Status:** Complete, tested end-to-end with NFS keepalive

---

## Table of Contents

1. [Overview & Architecture](#overview--architecture)
2. [Prerequisites](#prerequisites)
3. [Phase 0: Environment Setup](#phase-0-environment-setup)
4. [Phase 1: Create MKS Cluster](#phase-1-create-mks-cluster)
5. [Phase 2: Node Pools & Autoscaling](#phase-2-node-pools--autoscaling)
6. [Phase 3: Manila NFS Shared Storage](#phase-3-manila-nfs-shared-storage)
7. [Phase 4: S3 Object Storage](#phase-4-s3-object-storage)
8. [Phase 4.5: Private Container Registry](#phase-45-private-container-registry)
9. [Phase 5: Deploy Funnel TES](#phase-5-deploy-funnel-tes)
10. [Phase 6: Configure Cromwell](#phase-6-configure-cromwell)
11. [Phase 7: Verification & Testing](#phase-7-verification--testing)
12. [Container Images](#container-images)
13. [Troubleshooting](#troubleshooting)

---

## Overview & Architecture

This guide automates the deployment of a **genomics workflow platform** on OVHcloud MKS (Managed Kubernetes Service) consisting of:

- **Kubernetes Cluster**: 1 fixed system node (always-on, kube-system + app infrastructure) + autoscaled worker nodes
- **Funnel**: Task Execution Service (TES) for running containerized tasks (via nerdctl)
- **Cromwell**: Workflow Manager (WDL language support)
- **Storage**: 
  - **Manila NFS** (150 GB ReadWriteMany) for shared workflow data
  - **S3 Object Storage** (OVH-compatible) for task inputs/outputs/logs
  - **Cinder Volumes** (per-node, auto-expanding with LUKS encryption) for local task disk
- **Registry**: 
  - **OVH Managed Private Registry (MPR)** for custom task container images

### Architecture Diagram

```
                          ┌─────────────────────────────┐
                          │   Cromwell (localhost:7900) │
                          │   (submits WDL workflows)   │
                          └──────────────┬──────────────┘
                                         │ HTTP/REST
                          ┌──────────────▼──────────────┐
                          │   Funnel TES (LoadBalancer) │
                          │   (executes tasks)          │
                          └──────────────┬──────────────┘
                                         │
          ┌──────────────────────────────┼──────────────────────────────┐
          │                              │                              │
    ┌─────▼──────┐   ┌──────────────┐   ▼   ┌──────────────┐     ┌─────▼──────────┐
    │ system-    │   │ karpenter-   │       │ karpenter-   │  ...│ karpenter-     │
    │ node       │   │ c3-4-node-1  │       │ c3-4-node-2  │     │ r3-8-node-1    │
    │ (d2-4)     │   │ (c3-4/8GB)   │       │ (c3-4/8GB)   │     │ (r3-8/32GB)    │
    └─────┬──────┘   └──────┬───────┘       └──────┬───────┘     └─────┬──────────┘
          │                 │                      │                    │
          │                 │        ┌──────────────┼────────────────────┘
          │                 │        │              │
          └─────────────────┼────────┼──────────────┘
                            │        │
              ┌─────────────▼────────▼───────────────┐
              │  Manila NFS (/mnt/shared, 150GB)     │
              │  OVH Cloud (private Neutron vRack)   │
              └──────────────────────────────────────┘
                            │
                            │ (Karpenter worker nodes mount via DaemonSet)
                            │ (Task containers mount via nerdctl --volume)
                            │
              ┌─────────────────────────────────────┐
              │  OVH S3 Object Storage               │
              │  https://s3.gra.io.cloud.ovh.net    │
              │  (task inputs/outputs/logs)         │
              └─────────────────────────────────────┘
```

### Key Components

| Component | Role | Host | Port |
|-----------|------|------|------|
| **Cromwell** | WDL workflow submission & orchestration | localhost (your machine) | 7900 |
| **Funnel Server** | TES API, task queue management | MKS LoadBalancer | 8000 (HTTP), 9090 (gRPC) |
| **Funnel Worker (nerdctl)** | Task container executor | Each worker node | (bound to node) |
| **funnel-disk-setup** | Cinder volume mount + auto-expansion | Each worker node | N/A |
| **Karpenter** | Node autoscaler | MKS cluster | (internal) |
| **Manila NFS** | Shared read-write storage | OVH Cloud | 2049 (NFS) |
| **S3** | Object storage (workflow inputs/outputs) | OVH Cloud | 443 (HTTPS) |

---

## Prerequisites

### Local Machine Requirements

1. **Micromamba or Conda** with an `ovh` environment containing:
   ```bash
   # Create environment (one-time)
   micromamba create -n ovh
   micromamba activate ovh
   micromamba install \
     ovhcloud \
     openstack-clients \
     kubernetes \
     helm \
     gettext  # for envsubst
   ```

2. **OVHcloud CLI credentials** (one-time setup):
   ```bash
   ovhcloud account login
   # Saves credentials to ~/.config/ovhcloud/config.toml
   ```

3. **OpenStack RC file** (downloaded from OVH Control Panel):
   - Visit: https://www.ovh.com/manager/cloud/project/iam/users
   - Download OpenStack RC file for your region
   - Save as: `OVH_installer/installer/openrc-tes-pilot.sh`
   - Source it: `source openrc-tes-pilot.sh`

4. **AWS CLI** (for S3 operations):
   ```bash
   micromamba install awscli-v2
   # Configure: see Phase 4 (S3 setup)
   ```

5. **Docker** (for building custom container images):
   ```bash
   # Already installed on Linux
   # Ensure you have push access to your registry (e.g., docker.io/cmgantwerpen/...)
   ```

### OVHcloud Project Requirements

- **Project created** and activated in OVHcloud Manager
- **Project ID** noted (visible in: Manager → Cloud → Project → Settings)
- **At least one API user** with sufficient permissions:
  - Cloud > Kubernetes
  - Cloud > Network
  - Cloud > Storage
  - Cloud > Identity & Access Management (S3, Barbican)

### Quotas & Capacity

Before starting, ensure your OVHcloud project has sufficient quota:

| Resource | Recommendation | Notes |
|----------|-----------------|-------|
| **Compute (vCPU cores)** | 100+ | For Karpenter autoscaling |
| **RAM (GB)** | 300+ | Depends on workflow demands |
| **Cinder Volumes** | 500+ GB total | Task disk storage (auto-expandable) |
| **Cinder snapshots** | N/A | Not used |
| **Floating IPs** | 1 | For MKS external LoadBalancer |
| **Security groups** | Default OK | Rules auto-created by cluster |
| **Manila shares** | 1 (150+ GB) | NFS storage |
| **S3 buckets** | 1 | Task I/O storage |

---

## Phase 0: Environment Setup

### Step 0.1: Clone the Repository

```bash
cd /path/to/workspace
git clone <repo-url> k8s-ovh
cd k8s-ovh/OVH_installer/installer
```

### Step 0.2: Configure Environment Variables

Edit `env.variables` with your OVHcloud project details:

```bash
# Replace these with your actual values:
OVH_PROJECT_ID="<your-project-id>"           # e.g., c386d174c0974008bac7b36c4dfafb23
K8S_CLUSTER_NAME="tes-pilot"                 # MKS cluster name
K8S_VERSION="1.31"                           # Kubernetes version
EXTERNAL_IP="<your-floating-ip>"             # For Cromwell access
```

**Key variables explained:**

| Variable | Purpose | Example |
|----------|---------|---------|
| `OVH_REGION` | OVH region for all resources | GRA9 (Gravelines) |
| `SYSTEM_FLAVOR` | Fixed node (kube-system) | d2-4 (1 vCPU, 4 GB) |
| `WORKER_FAMILIES` | Instance types for workers | d2,b2,b3,c2,c3,r2,r3 |
| `FUNNEL_IMAGE` | Funnel TES docker image | docker.io/cmgantwerpen/funnel:... |
| `NFS_MOUNT_PATH` | Where to mount Manila NFS | /mnt/shared |
| `WORK_DIR_INITIAL_GB` | Initial Cinder volume per node | 100 GB |
| `CINDER_VOLUME_TYPE` | Encryption type | high-speed-luks |

### Step 0.3: Source OpenStack Credentials

```bash
source openrc-tes-pilot.sh
# Prompts for Keystone password
# Sets OS_AUTH_URL, OS_USERNAME, OS_PASSWORD, etc.
```

### Step 0.4: Verify Prerequisites

```bash
# Check all tools are available
which ovhcloud openstack kubectl helm envsubst docker
# Check OVHcloud login
ovhcloud account whoami
# Check OpenStack access
openstack server list --limit 1
# Check Docker registry access (if using custom images)
docker login  # if needed
```

### ✅ Phase 0 Checklist

- [ ] Micromamba environment created with all tools
- [ ] OVHcloud CLI logged in
- [ ] OpenStack RC file sourced
- [ ] env.variables customized with project ID and IPs
- [ ] All prerequisite commands verified

---

## Phase 1: Create MKS Cluster

### What Happens

This phase creates:

1. **Private Neutron network** (192.168.100.0/24) — required by MKS & Manila NFS
2. **MKS Kubernetes cluster** — hosted MKS on OVHcloud
3. **kubeconfig file** — saved to `~/.kube/ovh-tes.yaml`

### Execution

```bash
cd OVH_installer/installer
./install-ovh-mks.sh
```

The script will pause at Phase 1 and ask for confirmation. **Expected output:**

```
============================================
 Phase 1: Create MKS cluster
============================================

Checking for existing private network 'tes-private-net'...
Creating private network 'tes-private-net' in GRA9...
✅ Private network created: a3bcde13-4dfd-4a83-bce1-08509c53bc7d

Creating MKS cluster 'tes-pilot' (Kubernetes 1.31)...
[Waiting for cluster to reach ACTIVE status...]
  [15s/600s] cluster status: DEPLOYING — waiting...
  [30s/600s] cluster status: DEPLOYING — waiting...
  ...
✅ MKS cluster is ACTIVE

Kubeconfig saved to: /home/user/.kube/ovh-tes.yaml
```

### Verification

```bash
export KUBECONFIG=~/.kube/ovh-tes.yaml
kubectl get nodes
# Expected output:
# NAME                 STATUS   ROLES   AGE   VERSION
# system-node-b89e91   Ready    <none>  2m    v1.31.13

kubectl get pods -n kube-system | head -10
# Should see: coredns, kube-proxy, etc.
```

### 💰 Cost Impact

- **MKS cluster control plane**: Free (OVH free tier)
- **System node (d2-4)**: ~€0.005/hour = ~€3.60/month (always-on)

### ✅ Phase 1 Checklist

- [ ] Private network created
- [ ] MKS cluster status is ACTIVE
- [ ] kubeconfig generated and set
- [ ] `kubectl get nodes` shows system-node Ready

---

## Phase 2: Node Pools & Autoscaling

### What Happens

This phase:

1. Creates **Karpenter node autoscaler** (replaces OVH's simpler Cluster Autoscaler)
2. Defines node pools for heterogeneous instance types (d2, b2, c3, r3, etc.)
3. Configures consolidation (scales down when not needed)

### Execution

The installer continues after Phase 1. **Expected output for Phase 2 & 2.5:**

```
============================================
 Phase 2: Create node pools
============================================

Creating node pool 'workers' with flavors: d2,b2,b3,c2,c3,r2,r3...
✅ Node pool created

============================================
 Phase 2.5: Karpenter node autoscaler
============================================

Installing Karpenter + OVHcloud provider...
[Helm installing karpenter-ovhcloud...]
deployment "karpenter" successfully rolled out
✅ Karpenter deployed (replicas: 2, high availability)
```

### Configuration Details

**Karpenter NodePool (`workers`):**

```yaml
limits:
  cpu: 100 cores
  memory: 400 Gi
consolidateAfter: 5m      # Scale down idle nodes after 5 min
consolidationPolicy: WhenEmpty  # Consolidate empty nodes
```

**Instance types** (Karpenter picks the cheapest that fits):

| Family | Flavor | vCPU | RAM | Type | $/hour | Use Case |
|--------|--------|------|-----|------|--------|----------|
| **d2** | d2-4 | 1 | 4 GB | Shared | €0.005 | Small tasks |
| **b2** | b2-7 | 2 | 7 GB | AMD EPYC | €0.010 | Medium tasks |
| **c3** | c3-4 | 2 | 8 GB | Intel Xeon | €0.020 | Parallel tasks |
| **r3** | r3-8 | 4 | 32 GB | AMD EPYC | €0.050 | Memory-intensive |

### Verification

```bash
kubectl get nodepools
# NAME      NODECLASS   NODES   READY   AGE
# workers   default     0       True    5m

kubectl get nodeclaims
# (empty initially — only creates when pods are scheduled)

kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | tail -20
# Check for "Karpenter v0.32.x" message
```

### 💰 Cost Impact

- **Karpenter overhead**: negligible (2 replicas, ~100 m CPU each)
- **Worker nodes**: created on-demand, removed when idle

### ✅ Phase 2 Checklist

- [ ] Karpenter deployment shows Running
- [ ] NodePool "workers" is Ready
- [ ] Karpenter logs show no errors

---

## Phase 3: Manila NFS Shared Storage

### What Happens

This phase creates:

1. **Manila NFS share** (150 GB) on the private network
2. **Kubernetes PVC** + StorageClass for Manila CSI
3. **DaemonSet pod** that mounts NFS and maintains TCP keepalive
4. **Shared volume available** at `/mnt/shared` on all worker nodes

### Why DaemonSet + Keepalive?

OVH Manila's NFS has idle TCP timeout (~minutes). Without keepalive, after a task completes, the TCP connection dies. When a new task starts, the `mkdir /mnt/shared` fails with "Input/output error" on a stale VFS entry.

**Solution**: The `funnel-disk-setup` DaemonSet continuously touches `/mnt/shared/.keepalive` every 30 seconds, keeping the connection alive. Each task pod's `setup-nfs` initContainer just waits for NFS to be ready (non-privileged, safe for parallel tasks).

### Execution

```
============================================
 Phase 3: Manila NFS shared storage
============================================

Creating Manila share 'tes-shared' (150 GB)...
[Waiting for share to reach AVAILABLE status...]
  [15s/600s] share status: CREATING — waiting...
  ...
✅ Manila share created

Creating access rule (private network access)...
✅ Manila access rule created

Creating StorageClass 'manila-nfs'...
✅ StorageClass created

Deploying NFS mount DaemonSet + CSI driver...
✅ DaemonSet deployed (pod per worker node)
```

### Verification

```bash
# Check the PVC
kubectl get pvc -n funnel
# NAME                STATUS   VOLUME   CAPACITY   AGE
# manila-shared-pvc   Bound    pv-...   150Gi      2m

# Check the mount DaemonSet
kubectl get pods -n funnel -l app=funnel-disk-setup
# NAME                       READY   STATUS    AGE
# funnel-disk-setup-abc12    1/1     Running   2m
# funnel-disk-setup-def34    1/1     Running   2m

# Check mount is accessible
kubectl exec -n funnel funnel-disk-setup-abc12 -- ls /mnt/shared
# (should list no errors)

# Check keepalive touchdowns
kubectl exec -n funnel funnel-disk-setup-abc12 -- ls -la /mnt/shared/.keepalive
# -rw-r--r-- 1 root root 0 Mar 12 14:35 /mnt/shared/.keepalive
```

### 💰 Cost Impact

- **Manila share (150 GB)**: ~€6/month
- **NFS traffic** (private network): free (not counted as WAN)

### ✅ Phase 3 Checklist

- [ ] Manila share status is AVAILABLE
- [ ] PVC `manila-shared-pvc` is Bound
- [ ] DaemonSet pod is Running on each worker node
- [ ] `/mnt/shared` is accessible (non-empty `.keepalive` file)

---

## Phase 4: S3 Object Storage

### What Happens

This phase:

1. Creates **OVH S3 bucket** for task I/O and logs
2. Creates **OVH API credentials** (access key + secret)
3. Stores credentials in **Kubernetes Secret** for Funnel worker access

### Execution

```
============================================
 Phase 4: S3 bucket + credentials
============================================

Creating S3 bucket 'tes-tasks-c386d174c0974008bac7b36c4dfafb23-gra9'...
✅ S3 bucket created

Creating S3 credentials (access key + secret)...
✅ S3 credentials created

Storing credentials in Kubernetes Secret 'ovh-s3-credentials'...
✅ Secret created
```

### Configuration

**S3 endpoint (OVH-specific, not AWS):**

```bash
export AWS_ENDPOINT=https://s3.gra.io.cloud.ovh.net
export AWS_REGION=gra  # Note: 'gra', not 'gra9'
export AWS_S3_ADDRESSING_STYLE=path  # Required for OVH
```

**Bucket access policy:**

- **READ_BUCKETS**: `*` (workers can read from any bucket)
- **WRITE_BUCKETS**: empty (only write to the TES bucket)

### Verification

```bash
# List buckets (local check, using ~/ .aws/config)
aws s3 ls --profile ovh

# Check the Kubernetes Secret
kubectl get secrets -n funnel ovh-s3-credentials -o yaml
# Should show base64-encoded s3_access_key and s3_secret_key

# Test access from a pod
kubectl run -n funnel s3-test --rm -it \
  --env=AWS_ACCESS_KEY_ID=$(kubectl get secret -n funnel ovh-s3-credentials -o jsonpath='{.data.s3_access_key}' | base64 -d) \
  --env=AWS_SECRET_ACCESS_KEY=$(kubectl get secret -n funnel ovh-s3-credentials -o jsonpath='{.data.s3_secret_key}' | base64 -d) \
  --image=amazon/aws-cli:latest \
  -- s3 ls --endpoint-url https://s3.gra.io.cloud.ovh.net/
```

### 💰 Cost Impact

- **S3 storage**: €0.06 per GB/month (minimized by cleanup policies)
- **S3 API calls**: €0.003 per 1000 requests (negligible)

### ✅ Phase 4 Checklist

- [ ] S3 bucket created (visible in OVH Manager)
- [ ] Kubernetes Secret `ovh-s3-credentials` exists
- [ ] Secret contains valid access key & secret
- [ ] Bucket is accessible via `aws s3 ls`

---

## Phase 4.5: Private Container Registry

### What Happens

This phase:

1. Creates an **OVH Managed Private Registry (MPR)** named `tes-mpr` — a Harbor-based container registry
2. Generates **Harbor admin credentials** for the registry
3. Creates a **Harbor project** (namespace) for your images
4. Configures **nerdctl registry auth** on worker nodes so Funnel can pull private task images
5. Optionally sets up **K8s `imagePullSecrets`** for the Funnel worker pod image itself

### Why a Private Registry?

- **Control**: Store custom bioinformatics images (GATK wrappers, pipeline tools, etc.)
- **Security**: Private images not exposed to public Docker Hub
- **Performance**: Low-latency pulls within OVHcloud infrastructure (same region)
- **Vulnerability scanning**: M/L plans include Trivy for automatic scanning
- **Harbor UI**: Web interface for managing images, users, projects, and RBAC

### Architecture

> **Important**: Funnel uses `nerdctl` (not Kubernetes) to pull and run task container images.
> This means Kubernetes `imagePullSecrets` do **not** apply to task images.
> Instead, registry credentials must be configured at the **nerdctl/containerd** level on each worker node.

```
┌──────────────────────────────────────────────────┐
│  OVH Managed Private Registry (Harbor)           │
│  Name: tes-mpr                                   │
│  URL: xxxxxxxx.gra9.container-registry.ovh.net   │
│  (S plan: 200 GB, 15 concurrent connections)     │
└───────────┬──────────────────────────────────────┘
            │
            │ (1) K8s imagePullSecrets → pulls Funnel worker image
            │ (2) nerdctl login → pulls task container images
            │
   ┌────────▼─────────────────────────────────────────┐
   │  Kubernetes Cluster (MKS)                        │
   │  ┌────────────────────────────────────────────┐  │
   │  │ Funnel Worker Pod                          │  │
   │  │  ├─ image: <registry>/funnel:tag  ← (1)   │  │
   │  │  └─ nerdctl pull <registry>/task:tag ← (2) │  │
   │  └────────────────────────────────────────────┘  │
   └──────────────────────────────────────────────────┘
```

### OVH Plans

| Plan | Storage | Connections | Vuln. Scanning | Use Case |
|------|---------|-------------|----------------|----------|
| **S** | 200 GB | 15 | ❌ | Small projects, testing |
| **M** | 200 GB | 45 | ✅ Trivy | SMEs, product teams |
| **L** | 5 TB | 90 | ✅ Trivy | Large orgs, intensive use |

### Step 1: Create the Registry

**Via OVH Control Panel (recommended for first-time setup):**

1. Go to **OVHcloud Manager** → **Public Cloud** → your project
2. Navigate to **Containers & Orchestration** → **Managed Private Registry**
3. Click **Create a private registry**
4. Select region: **GRA9** (same as your MKS cluster)
5. Name: **tes-mpr**
6. Plan: **S** (small — sufficient for most bioinformatics projects)
7. Wait for status to change to **OK** (1-2 minutes)

**Via OVH API (for automation):**

```bash
# Get available plans
PLANS=$(curl -s \
  -H "X-Ovh-Application: $OVH_APP_KEY" \
  -H "X-Ovh-Consumer: $OVH_CONSUMER_KEY" \
  -H "X-Ovh-Timestamp: $(date +%s)" \
  -H "X-Ovh-Signature: ..." \
  "https://eu.api.ovh.com/v1/cloud/project/${OVH_PROJECT_ID}/capabilities/containerRegistry")

# Or using the OVH Python SDK (used in install-ovh-mks.sh):
python3 << 'PYEOF'
import ovh, json
client = ovh.Client(endpoint='ovh-eu')
plans = client.get(f"/cloud/project/{OVH_PROJECT_ID}/capabilities/containerRegistry")
for p in plans:
    print(f"  {p['name']} (id: {p['id']}) — {p['registryLimits']['imageStorage']} storage")
PYEOF

# Create the registry
python3 << 'PYEOF'
import ovh, json
client = ovh.Client(endpoint='ovh-eu')
result = client.post(f"/cloud/project/{OVH_PROJECT_ID}/containerRegistry",
    name="tes-mpr",
    region="GRA9",
    planID="<plan-id-from-above>"  # S plan ID
)
print(json.dumps(result, indent=2))
# Save result['id'] and result['url']
PYEOF
```

### Step 2: Generate Credentials

**Via OVH Control Panel:**

1. In **Managed Private Registry**, find your registry (`tes-mpr`)
2. Click the **`...`** menu → **Generate identification details**
3. Click **Confirm**
4. **Save the username and password** — the password is shown only once!

**Via OVH API:**

```bash
python3 << 'PYEOF'
import ovh, json
client = ovh.Client(endpoint='ovh-eu')
creds = client.post(f"/cloud/project/{OVH_PROJECT_ID}/containerRegistry/{REGISTRY_ID}/users",
    email="tes-admin@example.com",
    login="tes-admin"
)
print(f"Username: {creds['user']}")
print(f"Password: {creds['password']}")  # Save this!
PYEOF
```

> The registry URL will be in the format: `xxxxxxxx.gra9.container-registry.ovh.net`

### Step 3: Create a Harbor Project

After creation, access the **Harbor UI** at your registry URL:

1. Open `https://xxxxxxxx.gra9.container-registry.ovh.net` in your browser
2. Log in with the credentials from Step 2
3. Click **New Project**
4. Name: your namespace (e.g., `cmgantwerpen` or `tes-images`)
5. Access level: **Private**
6. Click **OK**

### Step 4: Configure nerdctl Registry Auth on Worker Nodes

Since Funnel uses `nerdctl` to pull task images, you need registry auth at the containerd/nerdctl level. This is done via a DaemonSet that writes Docker config to each worker node:

```bash
# Create a Kubernetes Secret with Docker registry credentials
kubectl create secret docker-registry regcred \
  -n funnel \
  --docker-server=xxxxxxxx.gra9.container-registry.ovh.net \
  --docker-username=tes-admin \
  --docker-password='<password-from-step-2>'

# Extract the Docker config JSON for nerdctl
DOCKER_CONFIG=$(kubectl get secret regcred -n funnel \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)

# Create a ConfigMap with the Docker config for mounting into worker pods
kubectl create configmap -n funnel docker-registry-config \
  --from-literal=config.json="${DOCKER_CONFIG}"
```

Then, in the Funnel worker pod template, mount this config so nerdctl can use it:

```yaml
# Add to worker pod volumes:
- name: docker-config
  configMap:
    name: docker-registry-config

# Add to worker container volumeMounts:
- name: docker-config
  mountPath: /root/.docker
  readOnly: true
```

**Alternative: DaemonSet approach** (writes auth to each node's host filesystem):

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: registry-auth-setup
  namespace: funnel
spec:
  selector:
    matchLabels:
      app: registry-auth
  template:
    spec:
      initContainers:
      - name: setup-auth
        image: busybox:latest
        command:
        - sh
        - -c
        - |
          mkdir -p /host-docker-config/.docker
          cat > /host-docker-config/.docker/config.json << 'EOF'
          {"auths":{"xxxxxxxx.gra9.container-registry.ovh.net":{"auth":"<base64-user:pass>"}}}
          EOF
        volumeMounts:
        - name: host-root
          mountPath: /host-docker-config
          subPath: root
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.9
      volumes:
      - name: host-root
        hostPath:
          path: /
```

### Step 5: Push Images to Your Registry

```bash
# 1. Login to your OVH registry (from your local machine)
docker login xxxxxxxx.gra9.container-registry.ovh.net \
  -u tes-admin \
  -p '<password>'

# 2. Tag your image for the registry
docker tag my-tool:v1.0 \
  xxxxxxxx.gra9.container-registry.ovh.net/cmgantwerpen/my-tool:v1.0

# 3. Push
docker push xxxxxxxx.gra9.container-registry.ovh.net/cmgantwerpen/my-tool:v1.0
```

**Image naming convention:**

```
xxxxxxxx.gra9.container-registry.ovh.net/cmgantwerpen/my-tool:v1.0
└────────────────────────────────────┘ └────────────┘ └──────┘ └──┘
           Registry URL                  Project       Image   Tag
```

### Step 6: Use Private Images in WDL Workflows

```wdl
task run_custom_analysis {
  input {
    File input_file
  }

  command {
    echo "Running analysis with private image..."
  }

  runtime {
    docker: "xxxxxxxx.gra9.container-registry.ovh.net/cmgantwerpen/my-tool:v1.0"
  }

  output {
    File result = stdout()
  }
}
```

### Verification

```bash
# 1. Check registry in OVHcloud Manager
#    Status should show "OK"

# 2. Verify K8s secret exists
kubectl get secret regcred -n funnel

# 3. Test docker login from your machine
docker login xxxxxxxx.gra9.container-registry.ovh.net

# 4. Verify Harbor UI access
#    Open: https://xxxxxxxx.gra9.container-registry.ovh.net
#    Should see your project and pushed images

# 5. Test nerdctl pull from a worker node (via debug pod)
kubectl run -n funnel nerdctl-test --rm -it \
  --image=xxxxxxxx.gra9.container-registry.ovh.net/cmgantwerpen/my-tool:v1.0 \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"regcred"}]}}' \
  --restart=Never \
  -- echo "Image pulled successfully!"
```

### Important Notes

⚠️ **nerdctl vs K8s image pulling**: Funnel uses nerdctl to pull task images on the host, not Kubernetes. K8s `imagePullSecrets` only affect the Funnel worker pod image itself, not the task container images.

⚠️ **Registry URL is unique**: Each registry gets a random hash prefix (e.g., `8093ff7x.gra5.container-registry.ovh.net`). Store this in `env.variables`.

⚠️ **Credentials are sensitive**: Never commit passwords to git. Use K8s Secrets or environment variables.

⚠️ **Harbor projects**: Images must be pushed to an existing Harbor project. Create one before pushing.

### 💰 Cost Impact

| Plan | Monthly Cost | Storage | Notes |
|------|-------------|---------|-------|
| **S** | ~€5/month | 200 GB | Sufficient for most use cases |
| **M** | ~€15/month | 200 GB | Includes Trivy vulnerability scanning |
| **L** | ~€45/month | 5 TB | For large image collections |

- Image pulls within OVH: **FREE** (no bandwidth charges)
- Image pushes: Included in plan

### ✅ Phase 4.5 Checklist

- [ ] Registry "tes-mpr" created in GRA9 (visible in OVHcloud Manager, status: OK)
- [ ] Harbor admin credentials generated and securely stored
- [ ] Harbor project created (e.g., `cmgantwerpen`)
- [ ] K8s Secret `regcred` created in `funnel` namespace
- [ ] nerdctl registry auth configured on worker nodes (Docker config mounted)
- [ ] Test image pushed to registry from local machine
- [ ] Test image pulled successfully in a Funnel task
- [ ] Registry URL stored in `env.variables` as `MPR_REGISTRY_URL`

---

## Phase 5: Deploy Funnel TES

### What Happens

This phase:

1. Creates **Funnel namespace** + RBAC
2. Deploys **Funnel Server** (REST API, gRPC, task queue)
3. Configures **nerdctl executor** for task container execution
4. Sets up **Cinder auto-expansion** disk manager
5. Exposes Funnel via **LoadBalancer service**

### Key Configuration

**Funnel Server ConfigMap** (`funnel-configmap.yaml`):

```yaml
Worker:
  WorkDir: /var/funnel-work     # Cinder volume, auto-expandable
  Container:
    DriverCommand: nerdctl      # Container executor
    RunCommand: run -i --net=host \
      --volume /mnt/shared:/mnt/shared:rw \  # NFS shared mount
      --volume /var/funnel-work:/var/funnel-work:rw \  # Task disk
      {{.Image}} {{.Command}}
```

**Funnel Worker pods** are created as Kubernetes Jobs with:

- **init-containers**:
  - `wait-for-workdir`: polls for Cinder volume mount
  - `wait-for-nfs`: polls for NFS availability
- **main container**: `funnel-worker` (runs the executor & task submission loop)

### Execution

```
============================================
 Phase 5: Deploy Funnel
============================================

Creating Funnel namespace + RBAC...
✅ ServiceAccount, Role, RoleBinding created

Building funnel-disk-setup image (if needed)...
✅ Image already exists: docker.io/cmgantwerpen/funnel-disk-setup:v17

Deploying Funnel Server...
deployment "funnel" successfully rolled out
✅ Funnel Server running (1 replica)

Deploying funnel-disk-setup DaemonSet (Cinder auto-expander)...
daemonset "funnel-disk-setup" successfully rolled out
✅ DaemonSet deployed (pod per worker node)

Exposing Funnel via LoadBalancer...
✅ Service created (external IP: 51.68.237.8)
```

### Verification

```bash
# Check Funnel Server
kubectl get deployment -n funnel
# NAME     READY   UP-TO-DATE   AVAILABLE   AGE
# funnel   1/1     1            1           5m

# Check Funnel Server is listening
kubectl logs -n funnel deployment/funnel | grep "listening"
# Should see: "Listening on :8000" + ":9090"

# Check Cinder auto-expander DaemonSet
kubectl get daemonset -n funnel
# NAME                  DESIRED   CURRENT   READY   UP-TO-DATE   AGE
# funnel-disk-setup     1         1         1       1            3m

# Check LoadBalancer external IP
kubectl get svc -n funnel
# NAME                 TYPE           CLUSTER-IP       EXTERNAL-IP      PORT(S)
# funnel-server        LoadBalancer   10.0.1.234       51.68.237.8      8000:32000/TCP,9090:31234/TCP
# tes-service          ClusterIP      10.0.1.235       <none>           9090/TCP

# Test Funnel API
curl http://51.68.237.8:8000/v1/tasks
# Should return: {"tasks":[]}  (empty initially)
```

### 💰 Cost Impact

- **Funnel server pod**: negligible (100 m CPU request)
- **Worker pods** (created per task): variable (depends on task requests)
- **DaemonSet overhead**: minimal (per node)

### ✅ Phase 5 Checklist

- [ ] Funnel Server pod is Running
- [ ] LoadBalancer has external IP assigned
- [ ] Cinder auto-expander DaemonSet is Running
- [ ] Funnel API responds to `/v1/tasks`

---

## Phase 6: Configure Cromwell

### What Happens

This phase prepares Cromwell for TES submission but doesn't deploy it (Cromwell is typically run locally on your machine):

1. Generates **cromwell-tes.conf** (Cromwell ↔ Funnel TES config)
2. Outputs **Cromwell startup command** for local execution

### Execution

```
============================================
 Phase 6: Cromwell configuration
============================================

Rendering Cromwell config from template...
✅ cromwell-tes.conf generated

Backend configuration:
  - backend: tes
  - tes_endpoint: http://51.68.237.8:8000
  - root: s3://tes-tasks-c386d174c0974008bac7b36c4dfafb23-gra9/cromwell/
  - nfs_root: /mnt/shared

S3 credentials:
  - endpoint_url: https://s3.gra.io.cloud.ovh.net
  - access_key: (from env)
  - secret_key: (from env)
```

### Starting Cromwell (Manual Step)

On your **local machine**:

```bash
cd OVH_installer/cromwell

# Load OpenStack credentials (for display only, not used by Cromwell)
source ../installer/openrc-tes-pilot.sh

# Source environment variables
source ../installer/env.variables

# Start Cromwell server
java -DLOG_LEVEL=INFO \
  -Dconfig.file=cromwell-tes.conf \
  -jar cromwell-93-0232cbd-SNAP.jar \
  server > cromwell.log 2>&1 &

echo "Cromwell starting... check cromwell.log"
sleep 15

# Verify it's running
curl -s http://localhost:7900/api/workflows/v1 | python3 -m json.tool
# Should return workflow list (empty)
```

### Configuration Details

**Key settings in `cromwell-tes.conf`:**

```hocon
backend {
  default = "tes"
  
  providers {
    tes {
      actor-factory = "cromwell.backend.impl.tes.TesBackendFactory"
      config {
        root = "s3://tes-tasks-c386d174c0974008bac7b36c4dfafb23-gra9/cromwell/"
        tes_endpoint = "http://51.68.237.8:8000"  # Funnel LoadBalancer
      }
    }
  }
}

filesystems {
  s3 {
    auth = "default"  # Uses AWS_* env vars
    endpoint_url = "https://s3.gra.io.cloud.ovh.net"
  }
  
  local.local-root = "/mnt/shared"  # NFS mount path
}
```

### Verification

```bash
# Check Cromwell is accepting submissions
curl -s http://localhost:7900/api/workflows/v1 | python3 -m json.tool

# Submit a test workflow (see Phase 7)
```

### ✅ Phase 6 Checklist

- [ ] cromwell-tes.conf is rendered with correct endpoints
- [ ] Cromwell started successfully (check cromwell.log)
- [ ] Cromwell API responds at http://localhost:7900

---

## Phase 7: Verification & Testing

### Smoke Test: Submit EfsTest Workflow

This WDL workflow tests:
- NFS mount visibility inside task containers
- Read/write access to `/mnt/shared`
- S3 bucket access for task submission

#### WDL Workflow Code

File: `wdl/efs.wdl`

```wdl
version 1.0

workflow EfsTest {
  call write_to_efs
}

task write_to_efs {
  command <<<
    echo "Testing /mnt/shared mount..."
    df -h /mnt/shared
    
    mkdir -p /mnt/shared/gra9/test
    date "+%Y%m%d-%H%M%S" > /mnt/shared/gra9/test/$(date +%Y%m%d-%H%M%S).txt
    
    echo "File written:"
    ls -la /mnt/shared/gra9/test/
  >>>
  
  output {
    Array[String] log = read_lines(stdout())
  }
  
  runtime {
    docker: "public.ecr.aws/lts/ubuntu:latest"
    cpu: 1
    memory: "512 MB"
    disk: "1 GB"
  }
}
```

#### Submission

```bash
cd OVH_installer

# Set Cromwell endpoint
export CROMWELL_URL=http://localhost:7900

# Submit workflow
curl -s http://localhost:7900/api/workflows/v1 -X POST \
  -F "workflowSource=@wdl/efs.wdl" \
  -F "workflowInputs=@wdl/efs.inputs.json" \
  -F "workflowOptions=@wdl/efs.options.json" | python3 -m json.tool

# Expected output:
# {
#   "id": "29f532f3-9c94-44be-b258-0621db45e89d",
#   "status": "Submitted"
# }
```

#### Monitoring

```bash
# Store the workflow ID
WF_ID="29f532f3-9c94-44be-b258-0621db45e89d"

# Poll status
watch -n 5 "curl -s http://localhost:7900/api/workflows/v1/$WF_ID/status | python3 -m json.tool"

# Check Funnel task status
kubectl logs -n funnel -l app=funnel-worker | tail -50

# Check worker node status
kubectl get pods -n funnel -o wide
```

#### Expected Output

After ~30-60 seconds:

```json
{
  "id": "29f532f3-9c94-44be-b258-0621db45e89d",
  "status": "Succeeded"
}
```

**Task output confirms NFS is working:**

```
  "outputs": {
    "EfsTest.write_to_efs.log": [
      "Testing /mnt/shared mount...",
      "Filesystem     Size Used Avail Use% Mounted on",
      "192.168.100.56:/shares/share-eb3a91cb-210b-4955-8b51-97045c7b1692 147G 2.0M 140G 1% /mnt/shared",
      "total 4",
      "-rw-r--r-- 1 root root 387 Mar 12 14:35 20260312-145531.txt"
    ]
  }
```

✅ **NFS is working correctly inside task containers!**

### Full Verification Checklist

```bash
#!/bin/bash
# Comprehensive cluster health check

KUBECONFIG=~/.kube/ovh-tes.yaml

echo "=== Cluster Health ==="
kubectl get nodes -o wide
kubectl get clusterroles | head -5

echo "=== Storage ==="
kubectl get pvc -A
kubectl get sc

echo "=== Funnel ==="
kubectl get deployment,daemonset,pod -n funnel -o wide

echo "=== Networking ==="
kubectl get svc -n funnel -o wide

echo "=== Resource Usage ==="
kubectl top nodes 2>/dev/null || echo "(metrics-server not ready)"
kubectl top pods -n funnel 2>/dev/null || echo "(metrics-server not ready)"

echo "=== S3 Bucket ==="
aws s3 ls --profile ovh

echo "=== NFS Test ==="
kubectl exec -n funnel $(kubectl get pod -n funnel -l app=funnel-disk-setup -o name | head -1) -- \
  mountpoint /mnt/shared && echo "✅ NFS mounted" || echo "❌ NFS not mounted"
```

---

## Container Images

### Custom-Built Images

These images are built from source in this repository and may be rebuilt if you modify the code:

#### 1. **funnel-disk-setup:v17**

**Purpose**: Cinder volume mount + auto-expansion + NFS keepalive DaemonSet

**Source**: `OVH_installer/installer/disk-autoscaler/Dockerfile`

**Responsibilities**:
- Mount Cinder volumes at `/var/funnel-work` using `/dev/openstack` labels
- LUKS unlock (using passphrase from env)
- LVM extend (auto-expansion when disk fill reaches threshold)
- NFS mount (`setup-nfs-host` container in Funnel worker Job initContainers)
- Keepalive loop (touch `/mnt/shared/.keepalive` every 30s)

**Build**:

```bash
cd OVH_installer/installer/disk-autoscaler
docker build -t docker.io/cmgantwerpen/funnel-disk-setup:v18 .
docker push docker.io/cmgantwerpen/funnel-disk-setup:v18
```

**Update in env.variables**:

```bash
FUNNEL_DISK_SETUP_IMAGE="docker.io/cmgantwerpen/funnel-disk-setup:v18"
```

#### 2. **Karpenter OVHcloud Provider**

**Purpose**: Kubernetes node autoscaler for OVHcloud

**Repository**: [antonin-a/karpenter-provider-ovhcloud](https://github.com/antonin-a/karpenter-provider-ovhcloud) (forked & maintained separately)

**Source**: `karpenter-provider-ovhcloud/` (in this workspace)

**Our version**: Built on `main` branch; includes OVHcloud API integration for node creation/deletion

**Build** (if modifying):

```bash
cd karpenter-provider-ovhcloud
docker build -t docker.io/cmgantwerpen/karpenter-provider-ovhcloud:latest .
docker push docker.io/cmgantwerpen/karpenter-provider-ovhcloud:latest
```

**Helm value override** (in install-ovh-mks.sh):

```bash
--set image.repository="cmgantwerpen/karpenter-provider-ovhcloud:latest"
```

### Forked/Third-Party Images

These are published external images; we point to them but don't build them:

#### 1. **Funnel TES**

**Purpose**: Task execution service (REST API + gRPC, nerdctl executor)

**Repository**: [ohsu-comp-bio/funnel](https://github.com/ohsu-comp-bio/funnel) (main)

**Our branch**: `feat/k8s-ovh-improvements` (in this workspace)

**Published image**: `docker.io/cmgantwerpen/funnel:multiarch-revbe2fbce-s3fix`

**Tag explanation**:
- `multiarch`: supports arm64 + amd64
- `revbe2fbce`: Funnel git commit
- `s3fix`: custom fix for OVH S3 compatibility

**Source code location**: `funnel-src/cromwell/` (in this workspace, for reference only)

**Credentials**: Stored in `cromwell-src/` for audit trail

#### 2. **Ubuntu Base Image**

**Used by**: Task containers (default)

**Image**: `public.ecr.aws/lts/ubuntu:latest` (AWS ECR, public)

**Note**: No OVH-specific modifications; plain Ubuntu with essential tools

#### 3. **OVH Cloud Providers**

**Purpose**: Cloud provider plugins for Kubernetes

- **Manila CSI Driver**: for NFS provisioning
- **Cinder CSI Driver**: for block storage

**Deployed via**: Helm charts during `openstack-cloud-controller-manager` init

---

## Troubleshooting

### Issue: Task pods failing with "cannot stat '/mnt/shared': Input/output error"

**Cause**: NFS mount dropped (idle TCP timeout).

**Solution**:

1. Check NFS keepalive DaemonSet is running:
   ```bash
   kubectl get daemonset -n funnel funnel-disk-setup
   kubectl logs -n funnel -l app=funnel-disk-setup -c holder | tail -20
   ```

2. Verify `.keepalive` touchdowns are happening:
   ```bash
   kubectl exec -n funnel $(kubectl get pod -n funnel -l app=funnel-disk-setup -o name | head -1) -- \
     ls -la /mnt/shared/.keepalive
   # Should show recent timestamp
   ```

3. If stale, manually remount:
   ```bash
   kubectl delete pods -n funnel -l app=funnel-disk-setup
   # DaemonSet will recreate them and remount NFS
   ```

### Issue: Karpenter not scaling up nodes when tasks arrive

**Cause**: Insufficient quota or node pool configuration issue.

**Diagnosis**:

```bash
# Check nodeclaims status
kubectl get nodeclaims -A
kubectl describe nodeclaim <name>

# Check Karpenter logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | tail -50

# Check node pool limits
kubectl get nodepool workers -o yaml | grep -A 10 "limits:"

# Check if pods are stuck in Pending
kubectl get pods -n funnel
```

**Solutions**:

- **Quota exceeded**: Increase project quota in OVH Manager (Compute → Quotas)
- **Node pool limits hit**: Edit `KUBECONFIG=~/.kube/ovh-tes.yaml kubectl edit nodepool workers`
  - Increase `.spec.limits.cpu` or `.spec.limits.memory`
- **OVH API error**: Check Karpenter token (KARPENTER_APP_KEY, etc.) is valid

### Issue: NFS mount failures during cluster startup

**Cause**: Private network not created before MKS cluster creation.

**Prevention**: Always run Phase 1 (it creates the network first).

**Recovery** (if it happened):

```bash
# Recreate private network manually
openstack network create tes-private-net \
  --provider:network_type vxlan \
  --provider:segmentation_id 0

# Then redeploy Funnel
cd OVH_installer/installer
./install-ovh-mks.sh
# Skip to Phase 5
```

### Issue: S3 bucket access "Access Denied"

**Cause**: Credentials invalid or bucket policy misconfigured.

**Diagnosis**:

```bash
# Check credentials in Secret
kubectl get secret -n funnel ovh-s3-credentials -o yaml

# Test credentials locally
export AWS_ACCESS_KEY_ID=$(echo "..." | base64 -d)
export AWS_SECRET_ACCESS_KEY=$(echo "..." | base64 -d)
aws s3 ls --endpoint-url https://s3.gra.io.cloud.ovh.net
```

**Solution**:

1. Regenerate S3 credentials in OVH Manager
2. Update `OVH_S3_ACCESS_KEY` and `OVH_S3_SECRET_KEY` in `env.variables`
3. Rerun Phase 4 to update the Kubernetes Secret
4. Restart Funnel pods: `kubectl rollout restart deployment/funnel -n funnel`

### Issue: Cromwell submits workflow but Funnel never receives task

**Cause**: Cromwell → Funnel network connectivity issue.

**Diagnosis**:

```bash
# Check Funnel LoadBalancer service
kubectl get svc -n funnel
# Should show external IP

# Test connectivity from local machine
curl -I http://<EXTERNAL_IP>:8000/api/v1/tasks

# Check Funnel server logs
kubectl logs -n funnel deployment/funnel | grep -i "error\|listening"

# Check network policies aren't blocking
kubectl get networkpolicies -A
```

**Solution**:

- If Funnel service has no external IP: Check OVH project quotas (Floating IP count)
- If connectivity timeout: Verify security group allows port 8000 (TCP)

### Issue: Karpenter pod CPU/memory throttled

**Symptom**: Karpenter logs show reconciliation timeouts; nodes not scaling quickly.

**Cause**: Too many node types in instance selector (expensive reconciliation).

**Solution**:

```bash
# Reduce instance type diversity
kubectl edit nodepool workers
# Change .spec.template.spec.requirements[].values to subset:
# - "c3-4"   (small: 2 vCPU, 8 GB)
# - "b2-7"   (medium: 2 vCPU, 7 GB)
# - "r3-8"   (large: 4 vCPU, 32 GB)
# Karpenter will still pick cheapest option that fits
```

---

## Appendix: Useful Commands

### Cluster Inspection

```bash
export KUBECONFIG=~/.kube/ovh-tes.yaml

# Nodes
kubectl get nodes -o wide
kubectl describe node <node-name>
kubectl top node

# Pods across all namespaces
kubectl get pods -A
kubectl get pods -n funnel -o wide

# Storage
kubectl get pv,pvc -A
kubectl get storageclass

# Network
kubectl get svc -A -o wide
kubectl get ing -A
```

### Logs & Debugging

```bash
# Funnel server
kubectl logs -n funnel deployment/funnel -f

# Funnel worker (task executor) for specific task
kubectl logs -n funnel <task-pod-name> -c funnel-worker

# Karpenter autoscaler
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f

# DaemonSet (NFS keeper)
kubectl logs -n funnel -l app=funnel-disk-setup -c holder

# Describe pod for events
kubectl describe pod -n funnel <pod-name>
```

### S3 Operations

```bash
# List buckets
aws s3 ls --profile ovh

# List bucket contents
aws s3 ls s3://tes-tasks-c386d174c0974008bac7b36c4dfafb23-gra9/ --recursive

# Download file
aws s3 cp s3://tes-tasks-c386d174c0974008bac7b36c4dfafb23-gra9/cromwell/path/to/file ./local-file

# Clean old files
aws s3 rm s3://tes-tasks-c386d174c0974008bac7b36c4dfafb23-gra9/ --recursive --exclude "*" --include "cromwell/*" --older-than 30
```

### NFS Operations

```bash
# Check NFS mount from DaemonSet pod
kubectl exec -n funnel <daemonset-pod> -- mountpoint /mnt/shared

# List NFS contents
kubectl exec -n funnel <daemonset-pod> -- ls -la /mnt/shared/gra9/

# Check disk usage
kubectl exec -n funnel <daemonset-pod> -- df -h /mnt/shared

# Delete old test files
kubectl exec -n funnel <daemonset-pod> -- rm -rf /mnt/shared/gra9/test/*
```

### Workflow Submission (Cromwell CLI)

```bash
# Get all workflows
curl -s http://localhost:7900/api/workflows/v1 | python3 -m json.tool

# Get specific workflow status
curl -s http://localhost:7900/api/workflows/v1/<WF_ID>/status

# Get workflow outputs
curl -s http://localhost:7900/api/workflows/v1/<WF_ID>/outputs | python3 -m json.tool

# Get workflow metadata (detailed info)
curl -s http://localhost:7900/api/workflows/v1/<WF_ID>/metadata | python3 -m json.tool

# Abort workflow
curl -X POST http://localhost:7900/api/workflows/v1/<WF_ID>/abort
```

---

## Summary

| Phase | Duration | Component | Verification |
|-------|----------|-----------|--------------|
| 0 | 5 min | Environment & tools | `kubectl version` |
| 1 | 15 min | MKS cluster | `kubectl get nodes` |
| 2 | 10 min | Karpenter autoscaler | `kubectl get nodepool` |
| 3 | 15 min | Manila NFS storage | `kubectl get pvc -n funnel` |
| 4 | 5 min | S3 object storage | `aws s3 ls --profile ovh` |
| 5 | 10 min | Funnel TES deployment | `kubectl get svc -n funnel` |
| 6 | 5 min | Cromwell configuration | `curl http://localhost:7900/api/workflows/v1` |
| 7 | 5 min | Smoke test | EfsTest workflow Succeeded |
| **Total** | **~65 min** | **Full platform** | **✅ Ready for production** |

---

**Document Version**: 1.0  
**Last Updated**: March 12, 2026  
**Next Review**: June 12, 2026 (quarterly)  
**Maintainer**: CMG UZA Team
