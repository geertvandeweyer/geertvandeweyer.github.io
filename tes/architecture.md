---
layout: default
title: "TES Architecture"
description: "Funnel TES design patterns and architecture"
permalink: /tes/architecture/
---

# Funnel TES Architecture

**Understanding how Funnel Task Execution Service works**

This guide explains the core architecture of Funnel, how it manages task execution on Kubernetes, and the design patterns used to ensure reliability and scalability.

---

## 🏗️ Component Overview

### Funnel Server

The central control plane running on a master or system node:
- REST API (port 8000): Workflow engines submit tasks here
- gRPC API (port 8001): Efficient task status updates
- Task Manager: Monitors pod lifecycle
- Database: Persists task state and metadata

### DaemonSet Pattern

A **Funnel Disk Setup** DaemonSet runs on every worker node:
- `setup-nfs-host` initContainer: Mounts shared storage on host
- `holder` container: Keeps mount alive with periodic touchfile

### Task Executor

Each Funnel task becomes a Kubernetes Pod:
- initContainer: `wait-for-nfs` (waits for mount readiness)
- container: `funnel-worker-<taskid>` (creates actual task container via nerdctl)
- Runs unprivileged userspace container for isolation

---

## 📦 Storage Architecture (DaemonSet Pattern)

```
DaemonSet funnel-disk-setup (1 per node)
│
├─ initContainer: setup-nfs-host
│  └─ Command: nsenter --mount=/proc/1/ns/mnt -- mount -t nfs ...
│     └─ Mounts NFS on host filesystem at /mnt/shared
│
├─ container: holder
│  └─ Command: while true; do sleep 30; touch /mnt/shared/.keepalive; done
│     └─ Keeps NFS connection alive (prevents timeout)
│
└─ volumes: hostPath /mnt/shared (DirectoryOrCreate)

Task Pod (per WDL task)
│
├─ initContainer: wait-for-nfs
│  └─ Command: until [ -f /mnt/shared/.keepalive ]; do sleep 5; done
│     └─ Waits for DaemonSet to mount NFS
│
├─ container: funnel-worker-<id> (privileged)
│  ├─ volumeMount: /mnt/shared (hostPath, HostToContainer propagation)
│  └─ nerdctl RunCommand: --volume /mnt/shared:/mnt/shared:rw
│     └─ Bind-mounts shared storage into task container
│
└─ nerdctl task container (unprivileged)
   └─ Sees /mnt/shared, can read/write normally
```

### Why This Design?

**Problem**: Soft NFS mounts timeout after idle period (~1-2 minutes)

**Old Solution** (Broken):
- Task Pod mounts NFS when created
- Task completes, NFS remains mounted but idle
- Next task checks mount: it looks OK (VFS entry exists)
- Next task accesses it: TCP timeout → I/O error

**New Solution** (DaemonSet Keepalive):
- Single owner (DaemonSet) mounts NFS on host
- Keepalive loop (`touch` every 30s) prevents idle timeout
- Task pods only consume (no mounting/unmounting)
- Safe for parallel tasks (no race conditions)

---

## 🔄 Task Lifecycle

```
1. Workflow Engine (Cromwell)
   │
   └─> Submit task via gRPC
       curl http://funnel:8000/v1/tasks (POST)
       {
         "name": "task-1",
         "commandLine": ["bash", "-c", "echo hello"],
         "outputs": [...]
       }
       
2. Funnel Server
   │
   ├─> Create Pod manifest
   │   ├─ initContainer: wait-for-nfs
   │   ├─ container: funnel-worker-task-1
   │   └─ volumeMount: /mnt/shared (HostToContainer)
   │
   └─> Submit to Kubernetes API
       kubectl create pod task-1 -n funnel
       
3. Kubernetes Scheduler
   │
   └─> Assign pod to node
       Select worker node with sufficient resources
       
4. Node's kubelet
   │
   ├─> Pull container image
   ├─> Start initContainers
   │   └─ wait-for-nfs waits for DaemonSet mount
   ├─> Start main container
   │   └─ nerdctl launches task container
   └─> Monitor until completion
   
5. Task Execution
   │
   ├─> runCommand: ["bash", "-c", "echo hello"]
   ├─> Mount propagation: HostToContainer picks up host's /mnt/shared
   ├─> Task reads/writes to /mnt/shared
   └─> Task exits (exit code captured)
   
6. Funnel Server
   │
   ├─> Poll pod status every N seconds
   ├─> Capture exit code and logs
   ├─> Mark task COMPLETE/FAILED
   └─> Store result in database
   
7. Workflow Engine
   │
   └─> Query task status via gRPC
       curl http://funnel:8000/v1/tasks/task-id
       Returns: { state: "COMPLETE", outputs: [...] }
```

