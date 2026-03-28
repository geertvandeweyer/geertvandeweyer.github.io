---
layout: default
title: "OVHcloud Cost & Infrastructure"
description: "Cost estimation and infrastructure planning for OVHcloud deployments."
permalink: /ovh/cost-and-infrastructure/
---

# OVHcloud Cost & Infrastructure

> All prices are for the **GRA9** (Gravelines) region, sourced from the [OVHcloud Public Cloud pricing page](https://www.ovhcloud.com/en-ie/public-cloud/prices/) (March 2026). Prices are **ex. VAT**, billed per hour with 730 hours used for monthly estimates. Always verify against current OVH pricing before planning.

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
| S3 long-term retention (5 GB cold archive) | **~€0.008 / month** | Cold Archive (PAR); €0.00000228/GiB/hr × 730 h; only final results kept |

### Per-Sample Total

| Scenario | Cost |
|---|---|
| Analysis only (results extracted + S3 purged) | **~€1.12–1.15** |
| + 1 month cold archive (5 GB, Cold Archive PAR) | **~€1.13** |

### Long-Term Archive Accumulation (6 000 Samples / Year)

Assuming 6 000 WES samples archived per year, each retaining **5 GB** in **Cold Archive** (€0.00000228/GiB/hr, PAR region). Archive grows linearly; the monthly rate at end of year N = N × 6 000 × 5 GiB × €0.001664/GiB/month ≈ **N × €50/month**. Annual cost uses the average monthly rate for that year.

| End of Year | Samples Archived | Total Stored | Monthly Rate (end of year) | Annual Cost | Cumulative Cost |
|---|---|---|---|---|---|
| 1 | 6 000 | 30 TB | ~€50 | ~€300 | **~€300** |
| 2 | 12 000 | 60 TB | ~€100 | ~€900 | **~€1 200** |
| 3 | 18 000 | 90 TB | ~€150 | ~€1 500 | **~€2 700** |
| 4 | 24 000 | 120 TB | ~€200 | ~€2 100 | **~€4 800** |
| 5 | 30 000 | 150 TB | ~€250 | ~€2 700 | **~€7 500** |
| 6 | 36 000 | 180 TB | ~€300 | ~€3 300 | **~€10 800** |
| 7 | 42 000 | 210 TB | ~€350 | ~€3 900 | **~€14 700** |
| 8 | 48 000 | 240 TB | ~€400 | ~€4 500 | **~€19 200** |
| 9 | 54 000 | 270 TB | ~€450 | ~€5 100 | **~€24 300** |
| 10 | 60 000 | 300 TB | ~€500 | ~€5 700 | **~€30 000** |

> **Region:** OVH Cold Archive is only available in `PAR` (Paris), **not** in GRA9. S3 objects must be moved/written to a PAR bucket. Cross-region writes from GRA9 are free (ingress included); retrieval is charged at **€0.009/GiB**.

> **Minimum storage:** Cold Archive has a **180-day minimum** storage commitment per object. Deleting earlier triggers a charge for the remaining days at the cold archive rate.

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
- **S3 data lifecycle:** Enable OVH S3 lifecycle policies to auto-expire all intermediate files after analysis. Archive only final results (5 GB / sample) to the **Cold Archive** class in PAR (~€0.008/sample/month). Keeping the full 50 GB scratch data in Standard S3 would add ~€0.36/sample/month — a 45× overhead vs. cold-archiving results only.
- **Egress is free:** Downloading analysis results (BAM, VCF, etc.) from S3 to your institution does not incur OVH charges in GRA.
- **MPR plan selection:** The S plan (200 GB, ~€17.30 / month) is the dominant baseline cost item. It is flat-rate regardless of usage. If the image catalog stays small, this is sufficient; there is no pay-per-pull model.
- **Block Storage cleanup:** Cinder volumes are high speed, LUKS-encrypted and auto-cleaned by Funnel after task completion. Verify cleanup is working to avoid orphaned volumes accumulating cost (High Speed Gen2: €0.000119/GiB/hr).
- **Savings Plans:** OVHcloud offers Savings Plans for predictable workloads (1–36 month commitment). The `d2-4` Savings Plan rate (1-month) is €0.0206/hr — a marginal saving over on-demand for a node running continuously.
