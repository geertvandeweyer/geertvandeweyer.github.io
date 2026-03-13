---
layout: default
title: "Cromwell + TES on Kubernetes"
description: "Platform-agnostic guide to deploying Cromwell and Task Execution Service on any cloud Kubernetes cluster"
permalink: /
---

# Cromwell + TES on Kubernetes

**A comprehensive platform for genomic workflow orchestration on any cloud**

> Deploy Cromwell (workflow engine) + Funnel TES (task execution) on OVH, AWS, or any managed Kubernetes service with this modular, cloud-agnostic documentation.

---

## 🎯 Project Goal

Run **high-throughput genomic workflows** (WDL/CWL) with:

- **Cromwell**: Workflow language execution engine (WDL, CWL)
- **Funnel TES**: Task Execution Service (GA4GH standard)
- **Kubernetes**: Any managed or self-hosted cluster
- **Cloud Storage**: S3, NFS, or cloud-native options
- **Auto-scaling**: Karpenter-managed worker pools

```
┌─────────────────┐
│ User Workflows  │ (WDL/CWL files)
│ (Cromwell)      │
└────────┬────────┘
         │
         ↓
    ┌─────────────────────────────┐
    │  Kubernetes Cluster         │ ← Any cloud (OVH, AWS, GCP, etc.)
    │  ┌─────────────────────────┐│
    │  │ Cromwell  (orchestrator) ││
    │  │ Funnel TES (task exec)   ││
    │  │ Karpenter (autoscaler)   ││
    │  └─────────────────────────┘│
    │  ┌─────────────────────────┐│
    │  │ Task Pods (worker nodes) ││
    │  │ (auto-scaled on demand)  ││
    │  └─────────────────────────┘│
    │  ┌─────────────────────────┐│
    │  │ Storage (S3/NFS/etc.)    ││
    │  └─────────────────────────┘│
    └─────────────────────────────┘
         │
         ↓
    ┌─────────────────┐
    │ Results/Outputs │
    │ (Cloud Storage) │
    └─────────────────┘
```

---

## 📚 Documentation Structure

### Platform-Agnostic (Cloud-independent)

**Learn the core components that work on any Kubernetes:**

- **[TES (Funnel)](/tes/)** — Task Execution Service
  - Architecture & design patterns
  - Container images & builds
  - Configuration & troubleshooting
  - NFS mount strategies

- **[Cromwell](/cromwell/)** — Workflow Orchestration Engine
  - Configuration & backends
  - Workflow submission & monitoring
  - Integration with TES
  - Troubleshooting

- **[Karpenter](/karpenter/)** — Kubernetes Auto-scaling (Optional)
  - Architecture & NodePools
  - Configuration for cloud providers
  - Troubleshooting scaling issues

### Platform-Specific (Cloud-specific implementations)

**Deploy to your chosen cloud:**

- **[OVHcloud](/ovh/)** — OVH MKS + Manila NFS + S3
  - 7-phase installation guide
  - OVH CLI commands & tools
  - Cost & capacity planning
  - Troubleshooting for OVH specifics

- **[Amazon AWS](/aws/)** — EKS + EFS + S3
  - Installation guide (coming soon)
  - AWS CLI commands & tools
  - IAM & security groups
  - Troubleshooting for AWS specifics

---

## 🚀 Quick Start

### Choose Your Platform

**Pick one:**

| Platform | Status | Docs | Time |
|----------|--------|------|------|
| **OVHcloud** | ✅ Production-ready | [→ OVH Docs](/ovh/) | ~65 min |
| **AWS** | 📋 Template available | [→ AWS Docs](/aws/) | ~90 min |
| **GCP** | 🔄 Coming soon | — | TBD |
| **Generic K8s** | ✅ Instructions included | [→ TES Docs](/tes/) | Variable |

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

## 📖 How to Use This Documentation

### I want to deploy on OVHcloud

**Start here**: [OVHcloud Installation Guide](/ovh/installation-guide/)

Then reference:
- [TES Architecture](/tes/architecture/) — Understand the task execution layer
- [Cromwell Configuration](/cromwell/configuration/) — Set up workflow engine
- [Karpenter Configuration](/karpenter/configuration/) — Auto-scaling (optional)

### I want to deploy on AWS

**Start here**: [AWS Installation Guide](/aws/installation-guide/)

Then reference:
- [TES Architecture](/tes/architecture/) — Understand the task execution layer
- [Cromwell Configuration](/cromwell/configuration/) — Set up workflow engine
- [Karpenter Configuration](/karpenter/configuration/) — Auto-scaling (optional)

### I want to understand TES (Funnel)

**Start here**: [Funnel TES Overview](/tes/)