---

## 🔌 API Endpoints

### REST API (Port 8000)

```bash
# List tasks
GET /v1/tasks

# Create task
POST /v1/tasks
  Body: { "name": "task-1", "commandLine": [...], ... }

# Get task details
GET /v1/tasks/{taskId}

# Get task logs
GET /v1/tasks/{taskId}/logs

# Cancel task
POST /v1/tasks/{taskId}:cancel

# Health check
GET /healthz
```

### gRPC API (Port 8001)

```protobuf
service TaskService {
  rpc CreateTask(Task) returns (CreateTaskResponse);
  rpc GetTask(GetTaskRequest) returns (Task);
  rpc ListTasks(ListTasksRequest) returns (ListTasksResponse);
  rpc CancelTask(CancelTaskRequest) returns (Empty);
  rpc WatchTask(WatchTaskRequest) returns (stream Task);
}
```

---

## 📊 Data Model

### Task Object

```json
{
  "id": "task-abc123",
  "state": "RUNNING",  // QUEUED, INITIALIZING, RUNNING, PAUSED, COMPLETE, EXECUTOR_ERROR, SYSTEM_ERROR
  "name": "alignment-task",
  "commandLine": ["bwa", "mem", "ref.fa", "reads.fq"],
  "inputs": [
    {
      "url": "s3://bucket/ref.fa",
      "path": "/task/ref.fa"
    }
  ],
  "outputs": [
    {
      "url": "s3://bucket/results/out.bam",
      "path": "/task/out.bam"
    }
  ],
  "resources": {
    "cpuCores": 2,
    "ramGb": 8,
    "diskGb": 100
  },
  "logs": [
    {
      "taskId": "task-abc123",
      "stdLog": "Task started...",
      "endTime": "2026-03-13T10:00:00Z"
    }
  ],
  "createdTime": "2026-03-13T09:50:00Z",
  "startTime": "2026-03-13T09:51:00Z",
  "endTime": "2026-03-13T10:00:00Z"
}
```

---

## 🔐 Security Model

### Container Isolation

- **Funnel Worker**: Runs as root (creates containers)
- **Task Container**: Runs as unprivileged user (can't escalate)
- **Storage Access**: Bind-mounted NFS is read/write but isolated

### Volume Access

- Task cannot mount new volumes (unprivileged)
- Task cannot access other pods' volumes
- Cross-pod communication via network only

---

## 📈 Scalability Considerations

### Horizontal Scaling

- Add more worker nodes → Karpenter provisions them
- DaemonSet automatically runs on new nodes
- Task Pod can be scheduled to any available node

### Vertical Scaling

- Increase resource requests/limits on tasks
- Funnel scales to node capabilities
- Karpenter provisions larger instances if needed

### Storage Bottlenecks

- DaemonSet keepalive ensures NFS stability
- All nodes use same shared mount
- Consider storage I/O patterns for large workflows

---

## ⚡ Performance Tuning

### Task Startup Time

```
Total Time = Pod creation (2-5s) + Container pull (5-30s) + Task init (0-10s)
```

Optimize by:
- Pre-pulling container images on nodes
- Using smaller container images
- Parallel task submission

### NFS Performance

Tuned mount options:
```bash
mount -t nfs -o vers=4,soft,timeo=30,retrans=3,_netdev ...
```

- `vers=4`: NFSv4 (modern, efficient)
- `soft`: Soft timeout (better for cloud)
- `timeo=30`: 3-second timeout (with retrans=3)
- `_netdev`: Network device (mount after network ready)

---

## 🔄 Failure Handling

### Soft Mount Timeout

When NFS is idle > 2 minutes (cloud timeout):
- Soft mount returns I/O error
- `retrans=3` retries 3 times
- If still fails, task gets I/O error

**Prevention**: DaemonSet keepalive prevents idle timeout.

### Pod Eviction

If node becomes unavailable:
- kubelet marks pod as pending
- Funnel detects status change
- Marks task as SYSTEM_ERROR
- Workflow engine can retry on another node

### Container Crash

If task container crashes:
- Funnel detects exit code
- Marks task as EXECUTOR_ERROR
- Logs error message
- Workflow engine decides to retry or fail

---

## 🔗 See Also

- [Container Images](/tes/container-images/) — Build & manage images
- [Configuration](/tes/configuration/) — Runtime options
- [Troubleshooting](/tes/troubleshooting/) — Debug issues
- [Cromwell Integration](/cromwell/tes-integration/) — How Cromwell uses TES

---

**Last Updated**: March 13, 2026
