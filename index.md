---
layout: default
title: "Cromwell + TES on Kubernetes"
description: "Platform-agnostic guide to deploying Cromwell and Task Execution Service on any cloud Kubernetes cluster"
permalink: /
extra_css:
  - /assets/css/custom.css
---

# Cromwell + TES on Kubernetes

**A comprehensive platform for genomic workflow orchestration on any^*^ cloud**

> Deploy Cromwell (workflow engine) + Funnel TES (task execution) on OVH, AWS, or other managed Kubernetes service based on this, partially cloud agnostic, documentation.


^*^_: This might be a bit optimistic. The documentation was written based on work on both AWS EKS and OVHcloud MKS._
---

## 🎯 Project Goal

Run **high-throughput genomic workflows** (WDL/CWL) with:

- **Cromwell**: Workflow language execution engine (WDL, CWL) — can run on-prem or in-cloud
- **Funnel TES**: Task Execution Service (GA4GH standard) — runs in Kubernetes cluster
- **Kubernetes**: Any managed or self-hosted cluster (OVH, AWS, GCP, etc.)
- **Cloud Storage**: S3, NFS, EFS, or other cloud-native options
- **Auto-scaling**: Karpenter-managed worker pools

### Architecture

```
┌──────────────────────────┐
│  Cromwell Workflow       │  (on-prem, cloud, or local)
│  Engine                  │  (submits tasks to TES)
└────────────┬─────────────┘
             │ WDL/CWL tasks
             ↓
    ┌────────────────────────────────┐
    │  Kubernetes Cluster            │  (OVH, AWS, GCP, etc.)
    │  ┌──────────────────────────┐  │
    │  │ Funnel TES               │  │
    │  │ (task executor)          │  │
    │  └──────────────────────────┘  │
    │  ┌──────────────────────────┐  │
    │  │ Task Pods (workers)      │  │
    │  │ (auto-scaled (karpenter))│  │
    │  └──────────────────────────┘  │
    │  ┌──────────────────────────┐  │
    │  │ Storage                  │  │
    │  │ (S3/NFS/EFS/...)         │  │
    │  └──────────────────────────┘  │
    └────────────────────────────────┘
             │
             ↓
    ┌────────────────────┐
    │ Results/Outputs    │
    │ (Cloud Storage)    │
    └────────────────────┘
```

**1. Cloud-Agnostic Core**

- **TES, Cromwell, Karpenter** work on any Kubernetes
- Documentation tries to separate platform-agnostic from platform-specific

**2. Modular Components**

- Swap storage (NFS ↔ S3 ↔ EFS)
- Swap compute (OVH ↔ AWS (↔ GCP) )
- Swap autoscaling (Karpenter ↔ Cloud-Managed)

**3. Storage Strategy (DaemonSet Pattern)**

```
DaemonSet (on every node)
  ├─ Mounts shared storage (NFS/EFS/S3)
  └─ Keeps connection alive to prevent timeouts on node re-usage during consecutive tasks

Task Pods
  ├─ Wait for mount to be ready
  ├─ Consume via hostPath + propagation
  └─ No unmounting on exit (DaemonSet owns lifecycle)
```

**4. Auto-scaling (Karpenter)**

Karpenter can be configured to select nodes from a preselected list of instance types

```
Monitor pod queue → Insufficient resources → Scale up nodes
                    Pods completed → Idle timeout → Scale down
```

**5. Cost Optimization**

This deployment was built with routine genomics pipelines in mind. In this setting, data comes in spikes (sequencing machines finish), and are time critical. Therefore, we aimed for: 

- Nodes scaling to (near) zero when idle
- Use spot instances with robust retries where available
- Prevent localization of static data where possible (reference data)
- Provide access to wide ranges of instance types

---

## 📖 How to Use This Documentation

The documentation is organized as two main deployment examples : OVHcloud and AWS.  Next there are a couple of pages describing setups in more detail. 

