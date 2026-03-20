---
layout: default
title: Pull Requests
permalink: /pull-requests/
---

# Upstream Pull Requests

This page documents pending pull requests to upstream repositories with functionality developed in this deployment.

---

## 1. karpenter-provider-ovhcloud

**Status**: PR submitted : [PR #1](https://github.com/antonin-a/karpenter-provider-ovhcloud/pull/1)  
**Branch**: `main` (4 commits)  
**Target**: `antonin-a/karpenter-provider-ovhcloud:main`

### Summary

Introduces Karpenter label patching controller and fixes for drift detection, pool creation, API parsing, and node tracking on OVH MKS. 

### Key Features & Fixes

#### New: Node Labels Controller
  - **Problem**: Karpenter requires standard Kubernetes labels on nodes (capacity, architecture, zone) but OVH nodes don't have them initially
  - **Solution**: Dedicated controller watches for node registration and applies required labels from matching NodeClaim
  - **Benefit**: Closes race window where Karpenter's drift controller fires within seconds of node joining

#### Fix: Drift Detection in Create()
  - Ensure labels are added to nodes during `Create()` method, not deferred
  - Convert flavor UUIDs to human-readable names for Karpenter compatibility

#### Fix: Single-Zone Cluster Pool Creation
  - Retry node pool creation without `availabilityZones` parameter on single-zone clusters
  - Prevents API 400 errors when zone parameter is not applicable

#### Fix: RAM API Response Parsing
  - OVH API returns RAM in GiB; convert to MiB for Karpenter compatibility

#### Fix: Node Provider-ID Tracking
  - Track individual nodes to prevent duplicate `provider-id` assignment

#### Fix: CRD Template Serialization
  - Remove `omitempty` from all template fields to ensure required fields are present in JSON
  - Add mandatory `finalizers` field to node pool templates


## 2. funnel

**Status**: PR submitted. [PR #1357](https://github.com/ohsu-comp-bio/funnel/pull/1357/)  
**Branch**: `feat/k8s-ovh-improvements` (branched from `develop`)  
**Target**: `ohsu-comp-bio/funnel:develop`

### Summary

Infrastructure, database, server, worker, and Kubernetes backend enhancements.

### Key Features & Fixes

#### Infrastructure (Docker img)
  - Bumped Go base image: `1.23-alpine` → `1.26-alpine`
  - Added `nerdctl` binary for containerd usage
  - Exposed containerd socket and namespace environment variables in final image

#### Database
  - **Problem**: Task insertion and queueing used separate BoltDB write operations, causing lock contention at scale
  - **Solution**: Combine task store and queue writes in single atomic `db.Update` transaction

#### Server
  - Added gRPC keepalive policies for server and gateway clients
  - Retry service config for transient errors (UNAVAILABLE, RESOURCE_EXHAUSTED)

#### Worker
  - **New**: `Resources` struct support with memory limit calculation helper
  - **New**: Volume consolidation algorithm to merge input mounts to common ancestor directory
     - Prevents EBUSY when tasks manipulate input files
     - Reduces mount label overhead

#### Kubernetes Backend: Optional GenericS3
  - **Problem**: GenericS3 (AWS S3 CSI configuration) was mandatory for all PV/PVC creation, blocking non-AWS deployments (OVH, on-premise)
  - **Solution**: 
    - Add nil guards around `config.GenericS3` accesses in `CreatePV` and `CreatePVC`
    - Deployments using hostPath or other non-S3 storage can now omit GenericS3
    - Prevents index-out-of-bounds panic when GenericS3 is empty
  
  
#### Kubernetes Backend: Configurable ConfigMaps
  - **Problem**: Per-task ConfigMaps created unconditionally, causing:
    - Duplicated full config (including credentials) N times in etcd
    - etcd write pressure and API-server churn at scale (1000s of tasks)
    - Leak risk if reconciler/worker crashes before cleanup
  - **Solution**:
    - New `ConfigMapTemplate` field (like existing `ServiceAccountTemplate`, `RoleTemplate`)
    - Default is `""` (disabled) — fully backward compatible
    - Renders template with `{{.TaskId}}`, `{{.Namespace}}`, `{{.Config}}`
    - Only create when template is explicitly configured
  - **Reference**: `config/kubernetes/worker-configmap.yaml`

#### Kubernetes Backend: Template Rendering Fix
  - **Problem**: All seven Kubernetes resource files used `html/template`, which HTML-escapes interpolated values (`"` → `&#34;`, `&` → `&amp;`), corrupting YAML
    - Example: `{{printf "\"%.0fG\"" .RamGb}}` becomes `&#34;` in output, breaking YAML parsing
  - **Solution**: Replace all `html/template` with `text/template` (required by Go docs for non-HTML output)
  


---

## 3. cromwell

**Status**: PR submitted. [PR #7858](https://github.com/broadinstitute/cromwell/pull/7858)  
**Branch**: `ovh-tes-improvements` (branched from working commit)  
**Target**: `broadinstitute/cromwell:develop` (or feature branch)

### Summary

S3/AWS endpoint flexibility, TES backend enhancements (memory retry, local-filesystem support, backoff limits), and logging improvements enabling Cromwell to work efficiently with OVH infrastructure and S3-compatible services.

### Key Features & Fixes

#### Standard Logging
- Downgraded command-line logging from `info` to `debug` in StandardAsyncExecutionActor
- Reduces log verbosity in production

#### S3/AWS Endpoint Support
- **Problem**: Cromwell hardcoded AWS endpoints; S3-compatible services and custom endpoints not supported
- **Solution**:
  - New `aws.endpoint-url` config parameter
  - Propagated through AwsConfiguration, AwsAuthMode, S3 client builder
  - Skip STS validation for non-AWS endpoints
  - Force path-style access for S3-compatible services
  - Custom URI handling in S3PathBuilder/Factory
- **Robustness Fixes**:
  - Ignore errors creating "directory marker" objects
  - Handle empty key (bucket root) specially in `exists()` and `S3Utils`
  - Tolerate 400/403 responses from S3-compatible services when checking existence
  - Miscellaneous path handling tweaks (permissions NPE, `createDirectories()` no-op)
- **Documentation**: Extensive comments explaining non-AWS behavior

#### TES Backend: Memory Retry
- **New Runtime Attribute**: `memory_retry_multiplier`
- Scan stderr and logs for OOM indicators
- Extended `handleExecutionResult()` with memory-specific error handling
- Automatic task retry with increased memory allocation

#### TES Backend: Shared Filesystem Support
- **New Config**: `filesystems.local.local-root` (with legacy `efs` fallback)
- Inputs under configured local root are **not** localized (reduce data movement)
- Custom hashing actor respects mountpoint boundaries
- Sibling-md5 file support for faster hashing
- Constructors and expression functions adjusted for local-filesystem paths

#### TES Backend: Backoff Limit Support
- **New Runtime Attribute**: `backoff_limit`
- Propagated to TES backend_parameters with debug logging
- Prevents excessive retries on permanent failures

#### TES Backend: File Hashing
- **New**: `TesBackendFileHashingActor.scala` with sibling-md5 file support
- Respects local filesystem mountpoints

#### TES Backend: JSON Formatting
- Recursive null-stripping for spray-json
- Corrected `size_bytes` type to `Long` for large files

---

## Deployment Context

These pull requests enable running Cromwell and Funnel on OVH MKS infrastructure with:

- **Node Provisioning**: Karpenter automatically scales workers up/down
- **Storage**: S3-compatible object storage (OVH S3) + local shared filesystems
- **Workload Execution**: TES backend for Cromwell, containerized Funnel workers
- **Cost Optimization**: Consolidation of idle nodes, configurable resource limits

See [Karpenter Deployment on OVH MKS](ovh/karpenter-deployment.md) for deployment details.

