---
layout: default
title: "Karpenter on AWS"
description: "AWS-specific Karpenter configuration and optimization"
permalink: /karpenter/cloud-providers/aws/
---

# Karpenter on AWS

**AWS-specific Karpenter configuration, optimization, and troubleshooting**

---

## Overview

Karpenter on AWS (via EKS) differs significantly from OVH in:
- **Quota model**: Spot/On-Demand quota (not vCPU quota)
- **Instance types**: Hundreds of EC2 instance options
- **Cost optimization**: Spot instances for 70% savings
- **Interruption handling**: Spot termination requires graceful shutdown
- **Scaling speed**: Typically 30-60s for new nodes

---

## AWS NodePool Configuration

### Basic Setup

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: workers
spec:
  template:
    spec:
      requirements:
        # Architecture
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64", "amd64"]
        
        # Instance families (compute-optimized for workflows)
        - key: node.kubernetes.io/instance-family
          operator: In
          values: ["c6g", "c6i", "m6g", "m6i"]
        
        # Capacity type: Spot (cost) vs On-Demand (reliability)
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        
        # No GPU nodes
        - key: karpenter.sh/gpu-count
          operator: In
          values: ["0"]
      
      nodeClassRef:
        name: default
  
  # Hard limits
  limits:
    cpu: 1000
    memory: 4000Gi
  
  # Consolidation: scale down idle nodes
  consolidateAfter: 30s
  consolidationPolicy: WhenEmpty
  
  # Node lifetime: recycle old nodes every 7 days
  expireAfter: 604800s
```

### NodeClass Configuration

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  role: "KarpenterNodeRole"
  
  # EBS configuration
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        iops: 3000
        throughput: 250  # MB/s
        deleteOnTermination: true
        encrypted: true
  
  # Security group (auto-created by CloudFormation)
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: TES
  
  # Subnets (auto-created by CloudFormation)
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: TES
  
  # Tenancy
  tenancy: default
  
  # Tags for cost allocation
  tags:
    Name: "karpenter-worker"
    Cluster: "TES"
    ManagedBy: "Karpenter"
```

---

## AWS vs OVH Differences

| Aspect | AWS | OVH |
|--------|-----|-----|
| **Quota Mechanism** | Spot/On-Demand quota per account | vCPU/RAM quota per project |
| **Quota Enforcement** | HTTP 400 on new SpotRequest | HTTP 412 on new instance |
| **Quota Recovery** | Automatic (quota applies globally) | Manual request increase |
| **Spot Interruption** | AWS terminates nodes (2-min warning) | No equivalent |
| **Instance Selection** | 300+ types, dynamic pricing | ~20 types, fixed pricing |
| **Network** | VPC subnets (managed) | Neutron vRack (manual) |
| **Storage** | EBS (per-node), EFS (shared) | Cinder (per-node), Manila (shared) |
| **Bin-Packing** | Prefers spot (cheaper) + smaller nodes | Largest fitting node |

### Key Implications

**AWS Karpenter strategy:**
1. Prefer Spot instances (70% cheaper) but tolerate interruption
2. Select smaller instance types for faster provisioning
3. Use On-Demand for system services (reliable)
4. Handle Spot termination gracefully

**OVH Karpenter strategy:**
1. Filter instance types to avoid oversized flavors
2. Respect vCPU/RAM quota explicitly
3. Use only On-Demand (no Spot equivalent)
4. Rely on consolidation to manage costs

---

## Instance Type Selection

### Recommended Families for Genomics

```yaml
# Compute-optimized (CPU-heavy bioinformatics)
c6g/c6i:
  - c6g.large    # 2 vCPU, 4 GB (Graviton, ARM)
  - c6g.xlarge   # 4 vCPU, 8 GB
  - c6i.2xlarge  # 8 vCPU, 16 GB (Intel)

# General purpose (balanced)
m6g/m6i:
  - m6g.large    # 2 vCPU, 8 GB (Graviton)
  - m6i.xlarge   # 4 vCPU, 16 GB (Intel)
  - m6i.2xlarge  # 8 vCPU, 32 GB

# Memory-optimized (for large reference files in RAM)
r6g/r6i:
  - r6g.xlarge   # 4 vCPU, 32 GB (Graviton)
  - r6i.2xlarge  # 8 vCPU, 64 GB (Intel)
```

