---
layout: default
title: "AWS Installation Guide"
description: "Complete guide to deploying Cromwell + TES on AWS EKS with Karpenter"
permalink: /aws/installation-guide/
---

# AWS EKS + Cromwell + Funnel TES Installation Guide

**Complete, production-ready guide to deploying a genomic workflow platform on AWS**

Deploy a scalable workflow execution environment on **AWS EKS** with managed Kubernetes, EFS storage, S3 object storage, and Karpenter auto-scaling.

---

## 📋 Table of Contents

1. [Overview & Architecture](#overview--architecture)
2. [Prerequisites](#prerequisites)
3. [Phase 0: Environment Setup](#phase-0-environment-setup)
4. [Phase 1: EKS Cluster Creation](#phase-1-eks-cluster-creation)
5. [Phase 2: Karpenter Auto-scaling](#phase-2-karpenter-auto-scaling)
6. [Phase 3: EFS Shared Storage](#phase-3-efs-shared-storage)
7. [Phase 4: S3 Object Storage](#phase-4-s3-object-storage)
8. [Phase 5: Deploy Funnel TES](#phase-5-deploy-funnel-tes)
9. [Phase 6: Configure Cromwell](#phase-6-configure-cromwell)
10. [Phase 7: Verification & Testing](#phase-7-verification--testing)
11. [Troubleshooting](#troubleshooting)

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

## Prerequisites

### AWS Account & Credentials

1. **AWS Account** with appropriate permissions
2. **IAM User** with programmatic access (Access Key + Secret Key)
3. **AWS CLI** configured: `aws configure`
4. **Verification**:
   ```bash
   aws sts get-caller-identity
   # Should return: { "Account": "123456789012", "UserId": "...", "Arn": "arn:aws:iam::..." }
   ```

### Local Tools

```bash
# AWS CLI (https://aws.amazon.com/cli/)
aws --version

# eksctl (https://eksctl.io/)
eksctl version

# kubectl (https://kubernetes.io/docs/tasks/tools/)
kubectl version --client

# Helm (https://helm.sh/)
helm version

# Karpenter CLI (optional, for advanced management)
karpenter version
```

### AWS Resource Quotas

Check your account limits in **AWS Console → Service Quotas → EC2**:

| Quota | Required | Command |
|-------|----------|---------|
| **vCPU (On-Demand)** | 64+ | `aws service-quotas list-service-quotas --service-code ec2 --query "Quotas[?QuotaName=='On-Demand ... Instances']"` |
| **Spot Instances** | 100+ | `aws service-quotas list-service-quotas --service-code ec2 --query "Quotas[?contains(QuotaName, 'Spot')]"` |
| **EBS Volumes** | 200+ | `aws service-quotas list-service-quotas --service-code ebs --query "Quotas[?QuotaName=='General Purpose SSD Volumes']"` |
| **EBS Snapshot Storage** | 500 GB+ | Related to EBS quota |

Request quota increases if needed (typically 2–4 hours).

### Disk Space

```bash
# Installer downloads ~500 MB (Karpenter, Funnel, Cromwell)
# EFS allocates 150 GB initially (expandable)
# Local workspace: ~2 GB for git repos + configs
```

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

The installer deploys Karpenter via **Helm**:

```bash
# Automatic (part of install script)
./install-eks-karpenter.sh

# Or manual:
helm repo add karpenter https://charts.karpenter.sh
helm install karpenter karpenter/karpenter --namespace karpenter --create-namespace \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn=arn:aws:iam::ACCOUNT_ID:role/karpenter-controller"
```

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
