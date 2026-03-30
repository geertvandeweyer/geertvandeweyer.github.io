---
layout: default
title: "Karpenter Autoscaling — AWS EKS & OVHcloud MKS"
description: "Platform-agnostic guide to Karpenter node autoscaling on AWS EKS and OVHcloud MKS. Covers NodePool configuration, Spot instances, instance-type filtering, and quota management."
keywords:
  - Karpenter
  - Kubernetes autoscaling
  - AWS EKS Karpenter
  - OVHcloud Karpenter
  - Spot instances
  - NodePool
  - EC2NodeClass
permalink: /karpenter/
---

# Karpenter Auto-scaling

**Platform-agnostic guide to Karpenter deployment and configuration**

Karpenter is an **open-source Kubernetes autoscaler** that provisions compute resources on-demand, enabling automatic scaling of worker nodes based on pod resource requirements.

---

## 📖 Documentation

### [Configuration](/karpenter/configuration/)
- NodePool configuration
- Compute templates
- Scaling policies
- Resource limits

### [OVH Quota Management](/karpenter/ovh-quota/) ⭐ **New**
- Preventing 412 InsufficientVCPUsQuota errors
- Flavor filtering strategy
- Quota-aware configuration
- Troubleshooting quota issues

### [Cloud-Specific Setup](/karpenter/cloud-providers/)
- **[OVH Provider](/karpenter/cloud-providers/ovh/)** — OVH MKS configuration, flavor selection, quota management
- **[AWS Provider](/karpenter/cloud-providers/aws/)** — AWS EKS configuration, Spot instances, instance families
- GCP Provider (coming soon)

### [Troubleshooting](/karpenter/troubleshooting/)
- Nodes not scaling
- Pod pending issues
- Cost analysis
- Performance tuning

---

## 🚀 Quick Start

### Check Karpenter Installation

```bash
# Check Karpenter controller
kubectl get deployment -n karpenter
kubectl logs -n karpenter deployment/karpenter -f

# Check NodePools
kubectl get nodepools
kubectl describe nodepools workers
```

### Scale Workers Manually

```bash
# View current NodePool
kubectl get nodepools -o wide

# Scale to specific count (Karpenter will adjust)
kubectl scale nodepools workers --replicas=3

# Update resource limits
kubectl patch nodepools workers --type merge \
  -p '{"spec":{"limits":{"resources":{"cpu":"100"}}}}'
```

---

## 🏗️ Architecture Overview

```
Karpenter Controller (namespace: karpenter)
├─ Webhook (validates NodePool specs)
├─ Controller (reconciles desired state)
└─ Provider Plugin (talks to cloud API)

NodePool Configuration
├─ Compute templates (machine types)
├─ Consolidation policy (remove idle nodes)
├─ Expiration policy (reclaim old nodes)
└─ Resource limits (cost control)

Cloud Provider
├─ OVH: Creates Cinder VMs in MKS
├─ AWS: Creates EC2 instances in EKS
└─ GCP: Creates GCE instances in GKE
```

---

## 🔧 Configuration

### Basic NodePool (OVH)

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: workers
spec:
  template:
    metadata:
      labels:
        workload-type: task
    spec:
      nodeClassRef:
        group: karpenter.ovhcloud.sh
        kind: OVHNodeClass
        name: default
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["c3-4", "c3-8", "c3-16", "c3-32"]  # Restrict to right-sized compute
  limits:
    cpu: "32"       # Set to OVH quota minus overhead
    memory: "426Gi"
  consolidateAfter: 5m
  expireAfter: 2592000s  # 30 days
```

**Key difference for OVH**: Instance-type filtering is **critical** to prevent 412 quota errors (see [Quota Management](#quota-management-on-ovh) below).

---

## 🎯 Quota Management on OVH

### The Problem

OVH Karpenter bin-packs all pending pods onto as few nodes as possible. Without instance-type filtering, Karpenter selects the **largest available flavor** (e.g., `a10-90` with 90 vCPU GPU), which:
1. **Exceeds your OVH quota** (typically 34–100 vCPU for projects)
2. **Causes 412 InsufficientVCPUsQuota errors**
3. **Locks Karpenter in retry loop**

### The Solution

**Three-layered filtering**:

| Layer | Mechanism | Example |
|-------|-----------|---------|
| **1. Family restriction** | `WORKER_FAMILIES` env var | `c3` only (exclude GPU/HPC/memory families) |
| **2. Per-flavor caps** | `WORKER_MAX_VCPU`, `WORKER_MAX_RAM_GB` | Max 16 vCPU, 32 GB per node |
| **3. NodePool limits** | `limits.cpu`, `limits.memory` | Total cluster cap: 32 vCPU, 426 Gi |

**How they work together**:

```
Pending pods arrive
  ↓
Karpenter evaluates NodePool.requirements (instance-type: [c3-4, c3-8, c3-16, c3-32])
  ↓
Karpenter filters to feasible options (all are ≤16vCPU, ≤32GB)
  ↓
Karpenter selects smallest fitting flavor (bin-packing)
  ↓
