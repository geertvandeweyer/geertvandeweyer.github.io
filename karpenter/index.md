---
layout: default
title: "Karpenter"
description: "Kubernetes Auto-scaling - Platform-agnostic setup"
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

### [Cloud-Specific Setup](/karpenter/cloud-providers/)
- OVH Provider
- AWS Provider
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
apiVersion: karpenter.sh/v1beta1
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
        name: ovh-workers
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
  limits:
    cpu: 100
    memory: 500Gi
  consolidateAfter: 30s
  expireAfter: 2592000s  # 30 days
```

### Basic OVHNodeClass

```yaml
apiVersion: karpenter.ovhcloud.com/v1beta1
kind: OVHNodeClass
metadata:
  name: ovh-workers
spec:
  region: GRA9
  flavorName: "c3-4"
  imageName: "Kubernetes 1.31.13"
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
