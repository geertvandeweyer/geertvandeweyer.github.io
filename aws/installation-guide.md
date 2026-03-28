---
layout: default
title: "AWS Installation Guide"
description: "Guide to deploying Cromwell + TES on AWS EKS (eu-north-1)"
permalink: /aws/installation-guide/
---

# AWS EKS Installation Guide

**Deploying Cromwell + Funnel TES on AWS EKS with Karpenter**

> **NOTE:** This is a stub page — contents will be revised after production validation on eu-north-1. The architecture and phase outline below reflect the intended deployment plan.

---

## Architecture Overview

```
AWS (eu-north-1 / Stockholm, 3 AZ)
┌────────────────────────────────────────────────────┐
│ VPC (10.0.0.0/16)                                    │
│ ├─ Public subnets (ALB, NAT Gateway)                 │
│ └─ Private subnets (EKS nodes, EFS mount targets)      │
└────────────────────────────────────────────────────┘
         │
         ├─ EKS Cluster (Kubernetes 1.34)
         │  ├─ System Node (t4g.medium, always-on)
         │  │  ├─ Karpenter Controller
         │  │  └─ Funnel Server
         │  └─ Worker Nodes (Karpenter-managed, Spot)
         │     └─ Task Pods (on demand)
         │
         ├─ EFS (Elastic File System)
         │  └─ Multi-AZ shared storage, NFS-mounted
         │
         ├─ EBS volumes (per task)
         │  └─ gp3, auto-provisioned by Karpenter
         │
         ├─ ECR (Elastic Container Registry)
         │  └─ Private container image registry
         │
         └─ S3
            └─ Task I/O, workflow inputs/outputs, cold archive
```

**Key Technologies**

| Technology | Role | Details |
|---|---|---|
| **EKS** | Kubernetes cluster | Managed service, $0.10/hr control plane |
| **Karpenter** | Auto-scaling | Scales workers on demand, Spot support |
| **EFS** | Shared storage | Multi-AZ NFS, CSI driver |
| **EBS** | Task local storage | gp3 volumes, auto-provisioned |
| **S3** | Object storage | Workflow I/O, cold archive |
| **ECR** | Container registry | Private registry for task images |

---

## Deployment Phases (Planned)

| Phase | Description | Estimated Time |
|---|---|---|
| **Phase 0** | Prerequisites: AWS account, IAM, quotas, tools | 15 min |
| **Phase 1** | VPC + EKS cluster creation (eksctl / CloudFormation) | 25–35 min |
| **Phase 2** | Karpenter autoscaler installation | 10 min |
| **Phase 3** | EFS shared storage + CSI driver | 10 min |
| **Phase 4** | S3 configuration + IAM policies | 10 min |
| **Phase 5** | ECR registry setup + image push | 10 min |
| **Phase 6** | Funnel TES deployment | 10 min |
| **Phase 7** | Cromwell integration + verification | 15 min |

**Estimated total: ~90–120 minutes**

---

## (P)rerequisites

### P.1 Micromamba / Conda

Install **Micromamba or Conda** with an `aws` environment. This is recommended to keep all tooling and config settings localised and isolated from the system Python.

```bash
# Create environment (one-time)
micromamba create -n aws
micromamba activate aws
micromamba install \
  -c conda-forge \
  -c defaults \
  python=3
```

⭐ Keep this env active during the install procedure!

### P.2 AWS CLI v2

The AWS CLI is the primary tool for interacting with all AWS services (EC2, EKS, EFS, S3, IAM, Service Quotas, SSM). Install it as a standalone binary into the conda env:

```bash
BIN_DIR=$(dirname $(which python3))
mkdir -p awscli_release && cd awscli_release
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install --bin-dir "$BIN_DIR" --install-dir "$BIN_DIR/../lib/awscli"
cd ..
```

Verify:
```bash
aws --version
# aws-cli/2.x.x Python/3.x.x Linux/...
```

### P.3 eksctl

`eksctl` is the official CLI for creating and managing EKS clusters and node groups. Install as a standalone binary:

```bash
BIN_DIR=$(dirname $(which python3))
mkdir -p eksctl_release && cd eksctl_release
# pick version: https://github.com/eksctl-io/eksctl/releases
EKSCTL_VERSION="0.224.0"
curl -sLO "https://github.com/eksctl-io/eksctl/releases/download/v${EKSCTL_VERSION}/eksctl_Linux_amd64.tar.gz"
tar -zxvf eksctl_Linux_amd64.tar.gz
mv eksctl "$BIN_DIR"
cd ..
```