### Avoid

```yaml
# Too small (not cost-effective)
t3.micro, t3.small:
  - High per-vCPU cost
  - Burstable (unpredictable)

# Too large (over-provision)
c6g.4xlarge, m6i.4xlarge:
  - Overkill for most genomics tasks
  - Longer startup time
  - Less flexible bin-packing

# Expensive specialty
p4d, trn1:
  - GPU/TPU (not needed for most workflows)
  - 10x–100x normal cost

# Outdated generations
m5, t2:
  - More expensive than m6i/c6i
  - Slower provisioning
```

### Configuration Example

```yaml
requirements:
  - key: node.kubernetes.io/instance-family
    operator: In
    values: ["c6g", "c6i", "m6g", "m6i"]  # Whitelist good families
  
  - key: node.kubernetes.io/instance-cpu
    operator: Lt
    values: ["16"]  # Don't select >16 vCPU instances
  
  - key: node.kubernetes.io/instance-memory
    operator: Lt
    values: ["65536"]  # Don't select >64 GB instances
```

---

## Spot vs On-Demand Strategy

### Spot Instances (Cost Optimization)

**Pros:**
- 70% cheaper than On-Demand
- Ideal for fault-tolerant workloads
- Automatic bin-packing across AZs

**Cons:**
- 2-minute termination warning
- Not suitable for long-running tasks
- Availability varies by region/type

**Configuration:**
```yaml
requirements:
  - key: karpenter.sh/capacity-type
    operator: In
    values: ["spot", "on-demand"]  # Prefer spot
```

**Pod configuration to tolerate Spot:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: task
spec:
  terminationGracePeriodSeconds: 120  # 2 min shutdown
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: karpenter.sh/capacity-type
                operator: In
                values: ["on-demand"]  # Prefer on-demand for critical tasks
```

### On-Demand Instances (Reliability)

**Use for:**
- System services (Karpenter, Funnel, Cromwell)
- Long-running tasks (>1 hour)
- Guaranteed availability

**Configuration:**
```yaml
# System NodePool (always on-demand)
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
  limits:
    cpu: 50      # Small, stable system
    memory: 200Gi
```

---

## Cost Optimization

### 1. Consolidation (Scale Down Idle Nodes)

```yaml
consolidateAfter: 30s       # Wait 30s before consolidating
consolidationPolicy: WhenEmpty  # Only consolidate when empty
```

**Effect:** Nodes automatically removed 30s after all pods move.

### 2. Spot Instance Preference

```yaml
requirements:
  - key: karpenter.sh/capacity-type
    operator: In
    values: ["spot", "on-demand"]  # Spot first, fallback to On-Demand
```

**Effect:** 70% cost savings on compute nodes.

### 3. Right-Sized Instances

Don't use oversized instances. Example cost per hour:

```
c6g.large   (2 vCPU, 4GB)   — $0.084/hr (Spot) ~ $0.28/hr (On-Demand)
c6g.xlarge  (4 vCPU, 8GB)   — $0.168/hr (Spot) ~ $0.56/hr (On-Demand)
c6i.2xlarge (8 vCPU, 16GB)  — $0.34/hr (Spot) ~ $1.13/hr (On-Demand)

Running 100 tasks:
- c6g.large ×100:    ~$8.40 (spot)
- c6i.2xlarge ×25:   ~$8.50 (spot, over-provisioned)

