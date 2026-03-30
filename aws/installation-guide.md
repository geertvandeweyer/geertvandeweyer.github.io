---
layout: default
title: "AWS EKS Installation Guide — Cromwell + Funnel TES + Karpenter Spot"
description: "Step-by-step guide to deploy Cromwell genomics workflows on AWS EKS with Karpenter Spot autoscaling, EFS shared storage, S3, ALB ingress, and Funnel TES task execution."
keywords:
  - AWS EKS
  - Cromwell
  - Funnel TES
  - Karpenter Spot
  - genomics workflow
  - WDL
  - EFS
  - EKS autoscaling
  - bioinformatics AWS
  - Task Execution Service
  - GA4GH TES
  - nerdctl
  - S3
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
│ VPC (10.0.0.0/16)                                  │
│ ├─ Public subnets (ALB, NAT Gateway)               │
│ └─ Private subnets (EKS nodes, EFS mount targets)  │
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
| **Funnel** | TES orchestrator | Kubernetes-native TES API server |
| **Cromwell** | Workflow manager | WDL submission, runs on system node |

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

> **Minimum version: 0.224.0** — the Karpenter subnet and security-group discovery tags (`karpenter.sh/discovery`) were auto-applied but silently broken in earlier releases; the fix shipped in v0.224.0 ([#8684](https://github.com/eksctl-io/eksctl/pull/8684)). Older versions can cause Karpenter to fail to provision nodes.


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

## (E)nvironment Setup

### E.1: Download Installer

```bash
mkdir -p aws_installer
cd aws_installer
wget https://geertvandeweyer.github.io/aws/files/aws_installer.tar.gz
tar -xzf aws_installer.tar.gz
cd installer
```

### E.2: Configure Environment Variables

Edit `env.variables`. Review and complete all settings — no shell logic belongs here, just plain values. Some variables requiring attention are highlighted below:

| Variable Name | Notes |
|---------------|-------|
| `CLUSTER_NAME` | Name for the EKS cluster (used as prefix for all created resources) |
| `AWS_DEFAULT_REGION` | Target AWS region (e.g. `eu-north-1`) |
| `K8S_VERSION` | Tested with 1.34 |
| `SYSTEM_NODE_TYPE` | Always-on bootstrap node; `t4g.medium` (ARM64) keeps the permanent cost minimal |
| `WORKER_INSTANCE_FAMILIES` | Comma-separated EC2 category letters: `c`=compute, `m`=general, `r`=memory, `i`=storage |
| `WORKER_MIN_GENERATION` | Minimum instance generation (e.g. `3` → c3+, m3+, r3+) |
| `WORKER_EXCLUDE_TYPES` | Comma-separated substrings to disqualify types (e.g. `metal,nano,micro,small,flex`) |
| `WORKER_MAX_VCPU` | Per-instance vCPU cap (0 = no cap) |
| `WORKER_MAX_RAM_GIB` | Per-instance RAM cap in GiB (0 = no cap) |
| `WORKER_ARCH` | `amd64` / `arm64` / `graviton` / `both` |
| `WORKER_CPU_VENDOR` | `intel` / `amd` / `both` (only relevant when `WORKER_ARCH=amd64`) |
| `SPOT_QUOTA` | Spot vCPU limit; auto-detected from Service Quotas if blank; pre-fill to cap below your raw quota |
| `ALIAS_VERSION` | AL2023 AMI alias version tag (e.g. `v20260223`); auto-detected from SSM if blank; pre-fill to pin |
| `USE_EFS` | `true` to provision and mount EFS shared storage on all worker nodes |
| `EFS_ID` | Leave blank on first run; the installer creates the filesystem and writes back the ID |
| `ECR_IMAGE_REGION` | AWS region where the Funnel ECR image is stored (may differ from cluster region) |
| `TES_VERSION` | Funnel image tag |
| `EXTERNAL_IP` | IP of the on-prem Cromwell server; only this IP gets inbound access to the TES endpoint |
| `READ_BUCKETS` | Additional S3 buckets worker tasks may read from (wildcards `*` allowed) |
| `WRITE_BUCKETS` | Additional S3 buckets worker tasks may write to |
| `EBS_IOPS` | gp3 IOPS for worker data disk (3,000–80,000; 3,000 = free baseline) |
| `EBS_THROUGHPUT` | gp3 throughput in MB/s (125–1,000; 250 = above baseline, small extra cost) |

> **Auto-derived values** — the following variables can be left blank and will be resolved by the installer at runtime. Pre-fill them to skip the live lookup or to override the derived value:
>
> | Variable | Resolved from |
> |---|---|
> | `AWS_ACCOUNT_ID` | `aws sts get-caller-identity` |
> | `FUNNEL_IMAGE` | `${AWS_ACCOUNT_ID}.dkr.ecr.${ECR_IMAGE_REGION}.amazonaws.com/funnel:${TES_VERSION}` |
> | `TES_S3_BUCKET` | `tes-tasks-${AWS_ACCOUNT_ID}-${AWS_DEFAULT_REGION}` |


### E.3: Verify Prerequisites

```bash
# Check all tools are available
which aws eksctl kubectl helm envsubst python3

# Check AWS credentials
aws sts get-caller-identity
# { "Account": "123456789012", "UserId": "AIDA...", "Arn": "arn:aws:iam::..." }

# Check target region is accessible
aws ec2 describe-availability-zones --region "${AWS_DEFAULT_REGION}" \
  --query 'AvailabilityZones[].ZoneName' --output text

# Check Spot vCPU quota
aws service-quotas list-service-quotas --service-code ec2 \
  --query "Quotas[?QuotaName=='All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests'].Value" \
  --output text
```

---

## (D)eploy Cluster

### What Happens

The installer orchestrates all setup in ordered phases (0–7) to provision AWS infrastructure, deploy Karpenter, configure storage, and deploy Funnel TES.

1. **Phase 0**: Load `env.variables`, derive blank variables (`AWS_ACCOUNT_ID`, `ALIAS_VERSION`, `SPOT_QUOTA`), validate tools and credentials
2. **Phase 1**: Deploy Karpenter prerequisite CloudFormation stack (IAM roles, SQS interruption queue)
3. **Phase 2**: Create EKS cluster via `eksctl` from CloudFormation template, wait for `ACTIVE`, label bootstrap node
4. **Phase 3**: Attach IAM policies to the Karpenter node role (EBS CSI + optional EFS CSI)
5. **Phase 4**: Install Karpenter via Helm (OCI chart from public ECR), verify IRSA/Pod Identity
6. **Phase 4.1**: Apply `EC2NodeClass` (rendered from template + injected userdata), then generate and apply `NodePool` via `update-nodepool-types.sh`
7. **Phase 5**: Create EFS filesystem, deploy EFS CSI addon, configure security groups and mount targets; write back `EFS_ID` to `env.variables`
8. **Phase 6**: Deploy AWS Load Balancer Controller via Helm
9. **Phase 7**: Create Funnel IAM role (IRSA), create S3 task bucket, deploy all Funnel resources from YAML templates

### Execution

```bash
cd installer/
./install-aws-eks.sh
```

The script prints coloured status lines (`✅` / `⚠` / `💥`) for each phase step and stops on the first unrecoverable error. All behaviour is driven by `env.variables` — re-runs are safe and idempotent.

> **NodePool only** — to regenerate the Karpenter `NodePool` after changing instance family or quota settings without re-running the full installer:
> ```bash
> ./update-nodepool-types.sh
> ```

---

## Phase 1: CloudFormation Prerequisites

### Goal

Deploy the Karpenter prerequisite IAM and eventing infrastructure as a CloudFormation stack before the EKS cluster is created.

### What Gets Created

- IAM role `KarpenterNodeRole-${CLUSTER_NAME}` — instance profile for all Karpenter-provisioned worker nodes
- Five `KarpenterController*` IAM policies scoped to the cluster — attached to the Karpenter controller role in Phase 4
- SQS interruption queue named `${CLUSTER_NAME}` — receives Spot interruption and rebalance notices
- EventBridge rules that forward EC2 Spot interruption, rebalance, health, and state-change events into the queue

### Expected Output

```
============================================
 Phase 1: CloudFormation prerequisites
============================================

Deploying CloudFormation stack for Karpenter prerequisites...
  1/40 : Stack status: CREATE_IN_PROGRESS — waiting 15s...
  2/40 : Stack status: CREATE_IN_PROGRESS — waiting 15s...
  ...
✅ CloudFormation stack is CREATE_COMPLETE
```

### Common Issues

- `ROLLBACK_COMPLETE` — usually a missing permission on the deploying IAM identity (`IAMFullAccess` or equivalent required)
- `CAPABILITY_NAMED_IAM` not passed — the stack creates named IAM roles; the CLI flag is required
- Stack already in `ROLLBACK_IN_PROGRESS` from a previous failed run — delete the stack manually before retrying:
  ```bash
  aws cloudformation delete-stack --stack-name "EKS-${CLUSTER_NAME}" --region "${AWS_DEFAULT_REGION}"
  ```

### Manual Verification

```bash
# Check stack status
aws cloudformation describe-stacks \
  --stack-name "EKS-${CLUSTER_NAME}" --region "${AWS_DEFAULT_REGION}" \
  --query "Stacks[0].StackStatus" --output text
# Expected: CREATE_COMPLETE

# Confirm KarpenterNodeRole exists
aws iam get-role --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --query "Role.Arn" --output text

# Confirm SQS queue exists
aws sqs get-queue-url --queue-name "${CLUSTER_NAME}" \
  --region "${AWS_DEFAULT_REGION}" --query "QueueUrl" --output text
```

### ✅ Phase 1 Checklist

- [ ] CloudFormation stack `EKS-${CLUSTER_NAME}` is `CREATE_COMPLETE`
- [ ] IAM role `KarpenterNodeRole-${CLUSTER_NAME}` exists
- [ ] SQS queue `${CLUSTER_NAME}` exists in the target region

---

## Phase 2: EKS Cluster

### Goal

Create the EKS control plane and a single always-on ARM64 baseline node via `eksctl`. This node hosts Karpenter and the Funnel server; all workflow work runs on Karpenter-provisioned Spot nodes.

### What Gets Created

- EKS cluster `${CLUSTER_NAME}` (Kubernetes `${K8S_VERSION}`) with OIDC provider
- Managed nodegroup `${CLUSTER_NAME}-baseline-arm` — 1× `${SYSTEM_NODE_TYPE}` (ARM64, always-on)
- Pod Identity Association for the Karpenter controller SA → `${CLUSTER_NAME}-karpenter` IAM role
- IAM identity mapping so `KarpenterNodeRole-${CLUSTER_NAME}` nodes can join the cluster
- Addons: `eks-pod-identity-agent`, `vpc-cni`
- Node labels: `${BOOTSTRAP_LABEL_KEY}=true`, `workload-type=system`
- VPC subnets tagged `karpenter.sh/discovery=${CLUSTER_NAME}` and `kubernetes.io/cluster/${CLUSTER_NAME}=owned`
- kubeconfig updated at `~/.kube/config`

### Expected Output

```
============================================
 Phase 2: EKS cluster
============================================

Rendering cluster configuration...
Creating EKS cluster 'TES' in eu-north-1 (K8s 1.34)...
2026-03-29 ... creating EKS cluster "TES" in "eu-north-1" region ...
2026-03-29 ... creating managed nodegroup "TES-baseline-arm" ...
2026-03-29 ... EKS cluster "TES" in "eu-north-1" region is ready
Waiting for EKS cluster to reach status 'ACTIVE' (timeout 1800s)...
  [0s/1800s] EKS cluster status: CREATING — waiting...
  ...
✅ EKS cluster is ACTIVE
✅ Cluster endpoint: https://ABCD1234.gr7.eu-north-1.eks.amazonaws.com
✅ VPC ID: vpc-0abc1234
Labeling bootstrap nodes: karpenter.io/bootstrap=true, workload-type=system
✅ Subnet tags applied
```

> **Duration**: ~15–20 minutes. `eksctl` polls internally; the `wait_for_status` call after is a belt-and-suspenders check.

### Common Issues

- `eksctl create cluster` hangs or fails — check CloudFormation events for the `eksctl`-managed stack:
  ```bash
  aws cloudformation describe-stack-events --stack-name "eksctl-${CLUSTER_NAME}-cluster" \
    --region "${AWS_DEFAULT_REGION}" --output table
  ```
- VPC quota exhausted — default limit is 5 VPCs per region; request an increase or delete unused VPCs
- Nodegroup stuck `CREATE_FAILED` — typically insufficient EC2 quota for `${SYSTEM_NODE_TYPE}` on-demand instances
- `cluster.yaml` rendered with blank variables — means `env.variables` was not sourced before calling `envsubst`

### Manual Verification

```bash
# Check cluster status
aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_DEFAULT_REGION}" \
  --query "cluster.status" --output text
# Expected: ACTIVE

# Check node is Ready and labelled
kubectl get nodes --show-labels
# ip-10-0-x-x.eu-north-1.compute.internal  Ready  <none>  ...  karpenter.io/bootstrap=true,...

# Check addons
aws eks list-addons --cluster-name "${CLUSTER_NAME}" --region "${AWS_DEFAULT_REGION}" \
  --output table

# Check kubeconfig
kubectl cluster-info
```

### ✅ Phase 2 Checklist

- [ ] EKS cluster status is `ACTIVE` (`aws eks describe-cluster ...`)
- [ ] Bootstrap node is `Ready` (`kubectl get nodes`)
- [ ] Bootstrap node has label `karpenter.io/bootstrap=true`
- [ ] `kubectl cluster-info` connects successfully

---

## Phase 3: Node IAM Policies

### Goal

Attach the additional inline IAM policies that worker nodes need for EBS autoscale script downloads from S3 and (optionally) EFS mount access. The base `KarpenterNodeRole` created in Phase 1 covers EC2/ECR/EKS join; these policies add the storage-specific permissions.

### What Gets Created

- Inline policy `EBSAutoscaleAndArtifactsPolicy` on `KarpenterNodeRole-${CLUSTER_NAME}` — allows nodes to download autoscale scripts from `${ARTIFACTS_S3_BUCKET}` and call EC2 autoscale APIs
- Inline policy `EFSClientPolicy` on `KarpenterNodeRole-${CLUSTER_NAME}` — allows `elasticfilesystem:ClientMount` / `ClientWrite` / `DescribeMountTargets` (only when `USE_EFS=true`)

### Expected Output

```
============================================
 Phase 3: Node IAM policies
============================================

Rendering EBS autoscale policy...
✅ EBSAutoscaleAndArtifactsPolicy attached
✅ EFSClientPolicy attached
```

### Common Issues

- Policy document render fails — check that `ARTIFACTS_S3_BUCKET` is set in `env.variables`
- `NoSuchEntityException` on `put-role-policy` — the CloudFormation stack (Phase 1) did not complete; the role does not exist yet

### Manual Verification

```bash
# List inline policies on the node role
aws iam list-role-policies \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --output text
# Expected: EBSAutoscaleAndArtifactsPolicy  (+ EFSClientPolicy if USE_EFS=true)
```

### ✅ Phase 3 Checklist

- [ ] `EBSAutoscaleAndArtifactsPolicy` is attached to `KarpenterNodeRole-${CLUSTER_NAME}`
- [ ] `EFSClientPolicy` is attached when `USE_EFS=true`

---

## Phase 4: Karpenter Controller

### Goal

Install the Karpenter controller (Helm, OCI chart from public ECR) onto the bootstrap node, wire its IAM role via IRSA/Pod Identity, and verify it is ready to provision worker nodes.

### What Gets Created

- Karpenter Helm release in namespace `${KARPENTER_NAMESPACE}` — `${KARPENTER_REPLICAS}` replica(s)
- Controller pinned to the bootstrap node via `nodeSelector: ${BOOTSTRAP_LABEL_KEY}=true`
- IRSA annotation on the `karpenter` ServiceAccount → `arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-karpenter`
- Five `KarpenterController*` policies verified as attached to the controller role
- Funnel namespace `${TES_NAMESPACE}` (created early, needed by later phases)

### Expected Output

```
============================================
 Phase 4: Karpenter controller
============================================

Tagging subnets for Karpenter and ALB discovery...
✅ Subnet tags applied
Creating namespace funnel...
Release "karpenter" does not exist. Installing it now.
NAME: karpenter
LAST DEPLOYED: Sun Mar 29 12:00:00 2026
NAMESPACE: kube-system
STATUS: deployed
✅ Karpenter controller installed
✅ Karpenter SA annotation: arn:aws:iam::123456789012:role/TES-karpenter
  ✓ KarpenterControllerInterruptionPolicy-TES attached
  ✓ KarpenterControllerNodeLifecyclePolicy-TES attached
  ✓ KarpenterControllerIAMIntegrationPolicy-TES attached
  ✓ KarpenterControllerEKSIntegrationPolicy-TES attached
  ✓ KarpenterControllerResourceDiscoveryPolicy-TES attached
✅ Karpenter controller verified
```

### Common Issues

- Karpenter pod `CrashLoopBackOff` — IRSA annotation missing or wrong; check `kubectl -n kube-system describe sa karpenter`
- `no subnets found` in Karpenter logs — subnet tags did not propagate; wait 1–2 min and restart the controller: `kubectl -n kube-system rollout restart deployment karpenter`
- Helm pull fails with `401 Unauthorized` — stale public ECR credentials; the installer calls `helm registry logout public.ecr.aws` first, but retry if needed
- Pod stays `Pending` — bootstrap node is not yet Ready or taint/nodeSelector mismatch

### Manual Verification

```bash
# Check Karpenter pod is Running
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
# NAME                        READY   STATUS    RESTARTS   AGE
# karpenter-xxxx-yyyy         1/1     Running   0          2m

# Check IRSA annotation
kubectl -n kube-system get sa karpenter \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
# arn:aws:iam::123456789012:role/TES-karpenter

# Check logs for errors
kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter --since=5m | grep -i error
```

### ✅ Phase 4 Checklist

- [ ] Karpenter pod is `Running` in `${KARPENTER_NAMESPACE}`
- [ ] `karpenter` ServiceAccount has correct IRSA annotation
- [ ] All five controller policies are attached to the role
- [ ] No `error` lines in Karpenter logs

---

## Phase 4.1: Karpenter EC2NodeClass & NodePool

### Goal

Define *how* worker nodes are launched (`EC2NodeClass`) and *what* workloads they accept + how many (`NodePool`). The NodePool's instance-type list is computed at install time from the live EC2 Spot catalog filtered by `env.variables` settings.

### What Happens

This phase:

1. Renders `userdata/workload-node.template.sh` (EBS autoscale setup script for worker nodes)
2. Injects the rendered userdata into `yamls/karpenter-nodeclass.template.yaml` and applies `EC2NodeClass workload`
3. Calls `update-nodepool-types.sh` which:
   - Queries `aws ec2 describe-instance-types --filters "Name=supported-usage-class,Values=spot"`
   - Filters by `WORKER_INSTANCE_FAMILIES`, `WORKER_MIN_GENERATION`, `WORKER_EXCLUDE_TYPES`, vCPU/RAM caps
   - Generates a `NodePool workload` YAML with an explicit `node.kubernetes.io/instance-type` In-values list
   - Sets `limits.cpu = ${SPOT_QUOTA} - 2` (reserves 2 vCPU for the bootstrap node)
   - Applies with `kubectl apply --server-side --force-conflicts`

### What Gets Created

- `EC2NodeClass workload` — AL2023 AMI alias `${ALIAS_VERSION}`, two EBS volumes (20 GiB root + 100 GiB data at `${EBS_IOPS}`/`${EBS_THROUGHPUT}`), subnet and SG discovery via `karpenter.sh/discovery=${CLUSTER_NAME}` tag
- `NodePool workload` — Spot-only, explicit instance-type list, `limits.cpu = SPOT_QUOTA - 2`, `consolidateAfter: 5m`, `expireAfter: 168h`

### Expected Output

```
============================================
 Phase 4.1: Karpenter EC2NodeClass + NodePool
============================================

Rendering workload node userdata...
Rendering EC2NodeClass...
ec2nodeclass.karpenter.k8s.aws/workload configured
✅ EC2NodeClass 'workload' applied
Generating Karpenter NodePool 'workload' with eligible instance types...
  Querying Spot instance types in eu-north-1...
  Filtering: families=[c,m,r] min_gen=3 exclude=[metal] vcpu_cap=0 ram_cap=0 min_mem=4096
  Eligible instance types (42): c3.large, c3.xlarge, c5.large, ...
  NodePool limits.cpu = 98
nodepool.karpenter.sh/workload configured
✅ Karpenter NodePool 'workload' applied
```

### Configuration Details

Instance selection is driven by `env.variables`:

| Variable | Effect |
|---|---|
| `WORKER_INSTANCE_FAMILIES` | First letter(s) of instance type names to include (`c,m,r`) |
| `WORKER_MIN_GENERATION` | Minimum generation integer (`3` → c5, m6i, r7g are in; c2/m2 are out) |
| `WORKER_EXCLUDE_TYPES` | Comma-separated substrings to disqualify (e.g. `metal,nano,micro,small,flex`) |
| `WORKER_MAX_VCPU` | Per-instance vCPU cap; `0` = no cap |
| `WORKER_MAX_RAM_GIB` | Per-instance RAM cap in GiB; `0` = no cap |
| `WORKER_MIN_MEMORY_MIB` | Minimum RAM per instance in MiB (e.g. `4096` removes tiny types) |
| `WORKER_ARCH` | `amd64` / `arm64` / `graviton` / `both` |
| `WORKER_CPU_VENDOR` | `intel` / `amd` / `both` (only applies when `WORKER_ARCH=amd64`) |

> To regenerate the NodePool after changing quota or instance-family settings without re-running the full installer:
> ```bash
> ./update-nodepool-types.sh ./env.variables
> ```

### Manual Verification

```bash
# Check EC2NodeClass
kubectl get ec2nodeclass workload

# Inspect NodePool instance list
kubectl get nodepool workload \
  -o jsonpath='{.spec.template.spec.requirements[?(@.key=="node.kubernetes.io/instance-type")].values}' \
  | python3 -m json.tool

# Check NodePool limits
kubectl get nodepool workload -o jsonpath='{.spec.limits}' | python3 -m json.tool
# { "cpu": "98" }

# Check Karpenter logs for NodePool reconciliation
kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter --since=2m
```

### ✅ Phase 4.1 Checklist

- [ ] `EC2NodeClass workload` exists and shows `Ready`
- [ ] `NodePool workload` exists with a non-empty instance-type list
- [ ] `limits.cpu` matches `SPOT_QUOTA - 2`
- [ ] Karpenter logs show no provisioning errors

---

## Phase 5: EFS Shared Storage

### Goal

Create an encrypted EFS filesystem and mount it on every worker node at `/mnt/efs` so that shared reference data (e.g. genome indices) is available across all tasks without S3 round-trips.

This phase is optional — set `USE_EFS=false` in `env.variables` to skip it entirely.

### What Gets Created

- EFS filesystem `${CLUSTER_NAME}-efs` (encrypted, Standard tier) — tagged `karpenter.sh/discovery=${CLUSTER_NAME}`
- `EFS_ID` written back to `env.variables` (for re-runs and the destroy script)
- EKS addon `aws-efs-csi-driver` scaled to 1 replica on the bootstrap node
- Kubernetes `StorageClass efs-sc`, `PersistentVolume efs-pv`, `PersistentVolumeClaim efs-pvc` in `${TES_NAMESPACE}`
- DaemonSet `efs-node-mount` — mounts EFS on each worker node's host filesystem at `/mnt/efs`
- Security group `efs-mount-sg-${CLUSTER_NAME}` — allows TCP 2049 from the Karpenter node SG and the EKS cluster SG
- EFS mount targets in each private subnet of the VPC

### Expected Output

```
============================================
 Phase 5: EFS shared storage (optional)
============================================

Creating new EFS filesystem in VPC vpc-0abc1234...
✅ EFS filesystem created: fs-0bd10f52a04211916
Installing EFS CSI driver add-on...
  attempt 1/36: addon status=CREATING — waiting 10s...
  ...
✅ EFS CSI Driver add-on ACTIVE
✅ EFS StorageClass, PV, PVC created
✅ efs-node-mount DaemonSet applied
Configuring EFS security groups and mount targets...
✅ EFS mount targets created
```

### Common Issues

- Addon stays `DEGRADED` — restart the `efs-csi-controller` deployment: `kubectl -n kube-system rollout restart deployment efs-csi-controller`
- Mount target creation fails with `subnet already has a mount target` — non-fatal; the installer uses `|| true`; mount target already exists in that AZ
- Worker pods can't reach EFS — the EFS security group did not allow inbound TCP 2049 from the node SG; verify with `aws ec2 describe-security-group-rules`
- EFS PVC stuck `Pending` — EFS CSI driver not running or `StorageClass efs-sc` not created

### Manual Verification

```bash
# Check EFS filesystem
aws efs describe-file-systems --file-system-id "${EFS_ID}" \
  --region "${AWS_DEFAULT_REGION}" \
  --query "FileSystems[0].LifeCycleState" --output text
# Expected: available

# Check mount targets
aws efs describe-mount-targets --file-system-id "${EFS_ID}" \
  --region "${AWS_DEFAULT_REGION}" \
  --query "MountTargets[].{Subnet:SubnetId,State:LifeCycleState}" --output table

# Check PVC
kubectl get pvc efs-pvc -n "${TES_NAMESPACE}"
# NAME       STATUS   VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
# efs-pvc    Bound    efs-pv   150Gi      RWX            efs-sc         2m

# Check efs-node-mount DaemonSet (only shows desired=0 until workers exist)
kubectl get daemonset efs-node-mount -n "${TES_NAMESPACE}"

# Verify /mnt/efs is mounted on an existing node
kubectl debug node/$(kubectl get nodes -o name | head -1 | cut -d/ -f2) \
  -it --image=busybox -- ls /mnt/efs
```

### ✅ Phase 5 Checklist

- [ ] EFS filesystem `EFS_ID` is set in `env.variables`
- [ ] EFS lifecycle state is `available`
- [ ] Mount targets exist in each private subnet
- [ ] `efs-pvc` is `Bound` in namespace `${TES_NAMESPACE}`
- [ ] `efs-node-mount` DaemonSet is deployed

---

## Phase 6: AWS Load Balancer Controller

### Goal

Install the AWS Load Balancer Controller so that the `Ingress tes-ingress` created in Phase 7 provisions an Application Load Balancer (ALB) for the Funnel TES endpoint.

### What Gets Created

- IAM policy `AWSLoadBalancerControllerIAMPolicy` (or reuses existing)
- IRSA ServiceAccount `aws-load-balancer-controller` in `kube-system` with the policy attached
- Helm release `aws-load-balancer-controller` (chart `eks/aws-load-balancer-controller` v3.0.0)
- LB controller CRDs applied from `eks-charts` GitHub

### Expected Output

```
============================================
 Phase 6: AWS Load Balancer Controller
============================================

✅ AWSLoadBalancerControllerIAMPolicy created: arn:aws:iam::123456789012:policy/...
Release "aws-load-balancer-controller" does not exist. Installing it now.
NAME: aws-load-balancer-controller
LAST DEPLOYED: Sun Mar 29 12:15:00 2026
NAMESPACE: kube-system
STATUS: deployed
✅ AWS Load Balancer Controller installed
```

### Common Issues

- Controller pod `CrashLoopBackOff` — IRSA service account missing or wrong policy ARN
- ALB not provisioned after Funnel ingress is applied — check controller logs: `kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller`
- `Failed to resolve security group` — subnets not tagged with `kubernetes.io/cluster/${CLUSTER_NAME}=owned` (applied in Phase 4)
- `invalid VPC ID` — `VPC_ID` was not exported from Phase 2; re-run from Phase 2

### Manual Verification

```bash
# Check controller is Running
kubectl get deployment -n kube-system aws-load-balancer-controller
# NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
# aws-load-balancer-controller   1/1     1            1           3m

# Check IRSA annotation
kubectl -n kube-system get sa aws-load-balancer-controller \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
```

### ✅ Phase 6 Checklist

- [ ] `aws-load-balancer-controller` deployment is `Available`
- [ ] IRSA ServiceAccount annotation points to the correct IAM role
- [ ] No errors in controller logs

---

## Phase 7: Funnel TES Deployment

### Goal

Create the Funnel IAM role (for S3 access via IRSA), provision the TES S3 bucket, and deploy all Funnel Kubernetes resources. After this phase the TES API is reachable via an ALB endpoint.

### What Happens

1. Resolves OIDC provider ID from the EKS cluster (`cut -d'/' -f5` of the OIDC issuer URL)
2. Creates IAM role `${CLUSTER_NAME}-iam-role` with an OIDC-scoped trust policy — allows the `funnel` ServiceAccount in `${TES_NAMESPACE}` to assume it
3. Builds and attaches an inline S3 policy: full access to `${TES_S3_BUCKET}`, read-only to `${READ_BUCKETS}`, read-write to `${WRITE_BUCKETS}`
4. Creates S3 bucket `${TES_S3_BUCKET}` with all public access blocked
5. Renders and applies all Funnel YAML templates: `funnel-namespace`, `funnel-serviceaccount`, `funnel-rbac`, `funnel-crds`, `funnel-deployment`, `funnel-tes-service`, `tes-ingress-alb`, `funnel-configmap`, `ecr-auth-refresh`
6. Waits for all Funnel pods to be Ready (10 min timeout)
7. If `EXTERNAL_IP` is set, calls `setup_external_access.sh` to restrict the ALB security group to that IP

### What Gets Created

- IAM role `${CLUSTER_NAME}-iam-role` with OIDC trust policy
- Inline S3 policy `${CLUSTER_NAME}-tes-policy` on the role
- S3 bucket `${TES_S3_BUCKET}` (private, public access blocked)
- Kubernetes resources in namespace `${TES_NAMESPACE}`:
  - `ServiceAccount funnel` annotated with the IAM role ARN (IRSA)
  - `ClusterRole` + `ClusterRoleBinding` for pod management
  - Funnel CRDs
  - `Deployment funnel` (Funnel server, pinned to bootstrap node)
  - `Service tes-service` (ClusterIP, port `${FUNNEL_PORT}`)
  - `Ingress tes-ingress` (ALB, port 80 → `${FUNNEL_PORT}`)
  - `ConfigMap funnel-config` (nerdctl executor config, EFS mounts if enabled)
  - `CronJob ecr-auth-refresh` (refreshes ECR credentials hourly)

### Expected Output

```
============================================
 Phase 7: TES / Funnel deployment
============================================

OIDC provider ID: ABCD1234567890EFGH
✅ IAM role created: TES-iam-role
✅ S3 permissions attached
✅ S3 bucket created: tes-tasks-123456789012-eu-north-1
Applying funnel-namespace...
Applying funnel-serviceaccount...
Applying funnel-rbac...
Applying funnel-crds...
Applying funnel-deployment...
Applying funnel-tes-service...
Applying tes-ingress-alb...
Applying funnel-configmap...
Applying ecr-auth-refresh...
Waiting for Funnel pods to be Ready (10 min)...
✅ Funnel deployment complete
✅ Installation complete!

Next steps:
  1. Retrieve the TES endpoint:
     kubectl -n funnel get ingress tes-ingress
  2. Configure Cromwell tes.conf to point at the TES endpoint
  3. Submit a test task: funnel task run hello.json
```

### Common Issues

- Funnel pod `Pending` — Karpenter has not provisioned a worker node yet; wait 30–60 s then check `kubectl get nodeclaims`
- `ImagePullBackOff` — ECR image not found in `${ECR_IMAGE_REGION}`; verify `FUNNEL_IMAGE` in `env.variables`
- ALB not created — LB controller not running (Phase 6 incomplete); check ingress events: `kubectl describe ingress tes-ingress -n ${TES_NAMESPACE}`
- IRSA not working (tasks can't write to S3) — OIDC fingerprint mismatch; run `aws iam list-open-id-connect-providers` and verify the OIDC provider ARN exists
- `ConfigMap funnel-config` renders with blank EFS mounts — `USE_EFS=true` but Phase 5 was skipped; re-run Phase 5 first

### Manual Verification

```bash
# Check Funnel pod is Running (on bootstrap node)
kubectl get pods -n "${TES_NAMESPACE}"
# NAME                      READY   STATUS    RESTARTS   AGE
# funnel-xxxxxxxxxx-yyyy    1/1     Running   0          3m

# Get the TES endpoint
kubectl get ingress tes-ingress -n "${TES_NAMESPACE}"
# NAME          CLASS   HOSTS   ADDRESS                                       PORTS   AGE
# tes-ingress   alb     *       k8s-funnel-xxx.eu-north-1.elb.amazonaws.com  80      5m

# Test TES API (replace with actual ALB DNS)
curl http://k8s-funnel-xxx.eu-north-1.elb.amazonaws.com/v1/service-info
# {"id":"funnel","name":"Funnel","type":{"artifact":"tes","type":"tes","version":"1.0.0"},...}

# Check IRSA annotation on Funnel ServiceAccount
kubectl get sa funnel -n "${TES_NAMESPACE}" \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
# arn:aws:iam::123456789012:role/TES-iam-role

# Verify S3 bucket
aws s3 ls "s3://${TES_S3_BUCKET}"
# (empty — no output means accessible and empty)
```

### ✅ Phase 7 Checklist

- [ ] Funnel pod is `Running` in namespace `${TES_NAMESPACE}`
- [ ] `Ingress tes-ingress` has an ALB address
- [ ] `curl http://<ALB_DNS>/v1/service-info` returns Funnel service info JSON
- [ ] `funnel` ServiceAccount has IRSA annotation pointing to `${CLUSTER_NAME}-iam-role`
- [ ] S3 bucket `${TES_S3_BUCKET}` exists and is accessible

---

## 💰 Cost Estimation

### Monthly Costs (Example)

| Component | Cost | Notes |
|-----------|------|-------|
| **EKS Cluster** | ~$72 | Fixed per cluster |
| **System Node (t4g.medium, on-demand)** | ~$29 | Always-on ARM64 |
| **Worker Nodes (Karpenter, Spot)** | ~$100–800 | Highly variable — scales to zero when idle |
| **EFS Storage** | ~$0.30/GB-month | Scales with usage; 0 cost when empty |
| **EBS Volumes** | ~$50–200 | Per-task gp3 volumes; auto-deleted |
| **S3 Storage & Transfer** | ~$50–300 | Depends on workflow data volume |
| **ALB** | ~$20 | Fixed per load balancer |
| **NAT Gateway** | ~$35 | Fixed per AZ for private subnet egress |
| **Total** | **~$360–1500/month** | Idle cluster (no tasks): ~$170/month |

**Cost optimisation tips:**
- Workers scale to zero between workflow runs — the dominant cost is proportional to active compute time
- Use `WORKER_MIN_GENERATION=5` or higher to target newer-generation instances with better price/performance
- Set `WORKER_MAX_VCPU` to avoid accidental selection of very large (expensive) instance types
- Pre-fill `SPOT_QUOTA` below your actual quota to leave headroom for other workloads

---

## Troubleshooting

### EKS Cluster Creation Fails

```bash
# Check eksctl CloudFormation stack events
aws cloudformation describe-stack-events \
  --stack-name "eksctl-${CLUSTER_NAME}-cluster" \
  --region "${AWS_DEFAULT_REGION}" --output table | head -60

# Check Karpenter prerequisites stack
aws cloudformation describe-stacks \
  --stack-name "EKS-${CLUSTER_NAME}" \
  --query "Stacks[0].StackStatus" --output text
```

**Common causes:** insufficient IAM permissions on deploying identity; VPC quota exhausted; `CAPABILITY_NAMED_IAM` not passed.

### Karpenter Not Provisioning Nodes

```bash
# Check NodePool and NodeClaims
kubectl get nodepool workload -o yaml
kubectl get nodeclaims

# Check Karpenter logs for provisioning decisions
kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter --since=5m | grep -E "launched|failed|error"
```

**Common causes:** Spot quota exhausted; `NodePool limits.cpu` already reached; no eligible instance types after filtering; subnet tags missing.

### Funnel Task Fails

```bash
# Check task pod logs
kubectl get pods -n "${TES_NAMESPACE}" --sort-by=.metadata.creationTimestamp
kubectl logs -n "${TES_NAMESPACE}" <task-pod-name>

# Check worker node has EFS mounted (if USE_EFS=true)
kubectl exec -n "${TES_NAMESPACE}" <task-pod-name> -- ls /mnt/efs
```

**Common causes:** EFS not mounted; S3 IRSA not working (check ServiceAccount annotation); container image not found in ECR.

---

## 📚 Related Documentation

- **[AWS CLI Guide](/aws/cli-guide/)** — All CLI commands used by the installer with exact syntax and expected output
- **[AWS Cost & Capacity](/aws/cost-and-capacity/)** — Quota planning and cost breakdown
- **[AWS Troubleshooting](/aws/troubleshooting/)** — Detailed issue resolution
- **[Cromwell Documentation](https://cromwell.readthedocs.io/)** — Workflow orchestration
- **[Funnel Documentation](https://ohsu-comp-bio.github.io/funnel/)** — Task Execution Service

---

**Last Updated**: March 29, 2026
**Status**: Draft — pending production validation on eu-north-1

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
