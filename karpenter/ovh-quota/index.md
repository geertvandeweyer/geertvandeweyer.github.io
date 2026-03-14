---
layout: default
title: "Karpenter OVH Quota Management"
description: "Preventing 412 InsufficientVCPUsQuota errors on OVHcloud"
permalink: /karpenter/ovh-quota/
---

# Karpenter OVH Quota Management

**How to prevent `412 InsufficientVCPUsQuota` errors and configure Karpenter for OVHcloud**

---

## Overview

On OVHcloud, Karpenter must respect your **project quota** (typically 34–100 vCPU) or it will hit 412 errors. This guide explains the filtering strategy and how to configure it.

---

## The Problem

### Root Cause

OVH Karpenter bin-packs all pending pods onto **as few nodes as possible** to minimize cost. Without restrictions, it selects the **largest available flavor** to fit the most pods:

```
8 pending pods × 4 vCPU each = 32 vCPU total

Karpenter thinks: "I need 32 vCPU. The largest flavor is a10-90 (90 vCPU).
One node will fit everything!"

OVH API responds: "You only have 34 vCPU quota. 90 > 34. Rejected. (412)"

Karpenter retries every 30s, looping forever.
```

### Symptoms

| Symptom | Diagnosis |
|---------|-----------|
| Nodes stuck in `Unknown` status for 5+ min | Check `kubectl describe nodeclaim <name>` for 412 error |
| `InsufficientVCPUsQuota` in event logs | OVH rejected node creation due to quota |
| Event: `NoCompatibleInstanceTypes filtered out all available instance types` | Node pool instance-type list is empty |
| Pending pods never transition to Running | Karpenter can't find valid nodes to provision |

---

## The Solution: Three-Layered Filtering

### Layer 1: Family Filtering (`WORKER_FAMILIES`)

Exclude oversized or specialty flavors:

```bash
# Only compute family (exclude GPU, HPC, memory-optimized)
WORKER_FAMILIES="c3"

# Skip these when scanning OVH API:
# - a10-90 (90 vCPU GPU) ❌
# - b3-256 (256 vCPU HPC) ❌
# - r3-8 (memory-intensive) ❌
# - keep c3-4, c3-8, c3-16, c3-32 ✅
```

### Layer 2: Per-Flavor Caps (`WORKER_MAX_VCPU`, `WORKER_MAX_RAM_GB`)

Cap individual flavors to prevent selecting resource hogs:

```bash
WORKER_MAX_VCPU="16"       # Largest node is 16 vCPU (c3-32)
WORKER_MAX_RAM_GB="32"     # Largest node is 32 GB (c3-32)

# Even if c3-32 exists, it's the ceiling.
# c3-4 (2 vCPU), c3-8 (4 vCPU), c3-16 (8 vCPU), c3-32 (16 vCPU) all fit.
# a10-90 (90 vCPU) is filtered out: 90 > 16. ❌
```

### Layer 3: NodePool Limits (`limits.cpu`, `limits.memory`)

Hard cap on total cluster resources:

```yaml
limits:
  cpu: "32"        # Stop provisioning new nodes after 32 vCPU total (quota - 2 for system)
  memory: "426Gi"  # Stop provisioning after 426 Gi total (quota - 4 for system)
```

**How it works**: Karpenter won't create a new node if the total usage **would exceed** these limits.

---

## Configuration

### Step 1: Determine Your OVH Quota

