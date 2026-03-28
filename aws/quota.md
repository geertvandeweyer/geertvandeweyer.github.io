---
layout: default
title: "AWS EC2 Quota Management"
description: "Preventing quota-related failures when using Karpenter on AWS EKS (eu-north-1)"
permalink: /aws/quota/
---

# AWS EC2 Quota Management

**How to prevent quota-related Karpenter failures on AWS EKS (eu-north-1 / Stockholm)**

---

## Overview

AWS enforces per-region **Service Quotas** on EC2 instances. Karpenter must stay within these limits or node provisioning fails silently. Unlike OVH (single project quota), AWS maintains **separate quotas per instance-type family** for both On-Demand and Spot instances.

---

## The Problem

```
10 pending pods × 8 vCPU each = 80 vCPU total

Karpenter: "I'll provision c7g.2xlarge nodes (8 vCPU each) to cover the demand"

AWS API: "Your Running On-Demand Standard instances quota is 32 vCPU. 80 > 32. Denied."

Karpenter retries, nodeclaims loop in Pending, tasks never start.
```

### Symptoms

| Symptom | Likely Cause |
|---------|-------------|
| Nodeclaims stuck in `Pending` | On-Demand or Spot vCPU quota exhausted |
| `InsufficientInstanceCapacity` in EC2 events | No capacity in AZ for requested family |
| `NodeCreationError` in Karpenter logs | EC2 API rejected the RunInstances call |
| `MaxSpotInstanceCountExceeded` | Spot instance request quota reached |
| Pods pending > 5 min despite Karpenter scaling events | Instance launch failed after NodeClaim created |

---

## Quota Types

AWS distinguishes four quota categories relevant to this deployment:

| Quota Name | Scope | Default (eu-north-1) | Notes |
|---|---|---|---|
| Running On-Demand Standard (A,C,D,G,I,M,R,T,Z) | vCPU per region | **32 vCPU** | Covers c7g, c6g, m7g, r6g, t4g, etc. |
| Running On-Demand F instances | vCPU per region | 0 | FPGA — not used |
| Running Spot Instance Requests | vCPU per region | **5 vCPU** | Applies to all Spot families combined |
| Amazon EKS clusters | Count per region | 100 | Rarely a bottleneck |

> **Critical:** The default **5 vCPU Spot limit** is nearly useless for genomics workloads. This must be increased before using Spot instances with Karpenter.

---

## Recommended Quotas for Production (eu-north-1)

| Quota | Recommended Minimum | Notes |
|---|---|---|
| On-Demand Standard vCPU | **64–128 vCPU** | Matches Karpenter NodePool `limits.cpu` |
| Spot vCPU | **64–256 vCPU** | Size to peak concurrent task demand |
| EKS clusters | 10 | Default 100 is usually fine |

---

## Instance Families in eu-north-1

### Compute-Optimised (recommended for WES tasks)

| Family | vCPU | RAM | On-Demand (xlarge) | Spot est. | Generation |
|---|---|---|---|---|---|
| `c7g` | 4 / 8 / 16 / 32 | 8 / 16 / 32 / 64 GB | ~$0.073/hr | ~$0.022/hr | Graviton3 ⭐ |
| `c6g` | 4 / 8 / 16 / 32 | 8 / 16 / 32 / 64 GB | ~$0.065/hr | ~$0.020/hr | Graviton2 |
| `c6i` | 4 / 8 / 16 / 32 | 8 / 16 / 32 / 64 GB | ~$0.085/hr | ~$0.026/hr | Intel Ice Lake |
| `c6a` | 4 / 8 / 16 / 32 | 8 / 16 / 32 / 64 GB | ~$0.076/hr | ~$0.023/hr | AMD EPYC |

### General Purpose (when extra RAM needed)