Verify:
```bash
eksctl version
# 0.224.0
```

> **Minimum version: 0.224.0** — the Karpenter subnet and security-group discovery tags (`karpenter.sh/discovery`) were auto-applied but silently broken in earlier releases; the fix shipped in v0.224.0 ([#8684](https://github.com/eksctl-io/eksctl/pull/8684)). Older versions will cause Karpenter to fail to provision nodes.
>
> Other notable changes in this range (0.207 → 0.224) with no action required:
> - **v0.215.0**: eksctl now auto-tags the cluster security group with `karpenter.sh/discovery` (previously required manual tagging; still needed the v0.224 fix to work correctly).
> - **v0.218.0**: eksctl-managed CloudFormation stacks have termination protection enabled by default. `eksctl delete cluster` handles this transparently; avoid deleting the stack manually via the AWS console or CLI.
> - **v0.219.0 💥**: AL2023 is now the default AMI for all K8s versions (AL2 deprecated). Our cluster template already pins `amiFamily: AmazonLinux2023` explicitly, so behaviour is unchanged.
> - **v0.222.0**: Default K8s version bumped to 1.34. `env.variables` pins `K8S_VERSION` explicitly, so no impact.

### P.4 kubectl

`kubectl` is the Kubernetes CLI. Install the latest stable release into the conda env:

```bash
BIN_DIR=$(dirname $(which python3))
mkdir -p kubectl_release && cd kubectl_release
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl "$BIN_DIR"
cd ..
```

Verify:
```bash
kubectl version --client
# Client Version: v1.3x.x
```

### P.5 helm

Helm is the Kubernetes package manager, used to deploy Karpenter and the EFS CSI driver. Install the latest v4 release:

```bash
BIN_DIR=$(dirname $(which python3))
mkdir -p helm_release && cd helm_release
# pick version: https://github.com/helm/helm/releases
wget https://get.helm.sh/helm-v4.1.3-linux-amd64.tar.gz
tar -zxvf helm-v4.1.3-linux-amd64.tar.gz
mv linux-amd64/helm "$BIN_DIR"
cd ..
```

Verify:
```bash
helm version
# version.BuildInfo{Version:"v4.1.3", ...}
```

> **Helm 4 vs Helm 3 — what changed for this installer:**
> - `helm upgrade --install` now defaults to **server-side apply (SSA)** for fresh installs. For Karpenter and the ALB controller this is transparent and improves conflict handling. Re-runs (upgrade path) latch to the previous apply method automatically.
> - `--atomic` is renamed `--rollback-on-failure`; `--force` is renamed `--force-replace`. The old flags still work but emit deprecation warnings. **Neither flag is used in this installer**, so no action needed.
> - `helm registry login/logout` must use the bare domain name only (no path). The installer already calls `helm registry logout public.ecr.aws` — correct as-is.
> - Existing Helm v2 `apiVersion: v1` charts continue to install unchanged.
> - `helm version` output format is identical to v3 (`version.BuildInfo{...}`).

### P.6 gettext (envsubst)

The installer uses `envsubst` (from the `gettext` package) to render YAML and policy templates before applying them. Install via conda:

```bash
micromamba install -c conda-forge gettext
```

Verify:
```bash
envsubst --version
# envsubst (GNU gettext-runtime) ...
```

### P.7 python3

The instance-type filtering script (`update-nodepool-types.sh`) is a Python 3 script embedded in the installer. It only uses the standard library — no extra pip packages are needed. `python3` is already present from step P.1.

```bash
python3 --version
# Python 3.x.x
```

### P.8 AWS Account & IAM Credentials

#### Account requirements

- **AWS account** with billing enabled in the target region (`eu-north-1` by default)
- **IAM user or role** with sufficient permissions (see table below)
- **Programmatic access** via Access Key + Secret Key, EC2 instance profile, or AWS SSO

#### Required IAM permissions

The deploying identity needs the following AWS-managed policies (or an equivalent custom inline policy):

| Policy | Needed for |
|--------|------------|
| `AmazonEKSClusterPolicy` + `AmazonEKSServicePolicy` | EKS cluster creation |
| `AmazonEC2FullAccess` | EC2 instances, VPC, security groups, AMI lookup |
| `IAMFullAccess` | Create Karpenter node role + IRSA roles/policies |
| `AWSCloudFormationFullAccess` | Karpenter prerequisite CloudFormation stack |
| `AmazonS3FullAccess` | Task I/O bucket creation and access |
| `AmazonElasticFileSystemFullAccess` | EFS filesystem + mount target creation |
| `AmazonSSMReadOnlyAccess` | AMI ID lookup via SSM parameter store |
| `ServiceQuotasReadOnlyAccess` | Spot vCPU quota auto-detection |
| `AmazonEC2ContainerRegistryFullAccess` | Image push to ECR during build phase |

⭐ A minimal scoped inline policy covering only the resources created by this installer is available at `policies/iam-installer-policy.json`.

> **Deploying identity vs runtime identities — these are separate.**
> The permissions above are only needed by the person (or CI/CD pipeline) running the installer — a one-time operation. They are **not** embedded in the cluster.
>
> Once the cluster is running, every component operates under its own purpose-built, minimally-scoped IAM role created by the installer:
>
> | Runtime role | Used by | Scope |
> |---|---|---|
> | `KarpenterNodeRole-${CLUSTER_NAME}` | Worker EC2 nodes (instance profile) | ECR pull, EKS node join, SSM, EBS/EFS access |
> | `${CLUSTER_NAME}-karpenter` | Karpenter controller pod (Pod Identity / IRSA) | EC2 run/terminate, SQS interruption queue — cluster-scoped |
> | `${CLUSTER_NAME}-iam-role` | Funnel/TES pods (IRSA) | S3 read/write on the task bucket only |
> | ALB controller role | ALB controller pod (IRSA) | ELB/EC2 management, cluster-scoped |
>
> Your admin credentials are not stored in the cluster and are not used after the install completes.

#### Configure credentials

```bash
aws configure
# AWS Access Key ID:     <your-access-key>
# AWS Secret Access Key: <your-secret-key>
# Default region name:   eu-north-1
# Default output format: json
```

Verify:
```bash
aws sts get-caller-identity
# { "Account": "123456789012", "UserId": "AIDA...", "Arn": "arn:aws:iam::..." }
```

### P.9 Quotas & Capacity

Before starting, ensure your AWS account has sufficient quota in the **target region**. Check via **AWS Console → Service Quotas → EC2**, or with the CLI:

```bash
# Standard Spot Instance vCPU quota
aws service-quotas list-service-quotas \
  --service-code ec2 \
  --region eu-north-1 \
  --query "Quotas[?QuotaName=='All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests'].{Name:QuotaName,Value:Value}" \
  --output table

# On-Demand vCPU quota (for system node)
aws service-quotas list-service-quotas \
  --service-code ec2 \
  --region eu-north-1 \
  --query "Quotas[?QuotaName=='Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances'].{Name:QuotaName,Value:Value}" \
  --output table
```

| Resource | Minimal | Notes |
|----------|---------|-------|
| **Spot vCPU (Standard family)** | 100+ | Karpenter worker pool; auto-detected from `SPOT_QUOTA` in `env.variables` |
| **On-Demand vCPU (Standard family)** | 4+ | System node (`t4g.medium` = 2 vCPU; keep headroom) |
| **EBS gp3 storage (GB)** | 500+ | Auto-provisioned per-task local volumes |
| **EFS filesystems** | 1 | Shared `/mnt/efs` across all worker nodes |
| **VPCs** | 1 | Created by CloudFormation prerequisite stack |
| **Elastic IPs** | 1 | NAT Gateway for private subnet outbound access |
| **NAT Gateways** | 1 | Outbound internet from private subnets |
| **S3 buckets** | 1 | Task I/O and workflow logs |
| **ECR repositories** | 1 | Funnel worker container image |

Request increases via **AWS Console → Service Quotas → Request increase**. Spot vCPU quota increases are typically approved within minutes; EBS and EIP increases within 1–2 hours.


---

## Overview & Architecture

### Platform Components

| Component | Purpose | AWS Service |
|-----------|---------|------------|
| **Kubernetes Cluster** | Container orchestration | EKS (Elastic Kubernetes Service) |
| **System Node** | Control plane + infrastructure (always-on) | EC2 t4g.medium |
| **Worker Nodes** | Task execution (auto-scaled) | EC2 (Karpenter-managed) |
| **Shared Storage** | Workflow data & reference files | EFS (Elastic File System) |
| **Object Storage** | Task I/O, logs, artifacts | S3 (Simple Storage Service) |
| **Orchestrator** | TES API for task execution | Funnel (container-native) |
| **Workflow Manager** | WDL workflow submission | Cromwell (hosted locally) |

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    AWS Account (us-east-1)                      │
├─────────────────────────────────────────────────────────────────┤
│                         VPC (10.0.0.0/16)                        │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │   EKS Cluster (Kubernetes 1.31+)                          │ │
│  │  ┌──────────────────────────────────────────────────────┐ │ │
│  │  │ System Node (t4g.medium, bootstrap)                 │ │ │
│  │  │ ├─ Karpenter Controller (2 replicas, HA)            │ │ │
│  │  │ ├─ Funnel Server (task queue)                       │ │ │
│  │  │ └─ Cromwell Server (localhost:7900)                 │ │ │
│  │  └──────────────────────────────────────────────────────┘ │ │
│  │  ┌──────────────────────────────────────────────────────┐ │ │
│  │  │ Worker Nodes (on-demand, Karpenter-managed)         │ │ │
│  │  │ ├─ c6g.large (2 vCPU, 8 GB) — small tasks           │ │ │
│  │  │ ├─ c6g.xlarge (4 vCPU, 16 GB) — medium tasks        │ │ │
│  │  │ └─ m6g.2xlarge (8 vCPU, 32 GB) — large tasks        │ │ │
│  │  └──────────────────────────────────────────────────────┘ │ │
│  │  ┌──────────────────────────────────────────────────────┐ │ │
│  │  │ Shared Services                                      │ │ │
│  │  │ ├─ EFS CSI Driver (mounts EFS on all nodes)          │ │ │
│  │  │ ├─ AWS Load Balancer Controller (ALB/NLB)           │ │ │
│  │  │ └─ CoreDNS, kube-proxy                              │ │ │
│  │  └──────────────────────────────────────────────────────┘ │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ┌─────────────┬──────────────────────────┬──────────────────┐ │
│  │   EFS       │      S3 Buckets          │   ECR Registry   │ │
│  │ (150 GB,    │ (task I/O, logs,         │ (Funnel image)   │ │
│  │  ReadWrite) │  artifacts)              │                  │ │
│  └─────────────┴──────────────────────────┴──────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### Key Differences from OVH

| Aspect | AWS | OVH |
|--------|-----|-----|
| **Cluster Creation** | CloudFormation + eksctl | ovhcloud CLI |
| **Shared Storage** | EFS (managed NFS) | Manila (managed NFS) |
| **Object Storage** | S3 (AWS-native) | OVH S3-compatible API |
| **VM Provisioning** | EC2 via AWS | OpenStack via OVH |
| **Authentication** | IAM roles/policies | OVH API tokens |
| **Cost Model** | Pay-per-hour on-demand | Fixed project quota + overage |
| **Karpenter Limits** | Spot quota limits | vCPU/RAM quota limits |

---

## Phase 0: Environment Setup

### Step 1: Clone Installer

```bash
cd /path/to/workspace
git clone https://github.com/your-org/k8s.git
cd k8s/AWS_installer/installer
```

### Step 2: Configure env.variables

Edit `./env.variables` with your AWS settings:

```bash
# Required: AWS account & region
export CLUSTER_NAME="TES"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_ACCOUNT_ID="123456789012"  # Get from `aws sts get-caller-identity`

# Kubernetes version
export K8S_VERSION="1.34"  # Check latest EKS support

# Karpenter
export KARPENTER_VERSION="1.9.0"
export KARPENTER_REPLICAS=2  # HA for production

# Storage
export USE_EFS="true"
export EFS_ID=""  # Will be created by installer
export TES_S3_BUCKET="tes-tasks-${AWS_ACCOUNT_ID}-${AWS_DEFAULT_REGION}"

# Funnel TES
export TES_NAMESPACE="funnel"
export ECR_IMAGE_REGION="us-east-1"  # Where Funnel image is stored
export FUNNEL_IMAGE="${AWS_ACCOUNT_ID}.dkr.ecr.${ECR_IMAGE_REGION}.amazonaws.com/funnel:multiarch-revc590523e-develop"

# Performance
export EBS_IOPS=3000        # EBS baseline IOPS
export EBS_THROUGHPUT=250   # EBS baseline throughput (MB/s)

# Optional: External access IP (for firewall rules)
export EXTERNAL_IP="203.0.113.42"  # Your IP (or leave empty)
```

### Step 3: Verify Prerequisites

```bash
bash -c '
  echo "=== AWS CLI ===" && aws --version
  echo "=== eksctl ===" && eksctl version
  echo "=== kubectl ===" && kubectl version --client
  echo "=== Helm ===" && helm version
  echo "=== AWS Credentials ===" && aws sts get-caller-identity
'
```

---

## Phase 1: EKS Cluster Creation

The installer uses **CloudFormation** to create EKS infrastructure.

### Automatic (Recommended)

```bash
cd ./AWS_installer/installer
./install-eks-karpenter.sh
# Runs CloudFormation, eksctl, Helm, kubectl automatically
```

**Expected output:**
```
✅ Deploying CloudFormation stack for Karpenter prerequisites...
✅ CloudFormation stack created successfully.
✅ EKS cluster created: TES
✅ Node group (system-ng) is ACTIVE
✅ kubeconfig updated
```

**Duration**: ~20–30 minutes

### Verification

```bash
# Check cluster access
kubectl get nodes
# NAME                                 STATUS   ROLES    AGE    VERSION
# ip-10-0-1-xx.ec2.internal          Ready    <none>   5m    v1.34.x

# Check system pods
kubectl get pods -n kube-system
# Should see: coredns, kube-proxy, aws-node, ebs-csi-driver, efs-csi-driver

# Check EKS cluster
aws eks describe-cluster --name TES --region us-east-1 --query Cluster.status
# Should return: ACTIVE
```

### Troubleshooting

**Issue**: `eksctl create cluster` hangs or fails

```bash
# Check CloudFormation events
aws cloudformation describe-stack-events --stack-name EKS-TES --region us-east-1

# Check EC2 instances
aws ec2 describe-instances --region us-east-1 --query 'Reservations[*].Instances[*].[InstanceId, State.Name, InstanceType]' --output table

# Delete and retry
eksctl delete cluster --name TES --region us-east-1
```

---

## Phase 2: Karpenter Auto-scaling

### Installation

The installer deploys Karpenter via **Helm** using the OCI chart from public ECR:

```bash
# Automatic (part of install script)
./install-eks-karpenter.sh

# Or manual (see installer for full flag set):
helm upgrade --install karpenter \
  oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace kube-system \
  --create-namespace \
  --set settings.clusterName="${CLUSTER_NAME}" \
  --set settings.interruptionQueue="${CLUSTER_NAME}" \
  --set replicas=1 \
  --wait --timeout 10m
```

> The chart is hosted on **public ECR** (`public.ecr.aws/karpenter/karpenter`) as an OCI artefact — not on `charts.karpenter.sh` (legacy, pre-v1 only). No `helm repo add` step is needed for OCI charts.
> IAM is wired via **Pod Identity Association** (set in `cluster.template.yaml` and created by `eksctl`), not via the old IRSA service-account annotation.

### Karpenter NodePool Configuration

AWS Karpenter differs from OVH: **no per-node vCPU quota** but **Spot quota limits**.

**NodePool YAML** (auto-generated from env.variables):

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: workers
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64", "amd64"]
        - key: node.kubernetes.io/instance-family
          operator: In
          values: ["c6g", "c6i", "m6g", "m6i"]  # Graviton + Intel
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand", "spot"]  # Prefer spot for cost
        - key: karpenter.sh/gpu-count
          operator: In
          values: ["0"]  # No GPU nodes
      nodeClassRef:
        name: default
  limits:
    cpu: 1000        # Max 1000 vCPU (adjust per AWS quota)
    memory: 4000Gi   # Max 4000 GB memory
  consolidateAfter: 30s
  expireAfter: 604800s  # 7 days
```

### AWS-Specific Settings

Unlike OVH, AWS Karpenter controls:

| Setting | Purpose | AWS Specific |
|---------|---------|------------|
| **Instance family** | Compute type (c6g = Graviton ARM) | Filter by cost/performance |
| **Capacity type** | On-demand vs Spot | Spot saves ~70% but can be interrupted |
| **AMI** | OS image (Amazon Linux 2023) | EBS-optimized, AWS-native |
| **VPC subnets** | Network placement | Auto-selected by CloudFormation |
| **IAM instance role** | Worker permissions | Created by installer |
| **Security group** | Firewall rules | Auto-created, allows internal traffic |

### Verification

```bash
# Check Karpenter controller
kubectl get deployment -n karpenter
kubectl logs -n karpenter deployment/karpenter -f | head -20

# Check NodePool
kubectl get nodepools
# NAME      NODEPOOL   CAPACITY   NODES   READY
# workers   default    1000       0       True

# Scale test: create 2 pods
kubectl create deployment test --image=nginx --replicas=2
kubectl get nodes -w
# Karpenter should provision nodes within 30s
```

---

## Phase 3: EFS Shared Storage

### Automatic Setup

The installer creates and mounts EFS:

```bash
# Automatic (part of install script)
./install-eks-karpenter.sh

# Or manual:
./mount-efs.sh  # Runs EFS CSI driver + mounts
```

**Expected output:**
```
✅ EFS created: fs-0bd10f52a04211916
✅ EFS mounted at /mnt/efs (all nodes)
✅ EFS PV and PVC created
```

### Verification

```bash
# Check EFS CSI driver
kubectl get daemonset -n kube-system efs-csi-node

# Check EFS mount on node
kubectl debug node/$(kubectl get nodes -o name | head -1) -it --image=ubuntu
> df -h | grep efs
# 127.0.0.1:/   150G   1G  149G   1% /mnt/efs

# Check EFS usage
kubectl exec -n kube-system -it $(kubectl get pods -n kube-system -l app=efs-csi-node -o name | head -1) -- \
  df -h /mnt/efs
```

### EFS Performance

| Tier | Throughput | Latency | Cost | Use Case |
|------|-----------|---------|------|----------|
| **Standard** | Bursting | <5ms | Low | Most workflows |
| **Max IO** | Provisioned | <5ms | Higher | High-throughput genomics |

For genomics workflows, **Standard** is typically sufficient.

---

## Phase 4: S3 Object Storage

### Bucket Setup

The installer creates S3 buckets:

```bash
export TES_S3_BUCKET="tes-tasks-123456789012-us-east-1"
export READ_BUCKETS="*"  # Allow all buckets

# Automatic (part of install script)
./install-eks-karpenter.sh

# Or manual:
aws s3api create-bucket --bucket "$TES_S3_BUCKET" --region us-east-1
aws s3api put-bucket-versioning --bucket "$TES_S3_BUCKET" --versioning-configuration Status=Enabled
```

### IAM Permissions

Worker pods get S3 access via **IRSA** (IAM Roles for Service Accounts):

```bash
# Installer creates IAM role: TES-iam-role
# Funnel service account linked to role
kubectl get serviceaccount funnel-worker -n funnel -o yaml | grep iam\.amazonaws\.com/role-arn
# arn:aws:iam::123456789012:role/TES-iam-role
```

### S3 Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": ["arn:aws:s3:::tes-tasks-*"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::cromwell-aws-*/*"]
    }
  ]
}
```

---

## Phase 5: Deploy Funnel TES

### Prerequisites

1. **Funnel image** pushed to ECR
2. **EKS cluster** running (Phase 1–4 complete)

### Automatic Deployment

```bash
./install-eks-karpenter.sh
# Runs all phases including Funnel deployment
```

### Manual Deployment

```bash
# Apply Funnel ConfigMap with EFS mounts
envsubst < yamls/funnel-configmap.template.yaml | kubectl apply -f -

# Deploy Funnel server
kubectl apply -f yamls/funnel-namespace.yaml
kubectl apply -f yamls/funnel-deployment.yaml
kubectl apply -f yamls/funnel-tes-service.yaml

# Check status
kubectl get pods -n funnel
kubectl logs -n funnel deployment/funnel -f
```

### Verification

```bash
# Get service endpoint
kubectl get svc -n funnel tes-service
# NAME          TYPE           CLUSTER-IP     EXTERNAL-IP                 PORT(S)        AGE
# tes-service   LoadBalancer   10.100.x.x     a1234567-1234567890.elb.us-east-1.amazonaws.com:8000

# Test TES API
export TES_SERVER=<EXTERNAL-IP>:8000
curl -X GET http://${TES_SERVER}/ga4gh/tes/v1/tasks

# Expected: { "tasks": [] }
```

---

## Phase 6: Configure Cromwell

### Local Installation

```bash
# Download Cromwell JAR
wget https://github.com/broadinstitute/cromwell/releases/download/86/cromwell-86.jar

# Create Cromwell config
cat > cromwell.conf << 'EOF'
include required(classpath("application"))

backend {
  default = TES
  providers {
    TES {
      actor-factory = "cromwell.backend.impl.tes.TesBackendFactory"
      config {
        root = "s3://tes-tasks-123456789012-us-east-1/cromwell"
        tes-server = "http://<TES_ALB_DNS>:8000"
        # EBS volume configuration
        disks = "/mnt/cromwell 100 SSD"
        concurrent-job-limit = 1000
      }
    }
  }
}
EOF

# Run Cromwell
java -Dconfig.file=cromwell.conf -jar cromwell-86.jar server
```

### Submit Workflow

```bash
# Create WDL workflow
cat > hello.wdl << 'EOF'
workflow HelloWorld {
  call hello
  output {
    String greeting = hello.message
  }
}

task hello {
  command {
    echo "Hello, World!"
  }
  output {
    String message = read_string(stdout())
  }
  runtime {
    docker: "ubuntu:22.04"
    cpu: 1
    memory: "512 MB"
  }
}
EOF

# Submit to Cromwell
curl -X POST http://localhost:7900/api/workflows/v1 \
  -H "Content-Type: application/json" \
  -d @- << 'EOF'
{
  "workflowSource": "$(cat hello.wdl)",
  "inputsJson": "{}"
}
EOF
```

---

## Phase 7: Verification & Testing

### Cluster Health

```bash
# Check nodes
kubectl get nodes -o wide

# Check Karpenter
kubectl get nodepools
kubectl top nodes

# Check storage
kubectl get pvc -n funnel
kubectl get storageclasses
```

### Workflow Test

```bash
# Monitor task execution
kubectl get pods -n funnel -w

# Check task logs
kubectl logs -n funnel <pod-name>

# Query TES API
curl http://${TES_SERVER}:8000/ga4gh/tes/v1/tasks/v1/$(TASK_ID)
```

---

## 💰 Cost Estimation

### Monthly Costs (Example)

| Component | Cost | Notes |
|-----------|------|-------|
| **EKS Cluster** | ~$72 | Fixed per cluster |
| **System Node (t4g.medium, on-demand)** | ~$36 | Always-on |
| **Worker Nodes (Karpenter, spot)** | ~$500–1000 | Depends on workflow |
| **EFS Storage (150 GB)** | ~$45 | $0.30/GB-month |
| **EBS Volumes** | ~$50–200 | Task-local storage |
| **S3 Storage & Transfer** | ~$100–500 | Depends on data volume |
| ****Total** | **~$800–2000/month** | Highly variable |

**Cost optimization:**
- Use **Spot instances** (70% cheaper but interruptible)
- Right-size instance types for your workload
- Delete unused EFS/S3 data
- Use **On-Demand Savings Plans** for system node

---

## Troubleshooting

### Issue: EKS Cluster Creation Fails

**Check CloudFormation stack:**
```bash
aws cloudformation describe-stack-events --stack-name EKS-TES
aws cloudformation describe-stacks --stack-name EKS-TES --query 'Stacks[0].StackStatus'
```

**Common causes:**
- Insufficient EC2/vCPU quota
- IAM permissions missing
- Region not available

### Issue: Karpenter Not Scaling

**Check NodePool:**
```bash
kubectl describe nodepool workers
kubectl logs -n karpenter deployment/karpenter | tail -50
```

**Common causes:**
- Spot quota exhausted (fallback to on-demand)
- Pod security policy blocking nodes
- Insufficient EBS quota

### Issue: Funnel Task Fails

**Check worker pod logs:**
```bash
kubectl logs -n funnel <task-pod-name>
kubectl describe pod -n funnel <task-pod-name>
```

**Common causes:**
- EFS not mounted (check `/mnt/efs`)
- S3 credentials expired
- Container image not in ECR

---

## 📚 Related Documentation

- **[Karpenter AWS Provider](/karpenter/cloud-providers/aws/)** — Karpenter-specific AWS setup
- **[AWS Cost Optimization](/aws/cost-and-capacity/)** — Budget planning
- **[AWS Troubleshooting](/aws/troubleshooting/)** — Detailed issue resolution
- **[Cromwell Documentation](https://cromwell.readthedocs.io/)** — Workflow orchestration
- **[Funnel Documentation](https://ohsu-comp-bio.github.io/funnel/)** — Task execution

---

**Last Updated**: March 13, 2026  
**Version**: 1.0  
**Status**: Production-ready
