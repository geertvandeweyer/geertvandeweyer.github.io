---
layout: default
title: "AWS Cost & Capacity Planning"
description: "Cost estimation, optimization, and capacity planning for AWS TES deployment"
permalink: /aws/cost-and-capacity/
---

# AWS Cost & Capacity Planning

**Comprehensive budget planning and cost optimization for AWS EKS TES deployment**

---

## Monthly Cost Breakdown

### Base Scenario: 1000 Genomics Tasks (2-Hour Average)

**Assumptions:**
- Average task duration: 2 hours
- Average task size: 4 vCPU, 8 GB RAM
- 1000 tasks/month
- Total compute: 2000 vCPU-hours/month
- 70% Spot, 30% On-Demand mix

### Cost Breakdown

| Component | Unit Cost | Usage | Monthly Cost |
|-----------|-----------|-------|--------------|
| **EKS Control Plane** | $0.10 | 1 cluster | $0.10 |
| **EC2 On-Demand** | $0.28/hr (c6g.large) | 600 vCPU-hrs ÷ 2 = 300 hrs | $84 |
| **EC2 Spot** | $0.084/hr (c6g.large) | 1400 vCPU-hrs ÷ 2 = 700 hrs | $58.80 |
| **EBS Storage** | $0.10/volume + $0.000417/IOPS-month | 40 nodes × $0.10 + IOPS | $10 |
| **EFS Storage** | $0.30/GB-month | 100 GB | $30 |
| **S3 Storage** | $0.023/GB-month | 500 GB | $11.50 |
| **S3 Requests** | $0.0004/1000 GET | 1M requests | $0.40 |
| **Data Transfer Out** | $0.02/GB | 100 GB | $2 |
| **ALB** | $18.25 + $0.006/LB-hour | 1 LB (optional) | ~$22 (optional) |
| | | **TOTAL (with ALB)** | **~$218** |
| | | **TOTAL (without ALB)** | **~$196** |

---

## Cost Scenarios

### Scenario 1: Small Lab (200 Tasks/Month)

```
Compute: 400 vCPU-hours
  - 120 vCPU-hrs on-demand  × $0.28 = $33.60
  - 280 vCPU-hrs spot       × $0.084 = $23.52

Storage: 50 GB EFS, 200 GB S3
  - EFS: 50 × $0.30 = $15
  - S3:  200 × $0.023 = $4.60

Infrastructure:
  - EKS: $0.10
  - EBS: $5
  - Requests: <$1

TOTAL: ~$83/month
```

**Use case:** Testing, development, pilot studies

**Cost breakdown:**
- Compute: 65%
- Storage: 25%
- Infrastructure: 10%

---

### Scenario 2: Medium Production (1000 Tasks/Month)

```
Compute: 2000 vCPU-hours
  - 600 vCPU-hrs on-demand  × $0.28 = $168
  - 1400 vCPU-hrs spot      × $0.084 = $117.60

Storage: 100 GB EFS, 500 GB S3
  - EFS: 100 × $0.30 = $30
  - S3:  500 × $0.023 = $11.50

Infrastructure:
  - EKS: $0.10
  - EBS: $10
  - Requests: $0.50

TOTAL: ~$337/month
```

**Use case:** Standard genomics analysis, daily workflows

**Cost breakdown:**
- Compute: 85%
- Storage: 12%
- Infrastructure: 3%

---

### Scenario 3: High-Volume Production (5000 Tasks/Month)

```
Compute: 10000 vCPU-hours
  - 3000 vCPU-hrs on-demand × $0.28 = $840
  - 7000 vCPU-hrs spot      × $0.084 = $588

Storage: 500 GB EFS, 2 TB S3
  - EFS: 500 × $0.30 = $150
  - S3:  2000 × $0.023 = $46

Infrastructure:
  - EKS: $0.10
  - EBS: $30
  - Requests: $2
  - ALB: $22

TOTAL: ~$1,679/month
```

**Use case:** Large-scale research, production genomics platform

