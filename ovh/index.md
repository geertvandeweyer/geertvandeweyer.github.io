---
layout: default
title: "OVHcloud Deployment"
description: "Complete guide to deploying Cromwell + TES on OVHcloud MKS"
permalink: /ovh/
---

# OVHcloud Deployment

**Complete, production-tested guide to deploying Cromwell + Funnel TES on OVHcloud**

Deploy a complete genomic workflow platform on **OVHcloud MKS** with managed Kubernetes, Manila NFS storage, S3 object storage, and Karpenter auto-scaling.

---


## 🏗️ OVH Architecture at a glance

```
OVHcloud (GRA9 Region)
┌──────────────────────────────────────────────────┐
│ Neutron Networking                               │
│ ├─ Public Network (external internet)            │
│ └─ Private vRack (192.168.100.0/24)              │
│    ├─ MKS Cluster nodes                          │
│    ├─ Manila NFS share                           │
│    └─ Inter-pod communication                    │
└──────────────────────────────────────────────────┘
         │
         ├─ MKS Cluster (Kubernetes 1.31.13)
         │  ├─ System Node (d2-4, always-on)
         │  │  ├─ Karpenter Provider
         │  │  └─ Funnel Server
         │  └─ Worker Nodes (Karpenter-managed)
         │     ├─ Funnel Disk Setup (DaemonSet)
         │     └─ Task Pods (on demand)
         │
         ├─ Manila NFS (150 GB)
         │  └─ Mounted on host, shared to all nodes
         │
         ├─ Cinder Volumes (per task)
         │  └─ Auto-expanded, LUKS encrypted
         │
         └─ S3 Object Storage (GRA9)
            └─ Task I/O, workflow inputs/outputs
```

**Key Technologies**

| Technology | Role | Details |
|-----------|------|---------|
| **MKS** | Kubernetes cluster | Managed service, Free or Standard^1^ |
| **Karpenter OVH** | Auto-scaling | Scales workers on demand |
| **Manila NFS** | Shared storage | 150 GB, highly available |
| **Cinder** | Task local storage | 100-500 GB volumes, auto-expanded |
| **S3** | Object storage | Workflow I/O, persistent storage |
| **LUKS** | Encryption | Keys managed by Barbican |

^1^_: Free cluster has max 100 nodes and 1 AZ, Standardard is approximately 70€/month for max 500 nodes and 3AZ_


## 📖 Documentation

### [Installation Guide](/ovh/installation-guide/)
- 7-phase deployment walkthrough
- Step-by-step instructions with verification
- Network setup (vRack, private subnets)
- Storage configuration (Manila NFS, Cinder volumes)
- Time estimate: **~65 minutes**

### [Karpenter OVH Quota Guide](/karpenter/ovh-quota/) ⭐ **Critical for Production**
- How to prevent 412 InsufficientVCPUsQuota errors
- Instance-type filtering strategy
- Quota-aware NodePool configuration
- Per-flavor vCPU/RAM caps

### [OVH CLI Guide](/ovh/cli-guide/)
- OpenStack CLI commands
- OVHcloud API tool usage
- Network management
- Security group configuration
- Storage operations

### [Cost & Infrastructure](/ovh/cost-and-infrastructure/)
- Monthly cost breakdown
- Quota requirements
- Flavor recommendations
- Scaling limits & optimization

### [Troubleshooting](/ovh/troubleshooting/)
- OVH-specific issues
- Network connectivity problems
- NFS mount failures
- LUKS encryption issues

---
<!-->
## 🚀 Quick Start

### Prerequisites

```bash
# OVHcloud account with API credentials
export OVH_REGION="GRA9"
export OVH_APPLICATION_KEY="<your-key>"
export OVH_APPLICATION_SECRET="<your-secret>"
export OVH_CONSUMER_KEY="<your-consumer-key>"

# Tools installed
which openstack           # OpenStack CLI
which aws                 # AWS CLI (for S3)
which kubectl             # Kubernetes CLI
which helm                # Helm (optional, for Karpenter)
```

### 7-Phase Deployment

