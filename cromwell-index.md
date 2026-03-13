---
layout: default
title: "Cromwell"
description: "Workflow Orchestration Engine - Platform-agnostic setup"
permalink: /cromwell/
---

# Cromwell

**Platform-agnostic guide to Cromwell deployment and configuration**

Cromwell is a **workflow orchestration engine** that executes WDL (Workflow Definition Language) and CWL (Common Workflow Language) workflows by breaking them into tasks and submitting them to a Task Execution Service (TES) backend.

---

## 📖 Documentation

### [Configuration](/cromwell/configuration/)
- Backend setup (TES, local, HPC)
- Resource allocation
- Workflow options
- Database configuration

### [Workflows](/cromwell/workflows/)
- Workflow submission
- Task monitoring
- Output retrieval
- Workflow state management

### [TES Integration](/cromwell/tes-integration/)
- Connecting to Funnel TES
- gRPC communication
- Task lifecycle management
- Error handling

### [Troubleshooting](/cromwell/troubleshooting/)
- Common issues
- Debugging workflows
- Log inspection
- Performance tuning

---

## 🚀 Quick Start

### Deploy Cromwell on Kubernetes

```bash
# 1. Create namespace
kubectl create namespace cromwell

# 2. Create ConfigMap with cromwell.conf
kubectl create configmap cromwell-config \
  --from-file=cromwell.conf \
  -n cromwell

# 3. Deploy Cromwell
kubectl apply -f cromwell-deployment.yaml -n cromwell

# 4. Verify
kubectl get pods -n cromwell
kubectl logs -n cromwell deployment/cromwell
```

### Submit a Workflow

```bash
# Port-forward to Cromwell
kubectl port-forward -n cromwell svc/cromwell-service 7900:7900

# Submit workflow
curl -X POST http://localhost:7900/api/workflows/v1 \
  -F workflowSource=@workflow.wdl \
  -F workflowInputs=@inputs.json
```

### Monitor Workflow

```bash
# Get workflow metadata
curl http://localhost:7900/api/workflows/v1/<workflow-id>/metadata

# Get outputs
curl http://localhost:7900/api/workflows/v1/<workflow-id>/outputs
```

---

## 🏗️ Architecture Overview

```
Cromwell Server (port 7900)
├─ HTTP API
├─ Workflow Engine
├─ Task Scheduler
└─ Backend Manager

Backend Selector
├─ TES Backend (Funnel)
│  └─ Submits tasks via gRPC to Funnel TES
├─ Local Backend (for testing)
├─ HPC Backend (SLURM, SGE, etc.)
└─ Multi-backend routing

Funnel TES (external)
├─ Receives task submissions
├─ Creates Kubernetes pods
└─ Reports task status back to Cromwell
```

---

## 🔧 Configuration

### Backend Configuration

```hocon
backend {
  providers {
    TES {
      actor-factory = "cromwell.backend.impl.tes.TesBackendFactory"
      config {
        root = "/cromwell-executions"
        
        tes {
          endpoint = "http://funnel-service:8000"
          timeout = "30 minutes"
        }
        
        filesystems {
          gcs.auth = "application-default"
          s3.auth = "default"
          local.localization = ["hard-link", "soft-link"]
        }
      }
    }
  }
}
```

### Resource Configuration

```wdl
runtime {
  docker: "ubuntu:latest"
  cpu: 2
  memory: "8 GB"
  disks: "100 GB"
}
```

See [Configuration](/cromwell/configuration/) for complete options.

---

## 📊 Component Status

| Component | Status | Purpose |
|-----------|--------|---------|
| **Workflow Engine** | ✅ Running | Parses & executes WDL/CWL |
| **Task Scheduler** | ✅ Running | Submits tasks to backend |
| **TES Integration** | ✅ Running | gRPC communication with Funnel |
| **Database** | ✅ Running | Workflow state persistence |
| **HTTP API** | ✅ Operational | Workflow submission & monitoring |

---

## 🔗 Related Sections

- **[Funnel TES](/tes/)** — Task execution backend
- **[TES Integration](/cromwell/tes-integration/)** — Detailed Cromwell-TES communication
- **[OVH Deployment](/ovh/)** — OVH-specific Cromwell setup
- **[AWS Deployment](/aws/)** — AWS-specific Cromwell setup

---

## 📚 Detailed Guides

1. **[Configuration](/cromwell/configuration/)** — Set up backends & options
2. **[Workflows](/cromwell/workflows/)** — Submit & monitor workflows
3. **[TES Integration](/cromwell/tes-integration/)** — Deep dive into Cromwell-TES
4. **[Troubleshooting](/cromwell/troubleshooting/)** — Fix common issues

---

## 🆘 Quick Troubleshooting

**Cromwell pod not starting?**
```bash
kubectl describe pod -n cromwell <pod-name>
kubectl logs -n cromwell <pod-name>
```

**Workflow submission failing?**
Check [TES Integration](/cromwell/tes-integration/#connection-issues)

**Tasks not executing?**
See [Workflow Troubleshooting](/cromwell/troubleshooting/#task-execution)

---

**Last Updated**: March 13, 2026  
**Version**: 2.0 (Platform-agnostic)
