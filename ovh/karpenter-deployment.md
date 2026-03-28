---
layout: default
title: Karpenter on OVH MKS - Deployment
description: "Details of the OVH-Karpenter setup"
permalink: /ovh/karpenter-deployment/
---

# Karpenter Deployment on OVH MKS

## Current Deployment Status (March 18, 2026)

### Cluster Configuration
- **Platform**: OVH Managed Kubernetes Service (MKS) - GRA9 region
- **Kubernetes Version**: v1.31.13
- **Cluster ID**: 926cbcf2-9069-49ee-93ed-2b5ca0dbdfc3

### Node Configuration
- **System Node**: 1 (2 CPU, 2GB RAM, system workloads only)
- **Worker Nodes**: Managed by Karpenter (provisioned on-demand, consolidated when idle)
- **Instance Types**: c3-4, c3-8, c3-16, c3-32, c3-64, b2-*, b3-*, r2-*, r3-*, d2-*

### Karpenter Deployment

#### Image
```
cmgantwerpen/karpenter-provider-ovhcloud:cinder-cleanup
```

#### Version
- **Base**: Karpenter v1.8.2
- **Provider**: OVH fork with local enhancements

#### Key Components
1. **Core Karpenter** - upstream v1.8.2 for provisioning, consolidation, and node lifecycle
2. **OVHcloud Provider** - custom cloud provider adapter
3. **Node Labels Controller** - patches Karpenter-required labels onto OVH nodes
4. **Cinder Volume Cleanup** - ensures volumes are deleted with nodes

### NodePool Configuration

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: workers
spec:
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
    budgets:
      - nodes: 100%
  limits:
    cpu: "32"
    memory: 426Gi
  template:
    metadata:
      labels:
        nodepool: workers
    spec:
      expireAfter: 720h
      nodeClassRef:
        group: karpenter.ovhcloud.sh
        kind: OVHNodeClass
        name: default
```

#### Consolidation Policy
- **Strategy**: `WhenEmptyOrUnderutilized` - consolidate if pod-density is low and no critical workloads block eviction
- **Consolidate After**: 30 seconds (time after which a marked-consolidatable node is eligible for eviction)
- **Disruption Budget**: 100% of nodes can be disrupted simultaneously (no disruption budget limits)

### Operational Features

#### Volume Management
**Problem Solved**: Cinder volumes orphaning on node termination due to timeout and race conditions.

**Solution**: Cinder cleanup moved into Karpenter's `Delete()` method
- Runs in Karpenter pod (stable network, never dies mid-cleanup)
- Uses Nova/Cinder APIs directly for robustness
- Singleflight pattern prevents concurrent duplicate cleanup attempts
- Handles both live instances (via Nova) and dead instances (via Cinder metadata fallback)

**Volume Identification**:
- **Old format**: name prefix `funnel-`
- **New format**: metadata tag `funnel-managed=true`

#### Node Labeling
**Problem**: Karpenter requires Kubernetes-standard labels on nodes (capacity, architecture) but OVH nodes don't have them initially.

**Solution**: Dedicated node labels controller
- Watches for node registration events
- Applies Karpenter-required labels from matching NodeClaim
- Closes race window between node joining and Karpenter's drift controller evaluation

#### DaemonSet Configuration
- **Funnel Disk Setup**: v24
  - `terminationGracePeriodSeconds: 30` (fast shutdown for consolidation)
  - Pod lifecycle hooks removed (cleanup now in Karpenter)
  - Volume metadata tags included for post-termination cleanup

### Known Limitations

1. **Consolidation Enqueue Timing**: 
   - Nodes marked as consolidatable must wait for the full `consolidateAfter` duration
   - Cannot be forced to evict earlier (Karpenter design)

2. **Single-Zone Availability Zones**:
   - Retry logic for single-zone clusters without specifying availabilityZones parameter

3. **Flavor UUID Handling**:
   - Flavor UUIDs converted to human-readable names for Karpenter compatibility

### Testing & Verification

The deployment has been tested with:
- Node provisioning on demand
- Automatic consolidation of idle nodes
- Cinder volume cleanup on node termination
- Pod eviction during node drain
- Multi-zone failover scenarios

### Deployment Artifacts

| Artifact | Location |
|----------|----------|
| Provider Code | `karpenter-provider-ovhcloud` repo |
| Container Image | `cmgantwerpen/karpenter-provider-ovhcloud:cinder-cleanup` |
| Docker Hub | `cmgantwerpen/karpenter-provider-ovhcloud` |
| Karpenter Namespace | `karpenter` |
| NodePool Name | `workers` |
| NodeClass Name | `default` |

### Configuration Files

- **Helm Values**: See OVH installer for Karpenter deployment configuration
- **NodePool Spec**: Part of standard Kubernetes manifests
- **Credentials**: OVH API credentials (Application Key, Secret, Consumer Key) stored in secrets

