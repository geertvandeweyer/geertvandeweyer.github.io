---
layout: default
title: "AWS Deployment (Template)"
description: "Guide to deploying Cromwell + TES on AWS EKS (coming soon)"
permalink: /aws/
---

# AWS Deployment (Template)

**Guide to deploying Cromwell + Funnel TES on AWS EKS**

> 📋 **Status**: Template available (production implementation in progress)

This section provides a template for deploying the platform on Amazon AWS using EKS (Elastic Kubernetes Service), EFS (Elastic File System), and S3.

---

## 📖 Documentation

### [Installation Guide](/aws/installation-guide/)
- Phase-by-phase deployment walkthrough (estimated ~90 minutes)
- AWS-specific networking setup (VPC, subnets, security groups)
- IAM roles and permissions
- EKS cluster creation and configuration
- Karpenter auto-scaling setup
- EFS storage configuration
- S3 bucket setup

### [AWS CLI Guide](/aws/cli-guide/)
- AWS CLI commands
- VPC and network management
- IAM policy configuration
- EC2 instance management
- S3 operations

### [Cost & Capacity](/aws/cost-and-capacity/)
- EC2 instance pricing
- EFS storage costs
- S3 storage costs
- Budget planning
- Cost optimization strategies

### [Troubleshooting](/aws/troubleshooting/)
- AWS-specific issues
- IAM permission problems
- Network connectivity issues
- EFS mount failures
- Auto-scaling problems

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