Then dive into:
- [Architecture](/tes/architecture/) — Design & patterns
- [Container Images](/tes/container-images/) — Custom builds
- [Configuration](/tes/configuration/) — Runtime options
- [Troubleshooting](/tes/troubleshooting/) — Common issues

### I want to understand Cromwell

**Start here**: [Cromwell Overview](/cromwell/)

Then dive into:
- [Configuration](/cromwell/configuration/) — Backends & runtime settings
- [Workflows](/cromwell/workflows/) — Submitting & monitoring
- [Troubleshooting](/cromwell/troubleshooting/) — Common issues

### I want quick command references

**See**: [Quick Reference](/quick-reference/)

kubectl, openstack, aws CLI commands, common tasks, troubleshooting.

---

## 🏗️ Architecture Principles

### 1. Cloud-Agnostic Core

- **TES, Cromwell, Karpenter** work on any Kubernetes
- Documentation separates platform-agnostic from platform-specific

### 2. Modular Components

- Swap storage (NFS ↔ S3 ↔ EFS)
- Swap compute (OVH ↔ AWS ↔ GCP)
- Swap autoscaling (Karpenter ↔ KEDA ↔ Manual)

### 3. Storage Strategy (DaemonSet Pattern)

```
DaemonSet (on every node)
  ├─ Mounts shared storage (NFS/EFS/S3)
  └─ Keeps connection alive (prevents timeout)

Task Pods
  ├─ Wait for mount to be ready
  ├─ Consume via hostPath + propagation
  └─ No unmounting on exit (DaemonSet owns lifecycle)
```

### 4. Auto-scaling (Karpenter)

```
Monitor pod queue → Insufficient resources → Scale up nodes
                    Pods completed → Idle timeout → Scale down
```

### 5. Cost Optimization

- Nodes scale to zero when idle
- On-demand pricing, spot instances where available
- Storage tiers based on access patterns

---

## 🔗 Key Links

| Section | Link |
|---------|------|
| **OVHcloud Setup** | [/ovh/](/ovh/) |
| **AWS Setup** | [/aws/](/aws/) |
| **Funnel TES** | [/tes/](/tes/) |
| **Cromwell** | [/cromwell/](/cromwell/) |
| **Karpenter** | [/karpenter/](/karpenter/) |
| **Quick Reference** | [/quick-reference/](/quick-reference/) |

---

## 💡 Common Questions

### Can I use this on a different cloud?

**Yes!** The documentation is structured so you can:
1. Follow [TES](/tes/), [Cromwell](/cromwell/), [Karpenter](/karpenter/) guides (cloud-agnostic)
2. Adapt cloud-specific parts (storage, networking, IAM) for your cloud

### Can I use different storage backends?

**Yes!** The storage layer is modular:
- NFS (Manila, EFS, self-hosted)
- S3 (any S3-compatible endpoint)
- Cloud-native (EBS, Cinder, etc.)

### Do I need Karpenter?

**No**, it's optional:
- For **on-demand auto-scaling**: Use Karpenter
- For **manual scaling**: Use `kubectl scale`
- For **CRON-based scaling**: Use KEDA or custom controllers

### What are the minimum requirements?

- Kubernetes 1.20+ (tested on 1.31.13)
- 2+ worker nodes (or 1 for testing)
- 20+ GB storage (for containers & outputs)
- S3 or NFS for shared data

### Can I mix cloud providers?

**Partially**: Storage might be provider-specific, but:
- Run Cromwell on AWS EKS
- Run workers on OVH MKS (federated)
- Use S3 for data (accessible from both)

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

## 📈 Next Steps

1. **Choose your cloud** ([OVH](/ovh/) or [AWS](/aws/))
2. **Read the platform-specific installation guide**
3. **Reference component documentation** as needed ([TES](/tes/), [Cromwell](/cromwell/), [Karpenter](/karpenter/))
4. **Deploy and test** with smoke tests
5. **Submit your first workflow!**

---

## 📞 Support & Contributions

- **Issues**: Document in GitHub Issues with `[TES]`, `[Cromwell]`, `[OVH]`, or `[AWS]` prefix
- **Updates**: Submit PRs with documentation improvements
- **Questions**: Check relevant section or file an issue

---

## 📋 Helpful Resources

- [Cromwell Documentation](https://cromwell.readthedocs.io/)
- [Funnel TES Documentation](https://ohsu-comp-bio.github.io/funnel/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Karpenter Documentation](https://karpenter.sh/)
- [GA4GH TES Specification](https://ga4gh.github.io/task-execution-schemas/)

---

**Last Updated**: March 13, 2026  
**Version**: 2.0 (Multi-platform)  
**Status**: ✅ Platform-agnostic core complete, OVH production-ready, AWS template available