| Family | vCPU | RAM | On-Demand (xlarge) | Spot est. |
|---|---|---|---|---|
| `m7g` | 4 / 8 / 16 / 32 | 16 / 32 / 64 / 128 GB | ~$0.092/hr | ~$0.028/hr |
| `m6g` | 4 / 8 / 16 / 32 | 16 / 32 / 64 / 128 GB | ~$0.083/hr | ~$0.025/hr |
| `m6i` | 4 / 8 / 16 / 32 | 16 / 32 / 64 / 128 GB | ~$0.107/hr | ~$0.032/hr |

> Prices are **eu-north-1 on-demand Linux**, approximate as of March 2026. Spot prices fluctuate. Check the [AWS Spot Price History](https://aws.amazon.com/ec2/spot/instance-advisor/) for current rates.

---

## Three-Layered Karpenter Filtering Strategy

### Layer 1: Instance Family Allowlist (`NodePool`)

Restrict Karpenter to instance families that are quota-approved and appropriate for the workload:

```yaml
# karpenter NodePool — instance type filtering
spec:
  template:
    spec:
      requirements:
        - key: "karpenter.k8s.aws/instance-family"
          operator: In
          values: ["c7g", "c6g", "c6i", "c6a"]    # compute-optimised only
        - key: "karpenter.k8s.aws/instance-size"
          operator: In
          values: ["xlarge", "2xlarge", "4xlarge"]  # 4–16 vCPU per node
        - key: "kubernetes.io/arch"
          operator: In
          values: ["arm64", "amd64"]
```

### Layer 2: Per-Node vCPU Cap (`instance-size`)

Preventing Karpenter from selecting large nodes keeps quota consumption predictable:

```yaml
# Cap nodes at 4xlarge (16 vCPU) maximum
- key: "karpenter.k8s.aws/instance-size"
  operator: In
  values: ["xlarge", "2xlarge", "4xlarge"]
# c7g.8xlarge (32 vCPU) is excluded → stays within 64 vCPU quota with 4 nodes
```

### Layer 3: NodePool Aggregate Limits

```yaml
spec:
  limits:
    cpu: "64"         # Karpenter will not provision beyond 64 total vCPU
    memory: "256Gi"   # Matches typical quota ceiling
```

---

## How to Request Quota Increases

1. Open the [AWS Service Quotas console](https://eu-north-1.console.aws.amazon.com/servicequotas/home/services/ec2/quotas) in **eu-north-1**
2. Search for `Running On-Demand Standard instances`
3. Click **Request quota increase** → enter the desired vCPU count
4. Repeat for `Running Spot Instance Requests`
5. Requests are typically processed within **minutes to a few hours**

> Quota increases in eu-north-1 are subject to AWS regional capacity. If a request is denied, try requesting a smaller increase first or contact AWS support.

---

## Checking Current Quota Usage

```bash
# Check current On-Demand vCPU usage vs quota
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --region eu-north-1

# Check Spot quota
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-34B43A08 \
  --region eu-north-1

# Current running On-Demand instance count
aws ec2 describe-instances \
  --region eu-north-1 \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].[InstanceType,InstanceId]' \
  --output table

# Karpenter NodeClaim status
kubectl get nodeclaims -A
kubectl describe nodeclaim <name>   # shows AWS launch errors
```

---

## Availability Zone Considerations (eu-north-1)

eu-north-1 has **3 AZs**: `eu-north-1a`, `eu-north-1b`, `eu-north-1c`.

Karpenter selects AZs automatically. If `InsufficientInstanceCapacity` occurs in one AZ, Karpenter will retry in another. Configure your NodePool to allow all three:

```yaml
requirements:
  - key: topology.kubernetes.io/zone
    operator: In
    values: ["eu-north-1a", "eu-north-1b", "eu-north-1c"]
```

> Some instance families (e.g. newer Graviton generations) may not be available in all AZs. Check [EC2 Instance Types by Region](https://instances.vantage.sh/?region=eu-north-1) before committing to a family.
