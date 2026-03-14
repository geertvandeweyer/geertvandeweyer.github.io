---
layout: default
title: "AWS Deployment"
description: "Guide to deploying Cromwell + TES on AWS EKS"
permalink: /aws/
---

# AWS Deployment

**Comprehensive guide to deploying Cromwell + Funnel TES on AWS EKS**

> ✅ **Status**: Production-ready documentation (AWS Karpenter 1.9.0, EKS 1.34+)

This section covers deploying the platform on Amazon AWS using EKS (Elastic Kubernetes Service), EFS (Elastic File System), S3, and Karpenter for autoscaling.

---

## Quick Start

**Estimated deployment time**: 90–120 minutes

1. **[Phase 0: Prerequisites](/aws/installation-guide/#phase-0-prerequisites)** (15 min)
   - AWS account setup, credentials, quotas
2. **[Phase 1: EKS Cluster](/aws/installation-guide/#phase-1-eks-cluster-creation)** (20–30 min)
   - CloudFormation infrastructure deployment
3. **[Phase 2: Karpenter](/aws/installation-guide/#phase-2-karpenter-autoscaling)** (5 min)
   - Autoscaling workers
4. **[Phase 3-7: Storage & Services](/aws/installation-guide/#phase-3-efs-storage)** (30–40 min)
   - EFS, S3, Funnel, Cromwell setup

For detailed walkthrough, see **[Installation Guide](/aws/installation-guide/)**.

---

## 📖 Complete Documentation

### 🚀 [Installation Guide](/aws/installation-guide/) — START HERE
- 7-phase deployment walkthrough (Phase 0–7)
- AWS architecture diagram (VPC → EKS → EFS/S3/ECR)
- AWS vs OVH comparison
- Prerequisites (AWS account, quotas, tools, credentials)
- Detailed code examples for each phase
- Verification steps after each phase
- Troubleshooting for common setup issues

### ⚙️ [Karpenter on AWS](/karpenter/cloud-providers/aws/)
- AWS-specific Karpenter configuration
- NodePool & EC2NodeClass setup
- Spot vs On-Demand strategy
- Instance family selection (c6g, c6i, m6g)
- Cost optimization (70% Spot savings)
- Graceful Spot interruption handling
- Quota management (Spot quota exhaustion)

### 🔧 [Troubleshooting Guide](/aws/troubleshooting/)
- ⭐ **START HERE if deployment fails**
- EKS cluster issues (CloudFormation, nodes not joining)
- Karpenter issues (pods stuck pending, nodes not scaling)
- Funnel TES issues (CrashLoopBackOff, task failures)
- S3 & EFS access problems
- Cromwell integration issues (TES 500 "task not found")
- Network & connectivity issues
- Performance optimization

### 💰 [Cost & Capacity Planning](/aws/cost-and-capacity/)
- Cost breakdown (EKS, EC2, EFS, S3, data transfer)
- Monthly scenarios: Small ($83), Medium ($337), Large ($1,679)
- Cost optimization strategies
- Quota planning (EC2, Spot, On-Demand, VPC)
- Storage capacity planning
- Budget planning templates

---

## Deployment Models

### Model A: Development (Spot-Only)
```yaml
# All Spot instances → 70% cost savings
# Trade-off: Tasks interrupted randomly
Cost: ~$80–150/month (100–200 tasks/month)
For: Testing, prototyping, fault-tolerant workflows
```

### Model B: Production (Mixed)
```yaml
# 70% Spot + 30% On-Demand
# Guaranteed availability for critical tasks
Cost: ~$200–500/month (500–1000 tasks/month)
For: Regular genomics analysis, daily workflows
```

### Model C: Enterprise (On-Demand Majority)
```yaml
# 30% Spot + 70% On-Demand
# Maximum reliability, higher cost
Cost: ~$1000–2000/month (2000–5000 tasks/month)
For: Production genomics platform, SLA requirements
```

---

## Platform Comparison

### AWS vs OVH

| Aspect | AWS | OVH |
|--------|-----|-----|
| **Setup time** | 20–30 min | 30–45 min |
| **Quota model** | Spot/On-Demand per account | vCPU/RAM per project |
| **Instance selection** | 300+ types | ~20 types |
| **Cost optimization** | 70% via Spot | Limited options |
| **Storage** | EFS (NFS) + S3 (object) | Manila (NFS) + S3-compat |
| **Learning curve** | Moderate (IAM, ECS) | Moderate (OVH API) |
| **Auto-scaling** | Karpenter (30–60s) | Karpenter (30–60s) |
| **Support** | AWS Support (paid) | OVH Support |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│          AWS Account                            │
│  ┌───────────────────────────────────────────┐  │
│  │  VPC (10.0.0.0/16)                        │  │
│  │  ├─ Public Subnets (ALB, NAT)             │  │
│  │  ├─ Private Subnets (EKS nodes)           │  │
│  │  ├─ Route Tables (VPC → IGW/NAT)          │  │
│  │  └─ Security Groups                       │  │
│  │                                            │  │
│  │  ┌──────────────────────────────┐         │  │
│  │  │  EKS Cluster (1.34+)         │         │  │
│  │  │  ├─ System nodes (on-demand) │         │  │
│  │  │  │  ├─ Karpenter controller  │         │  │
│  │  │  │  ├─ CoreDNS               │         │  │
│  │  │  │  └─ ALB controller        │         │  │
│  │  │  │                            │         │  │
│  │  │  ├─ Worker nodes (Spot/On-D) │         │  │
│  │  │  │  ├─ Funnel pod            │         │  │
│  │  │  │  └─ Task pods (Cromwell)  │         │  │
│  │  │  └─ Karpenter (provisioner)  │         │  │
│  │  └──────────────────────────────┘         │  │
│  │           ↓ ↓ ↓                            │  │
│  │  ┌──────────────────────────────┐         │  │
│  │  │  Storage                     │         │  │
│  │  │  ├─ EFS (shared scratch)     │         │  │
│  │  │  ├─ EBS (node-local)         │         │  │
│  │  │  └─ S3 (artifacts, references)        │  │
│  │  └──────────────────────────────┘         │  │
│  │                                            │  │
│  │  ┌──────────────────────────────┐         │  │
│  │  │  Services                    │         │  │
│  │  │  ├─ Funnel (TES HTTP API)    │         │  │
│  │  │  ├─ ALB (external access)    │         │  │
│  │  │  ├─ IAM IRSA (pod auth)      │         │  │
│  │  │  └─ CloudWatch (logs, metrics)        │  │
│  │  └──────────────────────────────┘         │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

---

## Next Steps

1. **First-time users**: Start with [Installation Guide](/aws/installation-guide/)
2. **Deployment issues**: Check [Troubleshooting Guide](/aws/troubleshooting/)
3. **Optimize costs**: Review [Cost & Capacity](/aws/cost-and-capacity/) and [Karpenter Guide](/karpenter/cloud-providers/aws/)
4. **Advanced tuning**: See specific guides for Cromwell, Funnel, TES configuration

---

## Related Platforms

- **[OVH Deployment](/ovh/)** — Deploy on OVH Managed Kubernetes
- **[Karpenter Hub](/karpenter/)** — Karpenter documentation for all clouds
- **[TES/Funnel Hub](/tes/)** — Task Execution Service setup

---

## Quick Reference

**Key AWS services:**
- **EKS**: Managed Kubernetes (control plane + worker nodes)
- **Karpenter**: Auto-scaler (provisions EC2 instances)
- **EFS**: Shared NFS storage for workflows
- **S3**: Object storage for inputs/outputs
- **IAM IRSA**: Pod authentication to AWS services
- **CloudFormation**: Infrastructure-as-Code for networking
- **ALB**: Load balancer for external access

**Key files:**
- `install-eks-karpenter.sh` (910-line main installer)
- `env.variables` (100-line configuration)
- `yamls/` (CloudFormation, Karpenter, Funnel templates)

---

**Last Updated**: March 13, 2026  
**Documentation Version**: 2.0 (Production-Ready)  
**AWS CLI Version**: Latest  
**EKS Kubernetes**: 1.34+  
**Karpenter**: 1.9.0+

---

## 🏗️ AWS Architecture

```
AWS Account (us-east-1)
┌──────────────────────────────────────────────────┐
│ VPC (10.0.0.0/16)                                │
│ ├─ Public Subnets (ALB, NAT Gateway)             │
│ └─ Private Subnets (EKS, EFS, no internet)       │
└──────────────────────────────────────────────────┘
         │
         ├─ EKS Cluster (Kubernetes 1.31+)
         │  ├─ System Node (t3.large, always-on)
         │  │  ├─ Karpenter Controller
         │  │  ├─ Funnel Server
         │  │  └─ Cromwell Server
         │  └─ Worker Nodes (Karpenter-managed)
         │     ├─ Funnel Disk Setup (DaemonSet)
         │     └─ Task Pods (on demand)
         │
         ├─ EFS (Elastic File System)
         │  └─ Mounted on all nodes
         │
         ├─ EBS Volumes (per task)
         │  └─ Encrypted with AWS KMS
         │
         └─ S3 (Simple Storage Service)
            └─ Task I/O, workflow inputs/outputs
```

---

## 🔧 Key Technologies

| Technology | Role | Notes |
|-----------|------|-------|
| **EKS** | Kubernetes cluster | Managed service (~$0.10/hour) |
| **Karpenter** | Auto-scaling | Scales EC2 instances on demand |
| **EFS** | Shared storage | Highly available NFS |
| **EBS** | Task storage | Per-volume encryption with KMS |
| **S3** | Object storage | Workflow I/O, long-term storage |
| **IAM** | Access control | Role-based permissions |
| **SecurityGroups** | Network | Ingress/egress rules |

---

## 🚀 Quick Start (Template)

### Prerequisites

```bash
# AWS account with API credentials
aws configure  # Configure with AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY

# Tools installed
which aws                 # AWS CLI
which kubectl             # Kubernetes CLI
which helm                # Helm (for deployments)
which eksctl              # EKS cluster management tool
```

### Estimated Deployment Time

```
Phase 0: Environment        (5 min)
Phase 1: VPC & Networking   (10 min)
Phase 2: Create EKS Cluster (20 min)
Phase 3: Configure Karpenter (10 min)
Phase 4: Set up EFS         (10 min)
Phase 5: Create S3 Bucket   (5 min)
Phase 6: Deploy Funnel      (10 min)
Phase 7: Deploy Cromwell    (5 min)
Phase 8: Smoke Tests        (10 min)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Total:                      ~85 minutes
```

---

## 📊 Infrastructure Details

### Recommended Cluster Specification

| Component | Value |
|-----------|-------|
| **Region** | us-east-1 (or your choice) |
| **Kubernetes Version** | 1.31+ |
| **System Node** | t3.large (always-on, ~$0.08/hour) |
| **Worker Nodes** | t3.2xlarge, c5.2xlarge (auto-scaled, $0.35-0.50/hour) |
| **VPC CIDR** | 10.0.0.0/16 (customizable) |
| **EFS** | Standard tier (auto-scaled storage) |

### Estimated Monthly Cost

```
System Node (t3.large):     ~€60/month
Workers (auto-scale, avg):  ~€100-300/month (usage-based)
EFS Storage (100GB):        ~€30/month
S3 Storage (100GB):         ~€2.30/month
NAT Gateway:                ~€40/month
Data Transfer:              ~€10-50/month (outbound)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Total:                      ~€240-500/month (depending on usage)
```

---

## 🔗 Platform-Agnostic Sections

Reference these guides for detailed component information:

- **[Funnel TES](/tes/)** — Task execution (AWS-independent)
- **[Cromwell](/cromwell/)** — Workflow orchestration (AWS-independent)
- **[Karpenter](/karpenter/)** — Auto-scaling (AWS-independent)
- **[Karpenter AWS Provider](/karpenter/cloud-providers/#aws)** — AWS-specific scaling

---

## 📚 Full Documentation

### Quick References

- **[Installation Guide](/aws/installation-guide/)** — Step-by-step deployment (TEMPLATE)
- **[CLI Guide](/aws/cli-guide/)** — AWS CLI commands (TEMPLATE)
- **[Cost & Capacity](/aws/cost-and-capacity/)** — Budget planning (TEMPLATE)
- **[Troubleshooting](/aws/troubleshooting/)** — Common issues (TEMPLATE)

---

## 🆘 Troubleshooting

### Common Issues

**EFS mount failing?**
→ See [EFS Troubleshooting](/aws/troubleshooting/#efs-issues) (template)

**Nodes not scaling?**
→ See [Karpenter Issues](/aws/troubleshooting/#karpenter-scaling) (template)

**S3 access denied?**
→ See [IAM & S3 Access](/aws/troubleshooting/#s3-access) (template)

---

## 💡 Migration Path from OVH

If you're migrating from OVH to AWS:

1. Follow [OVH docs](/ovh/) to understand architecture
2. Use this **AWS template** as a reference
3. Map OVH concepts to AWS:
   - OVH MKS → AWS EKS
   - Manila NFS → AWS EFS
   - Cinder volumes → AWS EBS
   - OVH S3 → AWS S3
   - Karpenter OVH provider → Karpenter AWS provider
4. Adapt storage and networking as needed
5. Test with smoke tests

---

## 📝 Contributing

This AWS template is a work in progress. To contribute:

1. Test deployment on AWS EKS
2. Document actual commands and outputs
3. Update cost estimates with real data
4. Submit PR with deployment experience

---

## 🎯 Future Plans

- [ ] Complete installation guide with actual AWS commands
- [ ] Karpenter AWS provider examples
- [ ] IAM policy templates
- [ ] CloudFormation IaC templates
- [ ] Multi-region deployment
- [ ] AWS Spot Instances integration
- [ ] AWS Cost Explorer integration

---

## ℹ️ Note

This section is a **template** for AWS deployment. The architecture and principles are identical to the [OVH deployment](/ovh/), but AWS-specific commands, APIs, and configurations need to be adapted.

**Production AWS deployment**: Coming in next iteration.  
**Volunteers welcome**: PR contributions for AWS-specific implementation.

---

**Status**: 📋 **Template** (production implementation in progress)  
**Last Updated**: March 13, 2026  
**Version**: 2.0 (Multi-platform, AWS template)
