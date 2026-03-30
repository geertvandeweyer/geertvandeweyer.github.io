---
layout: default
title: "Funnel TES — GA4GH Task Execution Service on Kubernetes"
description: "Platform-agnostic guide to deploying Funnel TES (Task Execution Service) on Kubernetes with nerdctl container executor, S3 and EFS storage backends."
keywords:
  - Funnel TES
  - Task Execution Service
  - GA4GH TES
  - Kubernetes
  - nerdctl
  - genomics
  - bioinformatics
permalink: /tes/
---

# Funnel TES (Task Execution Service)

**Platform-agnostic guide to Funnel TES deployment and configuration**

Funnel is a **task execution engine** implementing the [GA4GH TES specification](https://ga4gh.github.io/task-execution-schemas/), allowing Cromwell and other workflow engines to submit and monitor task execution on Kubernetes.

---

## 📖 Documentation

### [Architecture & Design](/tes/architecture/)
- How Funnel works
- DaemonSet pattern for storage
- Container structure & execution
- Design decisions & rationale

### [Container Images](/tes/container-images/)
- Custom-built images (funnel-disk-setup, funnel)
- Forked/maintained images (karpenter-provider-ovhcloud)
- Build procedures & dependencies
- Registry management

### [Configuration](/tes/configuration/)
- Funnel server settings
- Task pod configuration
- Storage backend options
- Resource limits & requests

### [Troubleshooting](/tes/troubleshooting/)
- Common issues & solutions
- Debugging techniques
- Log inspection
- Performance optimization

---

## 🚀 Quick Start

### Deploy Funnel on Kubernetes

```bash
# 1. Create namespace
kubectl create namespace funnel

# 2. Apply Funnel deployment (see /ovh/ or /aws/ for complete examples)
kubectl apply -f funnel-configmap.yaml
kubectl apply -f funnel-deployment.yaml

# 3. Verify
kubectl get pods -n funnel
kubectl logs -n funnel deployment/funnel
```

### Check Status

```bash
# Port-forward to Funnel
kubectl port-forward -n funnel svc/funnel-service 8000:8000

# List tasks
curl http://localhost:8000/v1/tasks

# Check service health
curl http://localhost:8000/healthz
```

---

## 🏗️ Architecture Overview

```
Funnel Service (on system/master node)
├─ REST API (port 8000)
├─ gRPC API (port 8001)
└─ Task Manager (monitors pods)

DaemonSet (on every worker node)
├─ setup-nfs-host (mounts shared storage)
└─ holder (keeps connection alive)

Task Pod (per task, auto-created)
├─ initContainer: wait-for-nfs
├─ container: funnel-worker-<id>
│  └─ runs nerdctl with privileged mode
└─ nerdctl task container
   └─ runs actual workload (non-privileged)
```

---

## 🔧 Configuration

### Funnel Server Settings

Key environment variables:

```bash
PORT=8000                           # REST API port
FUNNEL_LOG_LEVEL=debug              # Logging level
FUNNEL_DB_PATH=/var/lib/funnel      # Task database location
FUNNEL_WORKER_DIR=/mnt/shared       # Shared work directory
```

### Task Pod Settings

Resource requests/limits:

```yaml
resources:
  requests:
    cpu: "2"
    memory: "8Gi"
  limits:
    cpu: "4"
    memory: "16Gi"
```

See [Configuration](/tes/configuration/) for complete options.

---

## 📊 Component Status

| Component | Status | Purpose |
|-----------|--------|---------|
| **Funnel Server** | ✅ Running | REST/gRPC API, task management |
| **Task Executor** | ✅ Running | Pod creation & monitoring |
| **Storage Manager** | ✅ Running | NFS/S3 access, DaemonSet coordination |
| **Metrics** | ✅ Available | Prometheus endpoints |
| **Health Check** | ✅ Operational | `/healthz` endpoint |

---

## 🔗 Related Sections

- **[Cromwell Integration](/cromwell/)** — How Cromwell uses Funnel TES
- **[Karpenter](/karpenter/)** — Auto-scaling for task pods
- **[OVH Deployment](/ovh/)** — OVH-specific Funnel setup
- **[AWS Deployment](/aws/)** — AWS-specific Funnel setup

---

## 📚 Detailed Guides

1. **[Architecture & Design](/tes/architecture/)** — Understand how it works
2. **[Container Images](/tes/container-images/)** — Build & manage images
3. **[Configuration](/tes/configuration/)** — Tune for your workloads
4. **[Troubleshooting](/tes/troubleshooting/)** — Fix common issues

---

## 🆘 Quick Troubleshooting

**Funnel pod not starting?**
```bash
kubectl describe pod -n funnel <pod-name>
kubectl logs -n funnel <pod-name>
```

**Tasks failing with I/O error?**
See [NFS Troubleshooting](/tes/troubleshooting/#nfs-issues)

**Tasks slow to start?**
Check [Resource Configuration](/tes/configuration/#resource-settings)

---

**Last Updated**: March 13, 2026  
**Version**: 2.0 (Platform-agnostic)
