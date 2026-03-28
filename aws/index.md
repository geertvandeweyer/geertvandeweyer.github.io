---
layout: default
title: "AWS Deployment"
description: "Guide to deploying Cromwell + TES on AWS EKS (eu-north-1)"
permalink: /aws/
---

# AWS Deployment

**Guide to deploying Cromwell + Funnel TES on AWS EKS**

> **Status**: Installation guide is a stub — production validation on eu-north-1 (Stockholm) is in progress. Quota guide and cost estimates are available.

Deploy a complete genomic workflow platform on **AWS EKS** with managed Kubernetes, EFS shared storage, S3 object storage, and Karpenter auto-scaling.

---

## AWS Architecture at a Glance

```
AWS (eu-north-1 / Stockholm, 3 AZ)
┌─────────────────────────────────────────────────────┐
│ VPC (10.0.0.0/16)                                   │
│ ├─ Public subnets  (ALB, NAT Gateway)               │
│ └─ Private subnets (EKS nodes, EFS mount targets)   │
└─────────────────────────────────────────────────────┘
         │
         ├─ EKS Cluster (Kubernetes 1.34)
         │  ├─ System Node (t4g.medium, always-on)
         │  │  ├─ Karpenter Controller
         │  │  └─ Funnel Server
         │  └─ Worker Nodes (Karpenter-managed, Spot)
         │     └─ Task Pods (on demand)
         │
         ├─ EFS (Elastic File System)
         │  └─ Multi-AZ NFS, CSI-mounted on all nodes
         │
         ├─ EBS volumes (per task)
         │  └─ gp3, auto-provisioned, KMS-encrypted
         │
         ├─ ECR (Elastic Container Registry)
         │  └─ Private container image registry
         │
         └─ S3
            └─ Task I/O, workflow inputs/outputs, cold archive
```

**Key Technologies**

| Technology | Role | Details |
|---|---|---|
| **EKS** | Kubernetes cluster | Managed service, $0.10/hr control plane |
| **Karpenter** | Auto-scaling | Scales workers on demand, Spot support |
| **EFS** | Shared storage | Multi-AZ NFS, CSI driver |
| **EBS** | Task local storage | gp3 volumes, auto-provisioned per task |
| **S3** | Object storage | Workflow I/O, persistent storage |
| **ECR** | Container registry | Private registry for task images |
| **IAM / IRSA** | Access control | Pod-level authentication to AWS services |

---

## Documentation

### [Installation Guide](/aws/installation-guide/) *(stub — content pending)*
- 7-phase deployment walkthrough (Phase 0–7)
- Architecture: VPC → EKS → EFS/S3/ECR
- Prerequisites: AWS account, IAM, tools, quotas
- Estimated time: ~90–120 minutes

### [AWS EC2 Quota Guide](/aws/quota/) ⭐ **Review Before Deploying**
- On-Demand and Spot vCPU quota types explained
- Default limits in eu-north-1 (5 vCPU Spot — must increase)
- Recommended instance families: `c7g`, `c6g`, `c6i`
- Three-layer Karpenter filtering strategy
- How to request quota increases via Service Quotas console

### [AWS CLI Guide](/aws/cli-guide/) *(stub — content pending)*
- `aws` CLI commands: EKS, EC2, EFS, S3, ECR, IAM, Service Quotas
- `eksctl` commands: cluster lifecycle, IAM service accounts, addons

### [Cost & Infrastructure](/aws/cost-and-infrastructure/)
- Baseline cost breakdown: EKS, system node, EFS, ALB, ECR (~$125/month)
- Per-sample variable cost estimate (pending benchmark)
- Long-term archive accumulation table (S3 Glacier, 6 000 samples/year)
- Cost optimization: Spot instances, Graviton, egress management

---

## AWS vs OVH Comparison

| Aspect | AWS (eu-north-1) | OVH (GRA9) |
|---|---|---|
| **Kubernetes** | EKS ($73/month control plane) | MKS (free tier) |
| **Shared storage** | EFS NFS ($0.16/GB-month 1AZ) | Manila NFS (free beta) |
| **Block storage** | EBS gp3 ($0.0928/GB-month) | Cinder ($0.087/GB-month) |
| **Object storage** | S3 ($0.023/GB-month) | OVH S3 ($0.007/GB-month) |
| **Container registry** | ECR ($0.10/GB-month) | MPR Plan S (€17.30/month flat) |
| **Egress (internet)** | $0.09/GB | **Free** |
| **Karpenter** | Native provider | Community provider |
| **Spot instances** | Full support | On-Demand only |
| **Baseline cost** | ~$125/month | ~€42/month |

---

## Production Checklist

- [ ] EC2 quotas increased (On-Demand + Spot) in eu-north-1
- [ ] VPC + EKS cluster deployed
- [ ] Karpenter auto-scaling working
- [ ] EFS mounted on all nodes
- [ ] S3 access configured (IRSA)
- [ ] ECR registry populated
- [ ] Funnel TES deployed and reachable
- [ ] Cromwell-Funnel integration tested
- [ ] Workflow execution verified

---

**Status**: 🔧 **In Progress**  
**Region**: eu-north-1 (Stockholm)  
**Target**: EKS 1.34, Karpenter 1.9.0+