→ Use smallest fitting instance type
```

### 4. Lifecycle: Expire Old Nodes

```yaml
expireAfter: 604800s  # 7 days
```

Recycles nodes to catch security patches, kernel updates.

### 5. EBS Performance Settings

```yaml
blockDeviceMappings:
  - ebs:
      volumeType: gp3
      iops: 3000          # Baseline (free tier)
      throughput: 250     # 250 MB/s (included in 3000 IOPS)
      # Higher IOPS/throughput = more cost
```

**Pricing:**
- gp3: 3000 IOPS + 125 MB/s = $0.10/volume/month
- Each 100 additional IOPS: +$0.006/month
- Each 1 MB/s above 125: +$0.04/month

---

## AWS Spot Interruption Handling

### How Spot Interruption Works

1. **AWS sends 2-minute warning** via EC2 Instance Metadata Service
2. **Karpenter drains node** (sends SIGTERM to pods)
3. **Workload manager** (Cromwell/job controller) catches signal
4. **Task checkpoints** or fails gracefully
5. **Node terminated** after 2 minutes

### Enabling Graceful Shutdown

**Funnel task pods:**

```yaml
terminationGracePeriodSeconds: 120  # 2 minutes
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "sleep 5"]  # Allow graceful shutdown
```

**Cromwell jobs:**

```groovy
runtime {
  docker: "my-image:latest"
  cpu: 4
  memory: "8 GB"
  # Cromwell will receive SIGTERM and fail task gracefully
}
```

### Monitoring Interruptions

```bash
# Check node drain events
kubectl get events -n karpenter --sort-by='.lastTimestamp' | grep -i drain

# Check CloudWatch for SpotInstanceInterruption warnings
aws ec2 describe-spot-instance-requests --query \
  'SpotInstanceRequests[?Status.Code==`capacity-oversubscribed`]'
```

---

## Troubleshooting

### Issue: Nodes Not Scaling Up

**Diagnosis:**
```bash
kubectl describe nodepool workers
kubectl logs -n karpenter deployment/karpenter | tail -50
```

**Common causes:**

| Cause | Check | Fix |
|-------|-------|-----|
| Spot quota exhausted | `aws service-quotas list-service-quotas --service-code ec2` | Request quota increase or use on-demand |
| On-Demand quota exhausted | Same as above | Request quota increase |
| Pod security policy | `kubectl get psp` | Adjust PSP or use Pod Security Standards |
| Subnet capacity | `aws ec2 describe-subnets` | Add more subnets or expand CIDR |
| Instance type unavailable | `aws ec2 describe-spot-price-history` | Switch to different instance family |

### Issue: Spot Interruption Too Frequent

**Check interruption rate:**
```bash
aws ec2 describe-spot-instance-request-history --region us-east-1 \
  --query 'SpotInstanceRequestHistory[?EventCode==`instance-terminated-capacity-oversubscribed`]' | wc -l
```

**Solutions:**
- Switch to less-popular instance types (lower interruption rate)
- Use On-Demand instead of Spot for critical workloads
- Enable Capacity Rebalancing (cost extra but reduces interruption)

### Issue: Slow Node Provisioning

**Target: <1 minute from pod creation to running**

**Check:**
```bash
kubectl get events | grep -i provision
kubectl logs -n karpenter deployment/karpenter | grep -i latency
```

**Improvements:**
- Use smaller instances (faster to provision)
- Warm node pool (pre-provision standby nodes)
- Switch to Spot (typically faster than On-Demand)

---

## Related Documentation

- **[Installation Guide](/aws/installation-guide/)** — AWS EKS setup
- **[Cost & Capacity](/aws/cost-and-capacity/)** — Budget planning
- **[Troubleshooting](/aws/troubleshooting/)** — Detailed issue resolution
- **[Karpenter Docs](https://karpenter.sh/)** — Official Karpenter documentation
- **[AWS EC2 Pricing](https://aws.amazon.com/ec2/pricing/)** — Pricing calculator

---

**Last Updated**: March 13, 2026  
**Version**: 1.0