```bash
# Phase 0: Environment (5 min)
# Phase 1: Create MKS cluster (15 min)
# Phase 2: Configure node pools (10 min)
# Phase 3: Set up Manila NFS (10 min)
# Phase 4: Create S3 bucket (5 min)
# Phase 5: Deploy Funnel (10 min)
# Phase 6: Deploy Cromwell (5 min)
# Phase 7: Run tests (5 min)
```

**Total**: ~65 minutes for a complete deployment

**→ Start**: [Installation Guide](/ovh/installation-guide/)


---

## 📊 Infrastructure Details

### Cluster Specification

| Component | Value |
|-----------|-------|
| **Region** | GRA9 (Gravelines, France) |
| **Kubernetes Version** | 1.31.13 |
| **System Node** | d2-4 (1 shared vCPU, 4GB RAM, always-on) |
| **Worker Nodes** | c3-4, c3-8, r3-8 (auto-scaled, 0 at rest) |
| **Network** | Private vRack (192.168.100.0/24) |
| **Storage** | Manila NFS (150 GB) + Cinder volumes |

### Estimated Monthly Cost

```
System Node (d2-4):     ~€0.30/day   (€9/month)
Workers (auto-scale):   ~€0.10-0.50/day (usage-based)
Manila NFS (150GB):     ~€7.50/month
S3 Storage (100GB):     ~€2.50/month
━━━━━━━━━━━━━━━━━━━━━━
Total:                  ~€20-40/month (depending on usage)
```

---

## 🔗 Platform-Agnostic Sections

Reference these guides for detailed component information:

- **[Funnel TES](/tes/)** — Task execution (OVH-independent)
- **[Cromwell](/cromwell/)** — Workflow orchestration (OVH-independent)
- **[Karpenter](/karpenter/)** — Auto-scaling (OVH-independent)
- **[Karpenter OVH Provider](/karpenter/cloud-providers/#ovh)** — OVH-specific scaling

---
-->

## 📚 Installation overview


**[Phase 0: Environment Setup](/ovh/installation-guide/#phase-0)** (5 min)
- OVH account verification
- API credentials
- Local tool installation

**[Phase 1: Create MKS Cluster](/ovh/installation-guide/#phase-1)** (15 min)
- Networking setup (vRack)
- Cluster creation
- KUBECONFIG configuration

**[Phase 2: Node Pools & Karpenter](/ovh/installation-guide/#phase-2)** (10 min)
- System node creation
- Worker node pool setup
- Karpenter installation & configuration

**[Phase 3: Manila NFS Storage](/ovh/installation-guide/#phase-3)** (10 min)
- NFS share creation
- Access grant configuration
- DaemonSet mount setup

**[Phase 4: S3 Object Storage](/ovh/installation-guide/#phase-4)** (5 min)
- S3 bucket creation
- Service account credentials
- AWS CLI configuration

**[Phase 5: Deploy Funnel TES](/ovh/installation-guide/#phase-5)** (10 min)
- ConfigMap rendering
- Deployment creation
- Service verification

**[Phase 6: Deploy Cromwell](/ovh/installation-guide/#phase-6)** (5 min)
- Configuration setup
- Deployment creation
- Cromwell verification

**[Phase 7: Smoke Tests](/ovh/installation-guide/#phase-7)** (5 min)
- Test workflow submission
- Task execution verification
- Output validation

---

## 🆘 Troubleshooting

### Common Issues

**NFS mount failing?**
→ See [NFS Troubleshooting](/ovh/troubleshooting/#nfs-issues)

**Nodes not scaling?**
→ See [Karpenter Issues](/ovh/troubleshooting/#karpenter-scaling)

**S3 access denied?**
→ See [S3 Access Issues](/ovh/troubleshooting/#s3-access)

**LUKS key management?**
→ See [LUKS Encryption](/ovh/troubleshooting/#luks-encryption)

---


## ✅ Production Checklist

- [x] Installation verified (tested March 13, 2026)
- [x] NFS mount propagation working (DaemonSet pattern)
- [x] Karpenter auto-scaling working
- [x] LUKS encryption enabled
- [x] S3 access configured
- [x] Cromwell-Funnel integration tested
- [x] Workflow execution verified
- [x] Cost monitoring setup

---

**Status**: ✅ **Production-Ready**  
**Last Updated**: March 13, 2026  
**Version**: 2.0 (Multi-platform)  
**Tested On**: OVHcloud MKS 1.31.13, GRA9 region