**Cost breakdown:**
- Compute: 85%
- Storage: 12%
- Infrastructure: 3%

---

## Cost Optimization

### 1. Maximize Spot Usage

**Strategy:** Use Spot for fault-tolerant tasks, keep on-demand for critical workloads

**Savings:**
- Spot instances: 70% cheaper than on-demand
- Mix 70% Spot / 30% On-Demand → **40% overall compute savings**

**Implementation:**

```yaml
# In Cromwell runtime block
runtime {
  docker: "my-image:latest"
  cpu: 4
  memory: "8 GB"
  
  # For fault-tolerant tasks (most genomics)
  zones: ["spot"]  # Or allow both: ["spot", "on-demand"]
}
```

**Cost impact:**
- 2000 vCPU-hours at 70% spot: $142.80 vs $560 on-demand
- **Savings: $417/month**

---

### 2. Right-Size Instances

**Don't over-provision instances**

```
✗ Wrong: Running c6g.4xlarge (16 vCPU) for 4-vCPU task
  Cost per task: 16 × $0.28/hr × 2hr = $8.96
  Wasted: 75% of CPU

✓ Correct: Running c6g.large (2 vCPU) for 4-vCPU task with 2 instances
  Cost per task: (2 × 2) × $0.084/hr × 2hr = $0.67 (2 tasks run in parallel)
  Efficiency: 100%
```

**Karpenter auto-sizing:**

```yaml
# Karpenter will select smallest fitting instance
# This naturally right-sizes workloads
requirements:
  - key: node.kubernetes.io/instance-cpu
    operator: Lt
    values: ["16"]  # Don't use >16 vCPU instances
```

**Cost impact:**
- Right-sizing reduces wasted capacity
- **Savings: 15–25% of compute costs**

---

### 3. Consolidate During Off-Hours

**Scale down at night**

```bash
# Cron job to consolidate (0:00 UTC)
0 0 * * * kubectl patch nodepool workers --type=merge -p \
  '{"spec":{"consolidateAfter":"1s"}}' && sleep 300 && \
  kubectl patch nodepool workers --type=merge -p \
  '{"spec":{"consolidateAfter":"30s"}}'
```

**Cost impact:**
- If 30% of tasks run off-hours: 30% consolidation
- **Savings: $15–50/month for small deployments**

---

### 4. Use EFS Provisioned Throughput Instead of Burst

**When to switch:**

| Metric | Burst | Provisioned | Decision |
|--------|-------|-------------|----------|
| **Baseline throughput** | 1–3 MB/s | 1–1000 MB/s | If need >3 MB/s, switch to provisioned |
| **Burst credit usage** | 0 credits/day | N/A | If credits exhausted daily, switch |
| **Cost** | $0.30/GB | $0.30/GB + $0.10/MB/s-month | Provisioned if >330 MB/s sustained |
| **Use case** | Bursty I/O (genomics typical) | Sustained high throughput (big files) | Genomics = burst, keep burst |

**Decision tree:**

```
Do you have sustained 4+ hours of IO per day?
  No  → Use Burst (save $)
  Yes → Check throughput need
    <3 MB/s  → Use Burst
    3–30 MB/s → Use Provisioned (1–10 MB/s level)
    >30 MB/s → Use Provisioned (higher level)
```

**Cost impact:**
- Provisioned throughput: +$0.10/MB/s-month
- 10 MB/s provisioned: +$120/month
- **Only switch if currently bottlenecked by EFS**

---

### 5. S3 Tiering (Long-Term Storage)

**Move old data to cheaper storage classes**

```bash
# After 30 days: move to Standard-IA (infrequent access)
# After 90 days: move to Glacier (rare access)

# Lifecycle policy
aws s3api put-bucket-lifecycle-configuration --bucket tes-data \
  --lifecycle-configuration '{
  "Rules": [
    {
      "Id": "Archive",
      "Status": "Enabled",
      "Transitions": [
        {
          "Days": 30,
          "StorageClass": "STANDARD_IA"
        },
        {
          "Days": 90,
          "StorageClass": "GLACIER"
        }
      ]
    }
  ]
}'
```

