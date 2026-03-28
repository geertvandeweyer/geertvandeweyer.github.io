---
layout: default
title: "AWS Cost & Infrastructure"
description: "Cost estimation and infrastructure planning for AWS EKS deployments (eu-north-1)."
permalink: /aws/cost-and-infrastructure/
---

# AWS Cost & Infrastructure

> All prices are for the **eu-north-1** (Stockholm) region. Prices are **ex. VAT / USD**, billed per second for EC2 instances. Always verify against the [AWS Pricing Calculator](https://calculator.aws/pricing/2/home) before planning.

> **NOTE:** Benchmark figures for compute per WES sample are pending. This page will be updated once production runs in eu-north-1 are available. The OVHcloud benchmark (~1.10 € / sample) is provided as a reference.

---

## Pricing References

| Service | AWS Documentation |
|---|---|
| EC2 instances | [EC2 Pricing (eu-north-1)](https://aws.amazon.com/ec2/pricing/on-demand/) |
| EKS control plane | [EKS Pricing](https://aws.amazon.com/eks/pricing/) |
| EFS storage | [EFS Pricing](https://aws.amazon.com/efs/pricing/) |
| EBS volumes | [EBS Pricing](https://aws.amazon.com/ebs/pricing/) |
| S3 object storage | [S3 Pricing](https://aws.amazon.com/s3/pricing/) |
| ECR registry | [ECR Pricing](https://aws.amazon.com/ecr/pricing/) |
| ALB / Network LB | [ELB Pricing](https://aws.amazon.com/elasticloadbalancing/pricing/) |
| Data transfer | [EC2 Data Transfer Pricing](https://aws.amazon.com/ec2/pricing/on-demand/#Data_Transfer) |
| Spot instances | [EC2 Spot Pricing](https://aws.amazon.com/ec2/spot/pricing/) |
| Full pricing page | [AWS Pricing Calculator](https://calculator.aws/pricing/2/home) |

---

## Baseline Cost (Always-On Infrastructure)

Estimated cost for all resources running **24/7** with zero tasks executing.

| Component | Service / Size | Rate | Monthly (~730 h) | Notes |
|---|---|---|---|---|
| EKS control plane | — | $0.10/hr | **~$73** | Fixed per cluster |
| System node | `t4g.medium` (2 vCPU, 4 GB) | ~$0.0336/hr | **~$24.55** | Hosts Karpenter + Funnel server |
| EBS (system node OS disk) | gp3, 20 GB | $0.0928/GB-month | **~$1.86** | |
| Application Load Balancer | — | $0.018/hr + LCU | **~$13–20** | For Funnel TES endpoint |
| EFS shared storage | Standard 1-AZ, 50 GB | $0.16/GB-month | **~$8** | Shared workflow scratch space |
| ECR private registry | ~20 GB stored images | $0.10/GB-month | **~$2** | Container image registry |
| S3 standing data | ~5 GB | $0.023/GB-month | **~$0.12** | Reference data, logs |
| **Total baseline** | | | **~$122–130 / month** | |

> **EKS control plane** at $0.10/hr = $73/month is the dominant fixed cost item, contrasting with OVH MKS Free tier (€0). AWS Standard tier has no free control plane option.

> **Data transfer:** Outbound to the internet is charged at **$0.09/GB** (first 10 TB/month) in eu-north-1. This is a significant difference from OVHcloud where egress is free. Factor this into per-sample costs if analysis results are downloaded externally.

---

## Per-Sample Variable Cost (WES Analysis) — Estimates Pending

A typical WES sample generates ~50 GB of intermediate data, with ~5 GB final results, completing in approximately 2 hours.

### Compute (Karpenter workers — Spot)

| Component | Estimated Cost | Notes |
|---|---|---|
| Karpenter worker nodes (Spot) | **~$0.80–1.20** | Pending benchmark; reference OVH: ~€1.10 |
| EBS volumes (temp, per-task) | **~$0.02–0.05** | ~100 GB × 2 h × $0.0000001268/GiB/s (gp3) |

### Storage (S3)

| Component | Estimated Cost | Notes |
|---|---|---|
| S3 during analysis (50 GB × 2 h) | **~$0.001** | Negligible |
| S3 egress — results to internet (5 GB) | **~$0.45** | $0.09/GB × 5 GB — significant vs OVH (free) |
| S3 long-term retention (5 GB cold archive) | **~$0.005 / month** | S3 Glacier Instant Retrieval: $0.004/GB-month |

### Per-Sample Total (Estimate)

| Scenario | Estimated Cost |
|---|---|
| Analysis only (results in S3, no download) | **~$0.85–1.25** |
| + Download 5 GB results to external | **~$1.30–1.70** |
| + 1 month Glacier archive (5 GB) | **+~$0.02** |

---

## Long-Term Archive Accumulation (6 000 Samples / Year)

Using **S3 Glacier Instant Retrieval** ($0.004/GB-month), 5 GB per sample retained.

| End of Year | Samples Archived | Total Stored | Monthly Rate | Annual Cost | Cumulative Cost |
|---|---|---|---|---|---|
| 1 | 6 000 | 30 TB | ~$120 | ~$720 | **~$720** |
| 2 | 12 000 | 60 TB | ~$240 | ~$2 160 | **~$2 880** |
| 3 | 18 000 | 90 TB | ~$360 | ~$3 600 | **~$6 480** |
| 5 | 30 000 | 150 TB | ~$600 | ~$6 480 | **~$18 000** |
| 10 | 60 000 | 300 TB | ~$1 200 | ~$13 680 | **~$72 000** |

> **Glacier Deep Archive** ($0.00099/GB-month) would reduce the 10-year total to **~$18 000**, but retrieval takes 12 hours (standard) and costs $0.0025/GB. Suitable for compliance archives not expected to be retrieved.

---

## Cost Scaling (Estimates)

| Samples / Month | Compute Cost | Baseline | **Total** | Effective Cost / Sample |
|---|---|---|---|---|
| 10 | ~$10 | $125 | **~$135** | ~$13.50 |
| 50 | ~$50 | $125 | **~$175** | ~$3.50 |
| 100 | ~$100 | $125 | **~$225** | ~$2.25 |
| 500 | ~$500 | $125 | **~$625** | ~$1.25 |
| 1 000 | ~$1 000 | $125 | **~$1 125** | ~$1.13 |

*Compute cost estimates are preliminary. Benchmark against production runs.*

---

## Cost Optimization Notes

- **Spot instances:** Karpenter on AWS natively supports Spot with interruption handling. 60–70% savings over On-Demand. See [Quota Guide](/aws/quota/) for required quota increases.
- **EKS control plane cost:** At $73/month this is unavoidable — factor it into per-sample amortization. At 1 000 samples/month it adds ~$0.07/sample.
- **Egress charges:** Unlike OVH (free egress), AWS charges $0.09/GB out to internet. Keep analysis consumers (Cromwell, downstream tools) within the same AWS region to minimize data transfer costs.
- **Graviton instances:** `c7g`/`c6g` (Graviton) are ~20% cheaper than equivalent Intel `c6i` in eu-north-1 and available for EKS worker nodes. Bioinformatics tools compiled for x86 run via Rosetta-equivalent on arm64; verify tool containers support `linux/arm64`.
- **S3 Intelligent-Tiering:** For intermediate results with uncertain access patterns, use S3 Intelligent-Tiering to auto-move data to cheaper storage classes after 30/90 days.
- **Savings Plans:** EKS-managed node Savings Plans (Compute Savings Plans) apply to Karpenter-managed EC2 instances. A 1-year Compute Savings Plan for the system node yields ~20% savings.