### I want to deploy on OVHcloud

**Start here**: [OVHcloud Installation Guide](/ovh/installation-guide/)

Then reference:
- [TES Architecture](/tes/) — Understand the task execution layer
- [Cromwell Configuration](/cromwell/) — Set up workflow engine
- [Karpenter Configuration](/karpenter/) — Auto-scaling (optional)

### I want to deploy on AWS

**Start here**: [AWS Installation Guide](/aws/installation-guide/)

Then reference:
- [TES Architecture](/tes/) — Understand the task execution layer
- [Cromwell Configuration](/cromwell/) — Set up workflow engine
- [Karpenter Configuration](/karpenter/) — Auto-scaling (optional)


### The Task Execution Layer : TES (Funnel)

**Start here**: [Funnel TES Overview](/tes/)

Then dive into:
- [Architecture](/tes/architecture/) — Design & patterns
- [Container Images](/tes/container-images/) — Custom builds
- [Configuration](/tes/configuration/) — Runtime options
- [Troubleshooting](/tes/troubleshooting/) — Common issues

### The Workflow Execution Layer : Cromwell

**Start here**: [Cromwell Overview](/cromwell/)

Then dive into:
- [Configuration](/cromwell/configuration/) — Backends & runtime settings
- [Workflows](/cromwell/workflows/) — Submitting & monitoring
- [Troubleshooting](/cromwell/troubleshooting/) — Common issues

### The Cluster Autoscaling Layer : Karpenter

**Start here**: [Karpenter Overview](/karpenter/)

Then dive into: 
- [NodePools]()
- [Alternatives]()



### I need quick command references

**See**: [Quick Reference](/quick-reference/)

kubectl, openstack, aws CLI commands, common tasks, troubleshooting.


---

## 📊 Status & Maintenance

| Component | Status | Tested | Maintained |
|-----------|--------|--------|------------|
| **OVHcloud Deployment** | ✅ Production | OVH MKS 1.31.13 | Yes |
| **AWS Deployment** | 📋 Template | Not yet | Coming |
| **Funnel TES** | ✅ Functional | Yes | Yes |
| **Cromwell** | ✅ Functional | Yes | Yes |
| **Karpenter OVH** | ✅ Functional | Yes | Yes |
| **Karpenter AWS** | 📋 Template | Not yet | Coming |

---

## 🔐 Security Considerations

- **Encryption**: LUKS on persistent volumes (OVH), EBS encryption (AWS)
- **Networking**: Private subnets, security groups configured
- **Access Control**: RBAC configured per component
- **Credentials**: Environment variables, no hardcoding

See platform-specific guides for detailed security setup.


---

## Support & Contributions

- **Issues**: Document in GitHub Issues with `[TES]`, `[Cromwell]`, `[OVH]`, or `[AWS]` prefix
- **Updates**: Submit PRs with documentation improvements
- **Questions**: Check relevant section or file an issue
- **Contact** : geert.vandeweyer@uza.be

---

## 📋 Helpful Resources

- [Cromwell Documentation](https://cromwell.readthedocs.io/)
- [Funnel TES Documentation](https://ohsu-comp-bio.github.io/funnel/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Karpenter Documentation](https://karpenter.sh/)
- [GA4GH TES Specification](https://ga4gh.github.io/task-execution-schemas/)

---



### Installation Timeline

```
Choose Platform (2 min)
  ↓
Create Kubernetes Cluster (15-20 min)
  ↓
Configure Storage (10-15 min)
  ↓
Deploy Funnel TES (10 min)
  ↓
Deploy Cromwell (5 min)
  ↓
Run Smoke Tests (5-10 min)
  ↓
✅ Ready for production workflows!
```



---


**Last Updated**: March 13, 2026  
**Version**: 2.0 (Multi-platform)  
**Status**: ✅ Platform-agnostic core complete, OVH production-ready, AWS template available


