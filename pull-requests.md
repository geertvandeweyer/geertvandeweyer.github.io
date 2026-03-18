---
layout: default
title: Pull Requests
permalink: /pull-requests/
---

# Upstream Pull Requests

This page documents pending pull requests to upstream repositories with functionality developed in this deployment.

---

## 1. karpenter-provider-ovhcloud

**Status**: Ready for PR  
**Branch**: `main` (4 commits ahead of `origin/main`)  
**Target**: `antonin-a/karpenter-provider-ovhcloud:main`

### Summary

Introduces Karpenter label patching controller and fixes for drift detection, pool creation, API parsing, and node tracking on OVH MKS.

### Key Features & Fixes

#### New: Node Labels Controller
- **Problem**: Karpenter requires standard Kubernetes labels on nodes (capacity, architecture, zone) but OVH nodes don't have them initially
- **Solution**: Dedicated controller watches for node registration and applies required labels from matching NodeClaim
- **Benefit**: Closes race window where Karpenter's drift controller fires within seconds of node joining
- **Component**: `pkg/controllers/nodelabels/controller.go`

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

#### CI: Go 1.25.5 Compatibility
- Update CI workflows for Go 1.25.5

### Commits

```
89581989 feat: add nodelabels controller to patch karpenter labels onto OVH nodes
7e4279da fix(drift): add missing labels to Create(); translate flavor UUID in List()
0588a15c fix: retry node pool creation without availabilityZones on single-zone clusters
1d495a70 fix: cluster flavors API returns RAM in GiB, not MiB
```

(Plus 4 earlier commits already in origin/main)

---

## 2. funnel

**Status**: Ready for PR  
**Branch**: `feat/k8s-ovh-improvements` (branched from `develop`)  
**Target**: `ohsu-comp-bio/funnel:develop`

### Summary

Infrastructure, database, server, worker, and Kubernetes backend enhancements enabling Funnel to run efficiently on Kubernetes platforms without cloud-specific infrastructure (AWS S3, EBS), particularly OVH.

### Key Features & Fixes

#### Infrastructure
- Bumped Go base image: `1.23-alpine` → `1.26-alpine`
- Added `nerdctl` binary for containerd usage
- Exposed containerd socket and namespace environment variables in final image

#### Database
- **Problem**: Task insertion and queueing used separate BoltDB write operations, causing lock contention at scale
- **Solution**: Combine task store and queue writes in single atomic `db.Update` transaction
- **Benefit**: Reduced write-lock conflicts under high task load

#### Server
- Added gRPC keepalive policies for server and gateway clients
- Implemented retry service config for transient errors (UNAVAILABLE, RESOURCE_EXHAUSTED)
- Transparent error retry in HTTP gateway

#### Worker
- **New**: `Resources` struct support with memory limit calculation helper
- **New**: Volume consolidation algorithm for read-only inputs
  - Merges read-only input mounts to common ancestor directory
  - Prevents EBUSY when tasks manipulate input files
  - Reduces mount label overhead
- **New**: Path ancestor calculation helpers

#### Kubernetes Backend: Optional GenericS3
- **Problem**: GenericS3 (AWS S3 CSI configuration) was mandatory for all PV/PVC creation, blocking non-AWS deployments (OVH, on-premise)
- **Solution**: 
  - Add nil guards around `config.GenericS3` accesses in `CreatePV` and `CreatePVC`
  - Deployments using hostPath or other non-S3 storage can now omit GenericS3
  - Prevents index-out-of-bounds panic when GenericS3 is empty
- **Root Cause**: Guard conflated file-storage backend config (GenericS3) with PV template requirements; only upstream S3 CSI template actually uses those fields

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
- **Files**: job, pv, pvc, configmap, role, rolebinding, serviceaccount

### Commits

```
c590523e fix(kubernetes): use text/template instead of html/template for YAML rendering
4e06ae98 fix(kubernetes): make per-task ConfigMap creation optional via ConfigMapTemplate
55efca5d fix(kubernetes): make GenericS3 config optional for PV/PVC creation
07ff1e29 feat: port OVH/K8s improvements from main to develop
aef16a88 build: add build-and-push.sh for develop-branch multiarch image
2fa41e0d build: support DOCKERHUB_USER/PASS env vars for non-interactive Docker Hub login
b10877ff fix(kubernetes): skip per-task SA/Role/RoleBinding when templates not configured
```

(Plus 4 earlier commits already in develop)

---

## 3. cromwell

**Status**: Ready for PR  
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

### Commits

```
[Commit 1] standard: lower command-line log level to debug
[Commit 2] s3: add endpoint-url support & compatibility fixes
[Commit 3] tes: add memory-retry, local-root, backoff_limit & improved hashing
```

### Files Modified

| Category | Files |
|----------|-------|
| Standard Logging | `StandardAsyncExecutionActor.scala` |
| S3/AWS Support | `AwsConfiguration.scala`, `AwsAuthMode.scala`, `S3Storage.scala`, `EvenBetterPathMethods.scala`, `S3FileSystemProvider.java`, `S3Utils.java`, `S3PathBuilder.scala`, `S3PathBuilderFactory.scala` |
| TES Backend | `TesAsyncBackendJobExecutionActor.scala`, `TesConfiguration.scala`, `TesExpressionFunctions.scala`, `TesJobCachingActorHelper.scala`, `TesResponseJsonFormatter.scala`, `TesRuntimeAttributes.scala`, `TesTask.scala`, `TesBackendLifecycleActorFactory.scala`, `TesBackendFileHashingActor.scala` |

---

## Deployment Context

These pull requests enable running Cromwell and Funnel on OVH MKS infrastructure with:

- **Node Provisioning**: Karpenter automatically scales workers up/down
- **Storage**: S3-compatible object storage (OVH S3) + local shared filesystems
- **Workload Execution**: TES backend for Cromwell, containerized Funnel workers
- **Cost Optimization**: Consolidation of idle nodes, configurable resource limits

See [Karpenter Deployment on OVH MKS](ovh/karpenter-deployment.md) for deployment details.

