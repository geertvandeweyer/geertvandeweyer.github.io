---
layout: default
title: "AWS CLI Guide"
description: "AWS CLI and eksctl commands for managing EKS, EC2, EFS, S3, and ECR."
permalink: /aws/cli-guide/
---

# AWS CLI Guide

> **NOTE:** This is a stub page. Command reference will be added after deployment is production-tested on eu-north-1.

This page will document all **AWS CLI** (`aws`) and **eksctl** commands used in the deployment and operation of the Cromwell + Funnel TES platform on AWS EKS.

---

## Tools Covered

| Tool | Purpose | Install |
|---|---|---|
| `aws` | AWS CLI v2 — all service APIs | [AWS CLI docs](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| `eksctl` | EKS cluster lifecycle management | [eksctl.io](https://eksctl.io/installation/) |
| `kubectl` | Kubernetes cluster management | [k8s docs](https://kubernetes.io/docs/tasks/tools/) |
| `helm` | Karpenter & add-on deployment | [helm.sh](https://helm.sh/docs/intro/install/) |

---

## Sections (Planned)

### `aws` CLI

- **IAM** — create roles, attach policies, create OIDC provider for EKS
- **EKS** — cluster describe, kubeconfig update, nodegroup management
- **EC2** — instance listing, Spot price history, quota checks
- **EFS** — filesystem create, access point management, mount target status
- **S3** — bucket create, sync, lifecycle policy
- **ECR** — registry auth, image push/pull
- **Service Quotas** — query and request quota increases

### `eksctl`

- Cluster creation and deletion
- IAM service account (`iamserviceaccount`) for Karpenter and EFS CSI
- Addon management (EFS CSI driver, CoreDNS, kube-proxy)
- Fargate profile management

---

## Resources

- [AWS CLI Command Reference](https://docs.aws.amazon.com/cli/latest/reference/)
- [eksctl Documentation](https://eksctl.io/)
- [EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/)
- [Karpenter AWS Documentation](https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/)
