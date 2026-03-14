---
layout: default
title: "Quick Reference"
description: "Cheat sheet for common tasks and commands"
permalink: /quick-reference/
---

# Quick Reference Card

## Deployment in 65 Minutes

```
Phase 0: Prep              (5 min)  Prerequisites, credentials
Phase 1: MKS              (15 min)  Cluster creation
Phase 2: Nodepools        (10 min)  System + worker nodes
Phase 3: Manila NFS       (10 min)  Shared storage
Phase 4: S3 Bucket         (5 min)  Object storage
Phase 5: Funnel           (10 min)  TES service
Phase 6: Cromwell          (5 min)  Workflow engine
Phase 7: Smoke Tests       (5 min)  Verification
```

**Total**: ~65 minutes for fresh deployment

---

## Essential Environment Variables

```bash
# OVHcloud
export OVH_REGION="GRA9"
export OVH_APPLICATION_KEY="<your-app-key>"
export OVH_APPLICATION_SECRET="<your-app-secret>"
export OVH_CONSUMER_KEY="<your-consumer-key>"

# Kubernetes
export KUBECONFIG=~/.kube/ovh-tes.yaml

# Workflow
export CROMWELL_URL="http://localhost:7900"
export FUNNEL_URL="http://funnel-service:8000"
export NFS_PATH="/mnt/shared"
```

---

## kubectl Essentials

```bash
# Cluster info
kubectl cluster-info
kubectl get nodes

# Namespaces
kubectl get namespaces
kubectl config set-context --current --namespace=funnel

# Pod management
kubectl get pods -n funnel
kubectl logs -n funnel <pod-name>
kubectl describe pod -n funnel <pod-name>
kubectl exec -it -n funnel <pod-name> -- /bin/bash

# DaemonSet (NFS)
kubectl get daemonset -n funnel
kubectl logs -n funnel ds/funnel-disk-setup
kubectl exec -n funnel ds/funnel-disk-setup -- df -h /mnt/shared

# Deployments
kubectl rollout restart deployment/funnel -n funnel
kubectl get deployment -n funnel
kubectl scale deployment funnel --replicas=2 -n funnel

# Storage
kubectl get storageclass
kubectl get pvc -n funnel
kubectl get pv
```

---

## openstack CLI Essentials

```bash
# Authentication
openstack token issue

# Networks
openstack network list
openstack subnet list
openstack router list

# Security Groups
openstack security group list
openstack security group rule list

# Compute
openstack server list
openstack flavor list
openstack image list

# Storage
openstack volume list
openstack volume type list

# Container (Manila)
openstack share list
openstack share export location list <share-id>
```

---

## S3 CLI Essentials

```bash
# Configure credentials
aws configure --profile ovh

# Bucket operations
aws s3 ls --profile ovh
aws s3 mb s3://my-bucket --profile ovh --endpoint-url https://s3.gra.io.cloud.ovh.net

# File operations
aws s3 cp myfile.txt s3://my-bucket/ --profile ovh --endpoint-url https://s3.gra.io.cloud.ovh.net
aws s3 sync ./local-dir s3://my-bucket/ --profile ovh --endpoint-url https://s3.gra.io.cloud.ovh.net

# List with details
aws s3api list-objects --bucket my-bucket --profile ovh --endpoint-url https://s3.gra.io.cloud.ovh.net
```

---

## Common Task Patterns

### Submit a Workflow

```bash
curl -X POST http://localhost:7900/api/workflows/v1 \
  -F workflowSource=@workflow.wdl \
  -F workflowInputs=@inputs.json \
  -F workflowOptions=@options.json
```

### Check Task Status

```bash
# List all tasks
curl http://funnel-service:8000/v1/tasks | jq '.'

# Get specific task
curl http://funnel-service:8000/v1/tasks/<task-id> | jq '.'

# Monitor logs
kubectl logs -n funnel funnel-worker-<task-id> -c funnel-worker-task -f
```

### Monitor NFS

```bash
# Check mount on all nodes
kubectl exec -n funnel ds/funnel-disk-setup -- mountpoint /mnt/shared

# Check disk usage
kubectl exec -n funnel ds/funnel-disk-setup -- df -h /mnt/shared

# Verify keepalive
kubectl exec -n funnel ds/funnel-disk-setup -- ls -la /mnt/shared/.keepalive
```

### Scale Workers

```bash
# Current Karpenter NodePool
kubectl get nodepools.karpenter.sh

# Scale workers (example)
kubectl scale nodepool workers --replicas=3

# Update resource limits
kubectl patch nodepools.karpenter.sh workers --type merge \
  -p '{"spec":{"limits":{"resources":{"cpu":"100"}}}}'
```

### Restart Services