Check NodePool limits: remaining CPU >= requested?
  ↓
Create node pool + node on OVH
```

### Configuration

**env.variables**:

```bash
# Cloud-specific quotas (get these from OVH Manager → Quotas)
OVH_VCPU_QUOTA="34"          # Total vCPU quota for project
OVH_RAM_QUOTA_GB="430"       # Total RAM quota for project

# Filtering to prevent oversized selections
WORKER_FAMILIES="c3"         # Compute family only
WORKER_MAX_VCPU="16"         # Never select nodes larger than this
WORKER_MAX_RAM_GB="32"       # Never select nodes with more RAM

# NodePool limits (derived from quota - system overhead)
# Computed automatically: limit_cpu = quota - 2 (for system node)
# Computed automatically: limit_mem = quota_gb - 4
```

### Updating Quota Limits

If your OVH quota changes, update the NodePool **without redeploying Karpenter**:

```bash
# 1. Edit env.variables with new quota
vim ./OVH_installer/installer/env.variables
# OVH_VCPU_QUOTA="100"  # Changed!

# 2. Run update script
./OVH_installer/installer/update-nodepool-flavors.sh ./OVH_installer/installer/env.variables

# 3. Verify
kubectl get nodepool workers -o yaml | grep -A2 limits
# limits:
#   cpu: "98"        # 100 - 2 for system
#   memory: "426Gi"  # unchanged (if OVH_RAM_QUOTA_GB stayed same)

# 4. Karpenter reconciles within ~30s
kubectl get nodeclaim -w
```

### Example: Quota-Aware Node Selection

**Scenario**: 34 vCPU quota, current NodePool limit: 32 vCPU

```
Pending: 8 × task pods, each requiring 4 vCPU, 4 GB RAM

NodePool limit: 32 vCPU remaining
Karpenter evaluates:
  - c3-4 (2 vCPU, 8 GB) → fits 16 pods, but limit is only 32 vCPU → max 8 nodes → FITS
  - c3-8 (4 vCPU, 16 GB) → fits 8 pods, limit is 32 vCPU → max 8 nodes → FITS
  - c3-16 (8 vCPU, 32 GB) → fits 4 pods, limit is 32 vCPU → max 4 nodes → NOT ENOUGH
  
Karpenter selects: 2 × c3-8 nodes
  (8 pods fit, 2 × 4 vCPU = 8 vCPU used, limit still has 24 vCPU free)
```

### Basic OVHNodeClass

```yaml
apiVersion: karpenter.ovhcloud.sh/v1alpha1
kind: OVHNodeClass
metadata:
  name: default
spec:
  region: GRA9
  serviceName: <project-id>
  kubeId: <kube-id>
  credentialsSecretRef:
    name: ovh-credentials
    namespace: karpenter
```

See [Configuration](/karpenter/configuration/) for advanced options.

---

## 📊 Component Status

| Component | Status | Purpose |
|-----------|--------|---------|
| **Karpenter Controller** | ✅ Running | Manages NodePool state |
| **Webhook** | ✅ Running | Validates configurations |
| **Cloud Provider** | ✅ Connected | Provisions nodes |
| **Consolidation** | ✅ Enabled | Removes idle nodes |

---

## 🔗 Related Sections

- **[OVH Provider](/karpenter/cloud-providers/#ovh)** — OVH-specific configuration
- **[AWS Provider](/karpenter/cloud-providers/#aws)** — AWS-specific configuration
- **[Funnel TES](/tes/)** — What creates task pods for Karpenter to scale
- **[OVH Deployment](/ovh/)** — Full OVH setup with Karpenter

---

## 📚 Detailed Guides

1. **[Configuration](/karpenter/configuration/)** — NodePool tuning
2. **[Cloud Providers](/karpenter/cloud-providers/)** — Cloud-specific setup
3. **[Troubleshooting](/karpenter/troubleshooting/)** — Debug scaling issues

---

## 🆘 Quick Troubleshooting

**Nodes not scaling up?**
```bash
# Check controller logs
kubectl logs -n karpenter deployment/karpenter | grep -i scale

# Check NodePool
kubectl get nodepools -o yaml

# Check pods pending
kubectl get pods -A --field-selector=status.phase=Pending
```

**Nodes not scaling down?**
```bash
# Check consolidation settings
kubectl get nodepools -o jsonpath='{.items[*].spec.consolidateAfter}'

# Manual consolidation trigger
kubectl delete nodes --all-namespaces --all
```

---

## ⚙️ Optional Feature

Karpenter is **optional** for this platform:

- **With Karpenter**: Automatic scaling based on pod demand
- **Without Karpenter**: Manual node scaling via `kubectl scale`
- **With KEDA**: CRON-based or custom metric scaling

Choose based on your workflow patterns:
- **Bursty workloads**: Use Karpenter
- **Steady-state**: Manual scaling is simpler
- **Scheduled**: KEDA with CRONs

---

**Last Updated**: March 13, 2026  
**Version**: 2.0 (Platform-agnostic)