**Cost per GB:**
- S3 Standard: $0.023/GB-month
- S3 Standard-IA: $0.0125/GB-month ✅ 46% savings
- S3 Glacier: $0.004/GB-month ✅ 83% savings

**Cost impact:**
- 500 GB data, 50% >30 days, 20% >90 days
- Standard: 500 × $0.023 = $11.50
- With tiering: (250 × $0.023) + (150 × $0.0125) + (100 × $0.004) = $8.60
- **Savings: $2.90/month (26% reduction)**

---

### 6. Reserved Instances (System Node)

**For predictable system workload, use Reserved Instances**

```
System node: 1 × c6g.large (runs Karpenter, Funnel, CoreDNS)
On-Demand: 1 × $0.28/hr × 730 hrs/month = $204/month
1-Year Reserved: ~$140/month = 31% savings
3-Year Reserved: ~$100/month = 51% savings
```

**Implementation:**

```bash
# Purchase 1-year reserved capacity
aws ec2 purchase-reserved-instances-offering \
  --instance-count 1 \
  --instance-type c6g.large \
  --offering-class convertible  # Can change to larger instance later
```

**Cost impact:**
- System node reservation: Save $50–100/month
- **Savings: $600–1200/year**

---

## Capacity Planning

### Quota Limits & Planning

**EC2 Quota to Check:**

```bash
aws service-quotas list-service-quotas --service-code ec2 \
  --query 'ServiceQuotas[?contains(QuotaName, `Running`)]' | \
  jq '.[] | {QuotaName, Value: .Value, Usage: .UsageMetric.MetricValue}'
```

| Instance Type | AWS Default Quota | Min for 100 Tasks | Min for 500 Tasks |
|---|---|---|---|
| c6g/c6i (all sizes) | 5–20 | 10 (5 nodes × 2 vCPU) | 50 (25 nodes × 2 vCPU) |
| Spot c6g/c6i (all sizes) | 5–20 | 10 | 50 |
| On-Demand vCPU | 20–64 | 30 (system + workload) | 50 |
| VPC Elastic IPs | 5 | 2 (ALB + NAT) | 2 |

**Request quota increase (AWS Console):**

1. Go to **Service Quotas**
2. Search for "Running On-Demand [instance-type] instances"
3. Click quota
4. Request quota increase
5. AWS usually approves within 1 hour

---

### Storage Capacity Planning

**EFS Sizing:**

```
Base:     5 GB (OS, configs, logs)
Per task: 2–10 GB (scratch files, intermediate outputs)

Small (200 tasks):   5 + (200 × 2) = 405 GB
Medium (1000 tasks): 5 + (1000 × 2) = 2,005 GB
Large (5000 tasks):  5 + (5000 × 5) = 25,005 GB
```

**S3 Sizing:**

```
Base:        20 GB (configs, logs, archives)
Input data:  V × N (volume per task × num tasks)
Output data: V × N × 0.5 (typically 50% of input size)

Example (500 tasks, 1 GB input/task, 500 MB output/task):
Base:       20 GB
Input:      500 × 1   = 500 GB
Output:     500 × 0.5 = 250 GB
Total:      770 GB

Monthly cost: 770 × $0.023 = $17.70
```

---

### Performance Targets

**Recommended for Genomics:**

| Metric | Small | Medium | Large |
|--------|-------|--------|-------|
| **EFS throughput** | 1–3 MB/s (burst) | 3–10 MB/s | 10–50 MB/s (provisioned) |
| **EBS IOPS per node** | 3000 | 3000 | 5000–10000 |
| **EBS throughput per node** | 125 MB/s | 250 MB/s | 500 MB/s |
| **Spot/On-Demand mix** | 100/0 (all spot, fault-tolerant) | 70/30 | 70/30 or 50/50 (if critical) |

**Tuning AWS EBS:**

