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


## OVH Architecture at a glance

```
OVHcloud (GRA9 Region, 1AZ)
┌──────────────────────────────────────────────────┐
│ Neutron Networking                               │
│ ├─ Public Network (external internet)            │
│ └─ Private vRack (192.168.100.0/24)              │
│    ├─ MKS Cluster nodes                          │
│    ├─ Manila NFS share                           │
│    └─ Inter-pod communication                    │
└──────────────────────────────────────────────────┘
         │
         ├─ MKS Cluster (Kubernetes 1.34)
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
| **MKS** | Kubernetes cluster | Managed service, Free or Standard* |
| **Karpenter OVH** | Auto-scaling | Scales workers on demand |
| **Manila NFS** | Shared storage | 150 GB, highly available |
| **Cinder** | Task local storage | 50+ GB volumes, auto-expanded |
| **S3** | Object storage | Workflow I/O, persistent storage |
| **LUKS** | Encryption | Keys managed by Barbican |

* :_Free cluster has max 100 nodes and 1 AZ, Standardard is approximately 70€/month for max 500 nodes and 3AZ_


## Documentation

### [Installation Guide](/ovh/installation-guide/)
- 8-phase deployment walkthrough
- Step-by-step instructions with verification
- Network setup (vRack, private subnets)
- Storage configuration (Manila NFS, Cinder volumes)
- Time estimate: **~65 minutes**

### [Karpenter OVH Quota Guide](/ovh/ovh-quota/) ⭐ **Critical for Production**
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

### [Installer Files](/ovh/installer-files/)
- Complete bundle download
- Individual script and template reference
- YAML manifest descriptions
- Funnel TES example tasks


---


## Production Checklist

- [x] Installation verified (tested March 23, 2026)
- [x] NFS mount propagation working (DaemonSet pattern)
- [x] Karpenter auto-scaling working
- [x] LUKS encryption enabled
- [x] S3 access configured
- [x] Cromwell-Funnel integration tested
- [x] Workflow execution verified
- [x] Cost benchmarking runs

---

**Status**: ✅ **Production-Ready**  
**Last Updated**: March 28, 2026  
**Version**: 1.0 (OVH ready)  
**Tested On**: OVHcloud MKS 1.34, GRA9 region