Log in to [OVH Manager](https://www.ovh.com/manager/) → Compute → Quotas

Record:
- **vCPU quota**: Total cores available (e.g., 34)
- **RAM quota**: Total GB available (e.g., 430 GB)
- **Instance limit**: Max number of servers (e.g., 10)

### Step 2: Set env.variables

Edit `/OVH_installer/installer/env.variables`:

```bash
# Your actual OVH quotas
OVH_VCPU_QUOTA="34"          # 1:1 with OVH Manager quota
OVH_RAM_QUOTA_GB="430"       # 1:1 with OVH Manager quota

# Filtering strategy
WORKER_FAMILIES="c3"         # Compute family only
WORKER_MAX_VCPU="16"         # Per-node cap (c3-32 is 16 vCPU)
WORKER_MAX_RAM_GB="32"       # Per-node cap (c3-32 is 32 GB)

# NodePool limits are derived automatically:
# limit_cpu = OVH_VCPU_QUOTA - 2
# limit_mem_gi = OVH_RAM_QUOTA_GB - 4
```

### Step 3: Deploy or Update

**Fresh deployment:**
```bash
cd ./OVH_installer/installer
./install-ovh-mks.sh
# Installer uses env.variables to generate NodePool
```

**Update existing deployment:**
```bash
./update-nodepool-flavors.sh ./env.variables
# Re-fetches flavors, applies new limits
```

### Step 4: Verify

```bash
# Check NodePool instance-type requirement
kubectl get nodepool workers -o yaml | grep -A5 'node.kubernetes.io/instance-type'
# Should list only: c3-4, c3-8, c3-16, c3-32

# Check limits
kubectl get nodepool workers -o yaml | grep -A2 'limits:'
# Should show cpu: "32" (if OVH_VCPU_QUOTA=34)

# Check no pending 412 errors
kubectl describe nodepool workers | grep -A5 'Events:'
```

---

## Troubleshooting

### Issue: "InsufficientVCPUsQuota (412)" in NodeClaim Status

**Diagnosis:**
```bash
kubectl describe nodeclaim <name>
# Message: "...InsufficientVCPUsQuota...Cannot perform operation: current vCPUs quota is insufficient..."
```

**Fix:**
1. Check NodePool instance-type list still includes oversized flavors:
   ```bash
   kubectl get nodepool workers -o yaml | grep -A10 'node.kubernetes.io/instance-type'
   ```
   If it contains non-c3 flavors (e.g., `a10-90`, `b3-256`), re-run update script.

2. Verify `WORKER_MAX_VCPU` is set to a reasonable value:
   ```bash
   grep WORKER_MAX_VCPU ./env.variables
   # Should be 16 or less (c3 family max is 16 = c3-32)
   ```

3. Re-generate NodePool:
   ```bash
   ./update-nodepool-flavors.sh ./env.variables
   kubectl delete nodeclaim <name>  # Force re-evaluation
   ```

### Issue: "NoCompatibleInstanceTypes" Event

**Cause:** Instance-type filtering removed all compatible flavors.

**Fix:**
```bash
# Check what flavors were filtered
./update-nodepool-flavors.sh ./env.variables 2>&1 | grep -E 'Found|ERROR|Including'
# Look for stderr output explaining why flavors were filtered

# Common reasons:
# - WORKER_MAX_VCPU is too small (e.g., 2, but only c3-4 with 2 vCPU exists, but it's filtered out)
# - WORKER_FAMILIES is set to a family not in OVH GRA9 region
# - Network connectivity issue with OVH API
```

### Issue: Nodes Provisioning But Pods Stay Pending

**Cause:** NodePool CPU/memory limits reached.

**Fix:**
```bash
# Current usage
kubectl top nodes
# Check if sum of node capacity approaches NodePool limits.cpu

# Increase quota
# 1. Request higher quota in OVH Manager
# 2. Update env.variables
# 3. ./update-nodepool-flavors.sh ./env.variables
```

### Issue: update-nodepool-flavors.sh Errors

**Common errors:**

| Error | Cause | Fix |
|-------|-------|-----|
| `"No OVH config found"` | OVH credentials not in `~/.ovh.conf` | Set up OVH API token (see [OVH Setup](/ovh/installation-guide/#phase-0-environment-setup)) |
| `"ERROR: no matching flavors found"` | WORKER_FAMILIES value doesn't exist in region | Check spelling (e.g., `c3`, not `c2`); verify region in env.variables |
| `"Exception: Empty flavor mapping"` | OVH API call succeeded but returned no data | Check OVH project ID in `env.variables`; verify API credentials |

---

## Example Configurations

### Minimal Quota (34 vCPU)

```bash
OVH_VCPU_QUOTA="34"
OVH_RAM_QUOTA_GB="430"
WORKER_FAMILIES="c3"
WORKER_MAX_VCPU="8"       # Cap at c3-16 (8 vCPU max per node)
WORKER_MAX_RAM_GB="16"
```

**Result**: NodePool limits = 32 vCPU, 426 Gi memory. Can fit 4 × c3-8 nodes max.

### Medium Quota (100 vCPU)

```bash
OVH_VCPU_QUOTA="100"
OVH_RAM_QUOTA_GB="800"
WORKER_FAMILIES="c3"
WORKER_MAX_VCPU="16"      # Allow up to c3-32
WORKER_MAX_RAM_GB="32"
```

**Result**: NodePool limits = 98 vCPU, 796 Gi memory. Can fit 6 × c3-16 nodes.

### Large Quota (500+ vCPU, Multiple Families)

```bash
OVH_VCPU_QUOTA="500"
OVH_RAM_QUOTA_GB="4000"
WORKER_FAMILIES="c3,b3"   # Compute + balanced
WORKER_MAX_VCPU="32"      # Allow larger nodes
WORKER_MAX_RAM_GB="128"
```

**Result**: NodePool limits = 498 vCPU, 3996 Gi. Can fit 16+ mixed-size nodes.

---

## Key Takeaways

1. **Always set `OVH_VCPU_QUOTA` and `OVH_RAM_QUOTA_GB`** to your actual OVH limits
2. **Restrict `WORKER_FAMILIES` to `"c3"`** unless you specifically need other families
3. **Use `WORKER_MAX_VCPU` and `WORKER_MAX_RAM_GB`** to cap per-flavor selections
4. **NodePool `limits`** are derived automatically; don't edit them manually
5. **Update with `update-nodepool-flavors.sh`** when quota changes, not manual `kubectl edit`

---

## Related

- **[Karpenter Index](/karpenter/)** — General Karpenter documentation
- **[OVH Installation Guide](/ovh/installation-guide/#phase-2-node-pools--autoscaling)** — Full setup instructions
- **[OVH Troubleshooting](/ovh/installation-guide/#troubleshooting)** — More OVH-specific issues

---

**Last Updated**: March 13, 2026  
**Version**: 1.0
