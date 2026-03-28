---
layout: default
title: "OVHcloud Cost & Infrastructure"
description: "Cost estimation and infrastructure planning for OVHcloud deployments."
permalink: /ovh/cost-and-infrastructure/
---

# OVHcloud Cost & Infrastructure

> All prices are for the **GRA9** (Gravelines) region, sourced from the [OVHcloud Public Cloud pricing page](https://www.ovhcloud.com/en-ie/public-cloud/prices/) (July 2025). Prices are **ex. VAT**, billed per hour with 730 hours used for monthly estimates. Always verify against current OVH pricing before planning.

---

## Pricing References

| Service | OVH Documentation |
|---|---|
| Instances (flavors) | [Virtual Machine Instances](https://www.ovhcloud.com/en-ie/public-cloud/virtual-instances/) |
| Managed Kubernetes (MKS) | [MKS Pricing](https://www.ovhcloud.com/en-ie/public-cloud/kubernetes/) |
| Block Storage (Cinder) | [Block Storage](https://www.ovhcloud.com/en-ie/public-cloud/block-storage/) |
| File Storage (Manila / NFS) | [File Storage](https://www.ovhcloud.com/en-ie/public-cloud/file-storage/) |
| Object Storage (S3) | [Object Storage](https://www.ovhcloud.com/en-ie/public-cloud/object-storage/) |
| Load Balancer | [Load Balancer](https://www.ovhcloud.com/en-ie/public-cloud/load-balancer/) |
| Gateway | [Gateway](https://www.ovhcloud.com/en-ie/public-cloud/gateway/) |
| Floating IP | [Floating IP](https://www.ovhcloud.com/en-ie/public-cloud/floating-ip/) |
| Managed Private Registry (MPR) | [MPR Pricing](https://www.ovhcloud.com/en-ie/public-cloud/managed-private-registry/) |
| Full pricing page | [OVHcloud Public Cloud Prices](https://www.ovhcloud.com/en-ie/public-cloud/prices/) |

---

## Baseline Cost (Always-On Infrastructure)

This is the cost for all resources running **24/7**, even when no WES tasks are executing through TES/Funnel.

| Component | Flavor / Plan | Rate | Monthly (~730 h) | Notes |
|---|---|---|---|---|
| MKS control plane | Free tier | — | **€0** | Max 100 nodes, 1 AZ, 99.5% SLO |
| System node | `d2-4` (2 vCPU, 4 GB) | €0.0198/hr | **~€14.45** | Hosts Karpenter + Funnel server pod |
| OVHcloud Gateway | Gateway S (200 Mbps) | €0.0028/hr | **~€2.04** | Required for LoadBalancer service |
| Load Balancer | LB S (200 Mbps) | €0.0083/hr | **~€6.06** | `funnel-lb` Kubernetes service |
| Floating IP | IPv4 /32 | €0.0025/hr | **~€1.83** | Public IP attached to the Load Balancer |
| Manila NFS share | 150 GB, `standard-1az` | Free (beta) | **~€0** | See note below |
| Managed Private Registry | Plan S (200 GB) | €0.0237/hr | **~€17.30** | Harbor registry for container images |
| S3 Object Storage | Standard, ~5 GB standing | €0.00000972/GiB/hr | **~€0.04** | Reference data, standing logs |
| Private vRack network | — | Free | **€0** | `192.168.100.0/24` internal network |
| **Total baseline** | | | **~€41.70 / month** | |

> **Manila NFS (File Storage):** OVHcloud File Storage (Manila-backed NFS shares) is currently in **free public beta** in GRA (Gravelines). When the service reaches General Availability (GA), pricing is expected to be approximately **€0.07–0.10 / GB / month**, which would add ~**€10–15 / month** to the baseline. Monitor the [OVHcloud roadmap](https://www.ovhcloud.com/en-ie/roadmap-changelog/) for GA announcements.

> **MKS Standard tier:** If the project outgrows the Free plan (> 100 nodes or multi-AZ), the Standard tier is approximately **€70 / month** for the control plane alone. The Free tier is sufficient for this deployment.

---

## Per-Sample Variable Cost (WES Analysis)

Benchmark figures are derived from actual runs on this cluster. A typical WES sample generates ~50 GB of intermediate and output data and completes in approximately **2 hours** of active compute time.

Outgoing (egress) traffic on OVHcloud Public Cloud in GRA is **free** — no egress charges apply to S3 downloads or worker node output.

### Compute (Karpenter workers)

Karpenter spins up `b3`/`c3` worker nodes on demand and terminates them after task completion. All worker time is billed per second.

| Component | Estimated Cost | Notes |
|---|---|---|
| Karpenter worker nodes | **~€1.10** | Benchmark average (mix of `b3`/`c3` flavors) |
| Cinder volumes (temp, per-task) | **~€0.02–0.05** | ~100 GB × 2 h × €0.000119/GiB/hr; auto-cleaned after task |

### Storage (S3)

| Component | Estimated Cost | Notes |
|---|---|---|
| S3 during analysis (50 GB × 2 h) | **~€0.001** | €0.00000972/GiB/hr × 50 × 2 — negligible |
| S3 egress | **€0** | Outgoing public traffic is free in GRA |
| S3 long-term retention (50 GB / month) | **~€0.36 / month** | Optional; policy-dependent — delete after results are extracted |

### Per-Sample Total

| Scenario | Cost |
|---|---|
| Analysis only (results extracted + S3 purged) | **~€1.12–1.15** |
| + 1 month S3 data retention (50 GB) | **~€1.48–1.51** |

---

## Cost Scaling

Projected monthly totals combining fixed baseline with per-sample variable costs.  
*Assumes results are downloaded and purged from S3 after each analysis.*

| Samples / Month | Compute Cost | Baseline | **Total** | Effective Cost / Sample |
|---|---|---|---|---|
| 10 | ~€11 | €41.70 | **~€52.70** | ~€5.27 |
| 50 | ~€56 | €41.70 | **~€97.70** | ~€1.95 |
| 100 | ~€112 | €41.70 | **~€153.70** | ~€1.54 |
| 500 | ~€560 | €41.70 | **~€601.70** | ~€1.20 |
| 1 000 | ~€1120 | €41.70 | **~€1 161.70** | ~€1.16 |

At higher throughput the baseline becomes negligible and the effective cost converges toward the raw compute cost (~€1.10–1.15 / sample).

---

## Cost Optimization Notes

- **Scale-to-zero workers:** Karpenter removes idle worker nodes within minutes of task completion. You only pay for actual compute time, not standby capacity.
- **MKS Free tier:** The free control plane (max 100 concurrent nodes) is sufficient for most bioinformatics workloads. Upgrading to Standard adds ~€70 / month for multi-AZ redundancy.
- **Manila NFS free beta:** The 150 GB NFS share is currently free. Consider provisioning a larger share now while pricing is zero if scratch space becomes a bottleneck.
- **S3 data lifecycle:** Enable OVH S3 lifecycle policies to auto-expire intermediate files. Each month of 50 GB retention adds ~€0.36 / sample in standing storage costs.
- **Egress is free:** Downloading analysis results (BAM, VCF, etc.) from S3 to your institution does not incur OVH charges in GRA.
- **MPR plan selection:** The S plan (200 GB, ~€17.30 / month) is the dominant baseline cost item. It is flat-rate regardless of usage. If the image catalog stays small, this is sufficient; there is no pay-per-pull model.
- **Block Storage cleanup:** Cinder volumes are LUKS-encrypted and auto-cleaned by Funnel after task completion. Verify cleanup is working to avoid orphaned volumes accumulating cost (High Speed Gen2: €0.000119/GiB/hr).
- **Savings Plans:** OVHcloud offers Savings Plans for predictable workloads (1–36 month commitment). The `d2-4` Savings Plan rate (1-month) is €0.0206/hr — a marginal saving over on-demand for a node running continuously.