```yaml
# In NodeClass
blockDeviceMappings:
  - deviceName: /dev/xvda
    ebs:
      volumeSize: 150Gi        # Larger for large deployments
      volumeType: gp3
      iops: 5000               # For large (default 3000)
      throughput: 500          # For large (default 250)
```

---

## Cost Monitoring

### Set Up CloudWatch Alarms

```bash
# Alert if costs exceed $500/month
aws ce create-cost-category-definition --cost-category-definition \
  'Name=TES-Budget,RuleVersion=CostCategoryExpression.v1,Rules=[{Rule="tes",Value="true"}]'

# Create budget alert
aws budgets create-budget --account-id $(aws sts get-caller-identity --query Account --output text) \
  --budget '{
    "BudgetName": "TES-Monthly",
    "BudgetLimit": {"Amount": "500", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }' \
  --notifications-with-subscribers '[{
    "Notification": {"NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN", "Threshold": 80},
    "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "alerts@example.com"}]
  }]'
```

### Track Monthly Costs

```bash
# Get last 30 days cost breakdown
aws ce get-cost-and-usage \
  --time-period Start=$(date -d '30 days ago' +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[0].Groups[].{Service:Keys[0],Cost:Metrics.UnblendedCost.Amount}'
```

---

## Budget Planning Templates

### Planning Worksheet

```
Monthly task estimate: _________ tasks
Average task duration: _________ hours
Average task size: _________ vCPU, _________ GB RAM

Compute hours (tasks × duration):     _________ vCPU-hours
With 70% spot savings:                _________ $ (compute)

EFS storage (GB):                      _________ GB → $ _______ (at $0.30/GB)
S3 storage (GB):                       _________ GB → $ _______ (at $0.023/GB)

Fixed costs:
  EKS control plane                    $0.10
  EBS volumes (40 nodes × $0.10):      $4
  ALB (optional):                      $22
                                       -------
                          TOTAL/month: $ _______

Safety margin (20%):                   $ _______
BUDGET RECOMMENDATION:                 $ _______
```

### Example Calculations

**100 tasks/month, 1 hour each, 2 vCPU:**

```
Compute hours:     100 tasks × 1 hr × 2 vCPU = 200 vCPU-hours
Compute cost:      200 vCPU-hrs ÷ 2 vCPU/node × $0.28/hr × 70% on-demand factor
                   = (200 ÷ 2) × 0.28 × 0.7 + (200 ÷ 2) × 0.084 × 0.3
                   = $19.60 + $2.52
                   = $22.12

Storage cost:      50 GB EFS × $0.30     = $15
                   100 GB S3 × $0.023    = $2.30

Fixed costs:       $26.10

TOTAL:             $22.12 + $15 + $2.30 + $26.10 = ~$66/month
```

---

## AWS Cost Explorer

### Quick Analysis

```bash
# Start Cost Explorer in AWS Console:
# 1. Go to AWS Cost Management → Cost Explorer
# 2. Select last 30 days
# 3. Group by SERVICE
# 4. Filter by tags: Cluster=TES
# 5. Export to CSV for trend analysis
```

### Advanced: Cost Anomaly Detection

```bash
# Enable anomaly detection (automatic alerts for unexpected costs)
aws ce put-anomaly-monitor --anomaly-monitor '{
  "MonitorName": "TES-Anomalies",
  "MonitorType": "CUSTOM",
  "MonitorDimension": "SERVICE",
  "MonitorSpecification": "{ \"Dimensions\": { \"Key\": \"SERVICE\", \"Values\": [\"Amazon Elastic Kubernetes Service\", \"Amazon Elastic Compute Cloud\"] } }"
}'
```

---

## Related Documentation

- **[Installation Guide](/aws/installation-guide/)** — EKS setup
- **[Karpenter Guide](/karpenter/cloud-providers/aws/)** — Autoscaling
- **[Troubleshooting](/aws/troubleshooting/)** — Debugging issues
- **[AWS Cost Calculator](https://calculator.aws/#/)** — Online estimation tool

---

**Last Updated**: March 13, 2026  
**Version**: 1.0