```bash
# Restart Funnel
kubectl rollout restart deployment/funnel -n funnel

# Restart all pods in namespace
kubectl rollout restart all -n funnel

# Wait for rollout
kubectl rollout status deployment/funnel -n funnel
```

---

## Troubleshooting Commands

### NFS Issues

```bash
# Test mount from pod
kubectl run -it --rm nfs-test --image=busybox -n funnel -- sh -c "mount | grep shared"

# Force unmount stale NFS (on host via node shell)
nsenter --mount=/proc/1/ns/mnt -- umount -f -l /mnt/shared

# Check NFS version
kubectl exec -n funnel ds/funnel-disk-setup -- nfsstat
```

### Network Issues

```bash
# Test DNS resolution
kubectl run -it --rm dns-test --image=busybox -n funnel -- nslookup kubernetes.default

# Test connectivity to S3
kubectl run -it --rm s3-test --image=amazon/aws-cli -n funnel -- \
  aws s3 ls --endpoint-url https://s3.gra.io.cloud.ovh.net

# Check network policies
kubectl get networkpolicy -A
```

### Pod Issues

```bash
# Describe pod for events
kubectl describe pod -n funnel <pod-name>

# Check resource usage
kubectl top nodes
kubectl top pod -n funnel

# View pod events
kubectl get events -n funnel --sort-by='.lastTimestamp'

# Debug pod with shell
kubectl debug pod/<pod-name> -it -n funnel -- /bin/bash
```

### Karpenter Issues

```bash
# Check Karpenter controller logs
kubectl logs -n karpenter deployment/karpenter -f

# View NodePools
kubectl get nodepools -o wide

# Check nodes created by Karpenter
kubectl get nodes -L karpenter.sh/capacity-type

# Karpenter events
kubectl get events -n karpenter --sort-by='.lastTimestamp'
```

---

## Performance Monitoring

### Resource Usage

```bash
# Node resources
kubectl top nodes

# Pod resources
kubectl top pod -n funnel -A

# Describe node capacity
kubectl describe node <node-name> | grep -A 5 "Capacity\|Allocated"
```

### Storage Usage

```bash
# PVC usage
kubectl get pvc -A
kubectl exec -n funnel -- du -sh /mnt/shared/*

# Node disk usage
kubectl exec -n funnel ds/funnel-disk-setup -- df -h
```

### Network Traffic

```bash
# Pod network (if metrics server installed)
kubectl top pod -n funnel --containers

# Live traffic monitoring (requires tcpdump on node)
kubectl debug node/<node-name> -it -- tcpdump -i eth0
```

---

## File Operations

### Copy files to pod

```bash
kubectl cp ./local-file funnel/pod-name:/path/in/pod
```

### Copy files from pod

```bash
kubectl cp funnel/pod-name:/path/in/pod ./local-file
```

### Mount pod volume locally

```bash
kubectl port-forward -n funnel pod/pod-name 8080:8000 &
# Now access pod service at localhost:8080
```

---

## Safe Operational Practices

### Before maintenance

```bash
# Get cluster state snapshot
kubectl get all -A > cluster-snapshot.yaml
kubectl get pvc -A > pvc-snapshot.yaml
kubectl get pv > pv-snapshot.yaml

# Drain a node (graceful)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```

### During maintenance

```bash
# Monitor pod eviction
kubectl get pods -A --field-selector=status.phase=Failed,status.phase=Unknown

# Watch workload redistribution
kubectl get pods -o wide -n funnel --watch
```

### After maintenance

```bash
# Uncordon node
kubectl uncordon <node-name>

# Verify cluster health
kubectl get nodes
kubectl get deployment -n funnel
```

---

## Useful Aliases

```bash
# Add to ~/.bashrc or ~/.zshrc

alias k='kubectl'
alias kgn='kubectl get nodes'
alias kgp='kubectl get pods -n funnel'
alias kgd='kubectl get deployment -n funnel'
alias kl='kubectl logs'
alias kd='kubectl describe'
alias ke='kubectl exec -it'
alias kaf='kubectl apply -f'
alias kdel='kubectl delete'

# Quick namespace switch
alias kfunnel='kubectl config set-context --current --namespace=funnel'
alias ksystem='kubectl config set-context --current --namespace=kube-system'
alias kkarpen='kubectl config set-context --current --namespace=karpenter'
```

---

## Links

- [OVH Installation Guide](/ovh/installation-guide/) — Full 7-phase deployment
- [AWS Installation Guide](/aws/installation-guide/) — Full 7-phase deployment
- [TES Container Images](/tes/container-images/) — Image management (Funnel)
- [Karpenter Guide](/karpenter/) — Auto-scaling with Karpenter
- [OVH CLI Guide](/ovh/cli-guide/) — Advanced CLI commands
- [OVH Cost & Infrastructure](/ovh/cost-and-infrastructure/) — Budgeting & planning

---

**Last Updated**: March 12, 2026
