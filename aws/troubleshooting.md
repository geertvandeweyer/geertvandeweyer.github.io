---
layout: default
title: "AWS Deployment Troubleshooting"
description: "Common AWS EKS, Karpenter, and TES issues and solutions"
permalink: /aws/troubleshooting/
---

# AWS Deployment Troubleshooting

**Comprehensive guide to diagnosing and fixing AWS EKS, Karpenter, and TES issues**

---

## Quick Diagnostics

### 1. Check EKS Cluster Status

```bash
# Cluster health
aws eks describe-cluster --name TES --query 'cluster.status'
# Expected: ACTIVE

# Node status
kubectl get nodes -o wide
# Expected: All nodes READY

# Pod status
kubectl get pods -A --sort-by=.metadata.creationTimestamp
# Expected: No CrashLoopBackOff or Pending >5 minutes
```

### 2. Check Karpenter

```bash
# Karpenter deployment
kubectl get deployment -n karpenter

# Recent logs
kubectl logs -n karpenter deployment/karpenter --tail=100

# NodePool status
kubectl get nodepool -o wide
kubectl describe nodepool workers

# Nodes provisioned by Karpenter
kubectl get nodes -L karpenter.sh/capacity-type,node.kubernetes.io/instance-type
```

### 3. Check Funnel

```bash
# Funnel pods
kubectl get pods -n tes

# Funnel logs (all pods)
kubectl logs -n tes -l app=funnel --all-containers=true --tail=50

# Service status
kubectl get svc -n tes
kubectl describe svc funnel-service -n tes

# NodePort access
kubectl get svc funnel-service -n tes -o jsonpath='{.spec.ports[0].nodePort}'
# Try: http://<NodeIP>:<NodePort>
```

### 4. Check Cromwell Integration

```bash
# Cromwell metadata
cat ~/cromwell/conf/cromwell.conf | grep -A 20 "tes {"

# TES calls (curl from Cromwell host)
curl -X GET http://<FUNNEL_IP>:<PORT>/v1/tasks

# Workflow logs
tail -100 ~/cromwell/cromwell-workflow-logs/*/execution.log
```

---

## EKS Cluster Issues

### Issue: EKS Cluster Creation Fails (CloudFormation Error)

**Symptoms:**
- `aws eks describe-cluster` returns error
- CloudFormation stack shows CREATE_FAILED

**Diagnosis:**

```bash
# Check CloudFormation stack
aws cloudformation describe-stacks --stack-name TES-stack \
  --query 'Stacks[0].StackStatus'

# Get failure reason
aws cloudformation describe-stack-resources --stack-name TES-stack \
  --query 'StackResources[?ResourceStatus==`CREATE_FAILED`]' | jq .

# Check VPC quotas
aws service-quotas list-service-quotas --service-code vpc \
  --query 'ServiceQuotas[*].{Quota:QuotaName,Used:UsageMetric.MetricValue}'
```

**Common causes & fixes:**

| Cause | Check | Fix |
|-------|-------|-----|
| **VPC quota exceeded** | `service-quotas list-service-quotas --service-code vpc` | Request quota increase or delete old VPCs |
| **IAM permissions missing** | `aws iam list-user-policies --user-name <user>` | Attach AmazonEKSFullAccess policy |
| **Subnet configuration invalid** | `aws ec2 describe-subnets` | Subnets must be in ≥2 different AZs |
| **Route table conflict** | `aws ec2 describe-route-tables` | Delete conflicting routes or use different CIDR |
| **Elastic IP quota** | `aws ec2 describe-addresses` | Delete unused EIPs or request quota increase |

**Recovery steps:**

```bash
# 1. Delete failed stack
aws cloudformation delete-stack --stack-name TES-stack

# 2. Wait for deletion
aws cloudformation wait stack-delete-complete --stack-name TES-stack

# 3. Retry installation
cd ~/VSCode/k8s/AWS_installer/installer
source env.variables
bash install-eks-karpenter.sh
```

---

### Issue: Nodes Not Joining EKS Cluster

**Symptoms:**
```bash
kubectl get nodes
# Returns: No nodes, or nodes show NotReady
```

**Diagnosis:**

```bash
# Check EC2 instances
aws ec2 describe-instances --filters 'Name=tag:karpenter.sh/managed-by,Values=karpenter' \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PrivateIpAddress]'

# Check CloudWatch logs for node
aws logs tail /aws/eks/TES/cluster --follow

# SSH to node and check kubelet
ssh -i <key> ec2-user@<node-ip>
sudo journalctl -u kubelet -n 50
```

**Common causes & fixes:**

| Cause | Check | Fix |
|-------|-------|-----|
| **Security group blocks 443** | `aws ec2 describe-security-groups` | Allow inbound 443 from node to cluster SG |
| **IAM role missing** | `aws iam list-instance-profiles` | Ensure NodeInstanceProfile attached to EC2 instances |
| **CoreDNS not running** | `kubectl get pods -n kube-system` | Delete CoreDNS pod to force restart |
| **Service CIDR conflict** | `aws eks describe-cluster --name TES --query 'cluster.kubernetesNetworkConfig.serviceIpv4Cidr'` | Change serviceIpv4Cidr in EKS cluster |
| **AMI out of date** | Check EC2 launch template | Use latest AL2 AMI from `aws ec2 describe-images` |

**Manual node recovery:**

```bash
# 1. Check node logs
kubectl describe node <node-name>

# 2. Drain if stuck
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# 3. Delete node (Karpenter will replace)
kubectl delete node <node-name>
```

---

## Karpenter Issues

### Issue: Pods Stuck in Pending

**Symptoms:**
```bash
kubectl get pods -o wide
# Shows pod PENDING for >2 minutes
```

**Diagnosis:**

```bash
# Check pod events
kubectl describe pod <pod-name>

# Check Karpenter logs
kubectl logs -n karpenter deployment/karpenter | grep -i pending

# Check for pod constraints
kubectl get pod <pod-name> -o yaml | grep -A 20 affinity
```

**Common causes & fixes:**

| Cause | Solution |
|-------|----------|
| **Insufficient resources** | Check `kubectl top nodes`, scale up limits in NodePool |
| **Pod security policy** | `kubectl auth can-i create pods` |
| **Taints not tolerated** | Add `toleration` to pod spec |
| **Node selector not matching** | `kubectl get nodes --show-labels` |
| **Karpenter not running** | `kubectl get pods -n karpenter` |

**Detailed debugging:**

```bash
# 1. Check Karpenter is provisioning
kubectl logs -n karpenter deployment/karpenter | tail -50

# 2. Check for provisioner errors
kubectl describe nodepool workers

# 3. Check AWS quota status
aws service-quotas list-service-quotas --service-code ec2 \
  --filters 'ServiceCode=ec2' \
  --query 'ServiceQuotas[?QuotaName==`Running On-Demand <instance-type> instances`]'

# 4. Force Karpenter to try again
kubectl delete nodepool workers
kubectl apply -f nodepool.yaml
```

---

### Issue: Nodes Not Scaling Down

**Symptoms:**
```bash
kubectl get nodes
# Shows many nodes even though pods are low
```

**Diagnosis:**

```bash
# Check for daemonsets/system pods
kubectl get pods --all-namespaces -o wide | grep <node-name>

# Check consolidation status
kubectl logs -n karpenter deployment/karpenter | grep -i consolidat

# Check node age
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
AGE:.metadata.creationTimestamp,\
READY:.status.conditions[?(@.type==\"Ready\")].status
```

**Common causes & fixes:**

| Cause | Fix |
|-------|-----|
| **Daemonsets prevent drain** | Karpenter respects this; expected behavior |
| **Long-running pod** | Terminate gracefully or evict with `kubectl delete pod --force` |
| **consolidationPolicy: WhenEmpty** | Change to `WhenUnderutilized` (if defined) |
| **consolidateAfter too long** | Reduce from default 30s if needed |

**Force consolidation:**

```bash
# 1. Check what's blocking
kubectl get pods --all-namespaces -o wide

# 2. Evict long-running tasks
kubectl delete pod <task-pod> --grace-period=120

# 3. Check consolidation happens
kubectl logs -n karpenter deployment/karpenter | grep -i consolidat
```

---

### Issue: Spot Interruptions Too Frequent

**Symptoms:**
- Pods repeatedly terminated and rescheduled
- Funnel tasks fail with "Pod terminated"

**Diagnosis:**

```bash
# Check interruption rate (last 24 hours)
aws ec2 describe-spot-instance-request-history \
  --start-time $(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%S) \
  --query 'SpotInstanceRequestHistory[?EventCode==`instance-terminated-capacity-oversubscribed`]' | wc -l

# Check which instance types are being interrupted
kubectl get nodes -o json | jq '.items[] | select(.metadata.labels["karpenter.sh/capacity-type"]=="spot") | .metadata.labels["node.kubernetes.io/instance-type"]'

# Get Spot pricing history
aws ec2 describe-spot-price-history \
  --instance-types c6g.large c6i.xlarge \
  --product-descriptions "Linux/UNIX" \
  --query 'SpotPriceHistory[*].[Timestamp,SpotPrice,InstanceType]'
```

**Common causes & fixes:**

| Cause | Fix |
|-------|-----|
| **High-demand instance type** | Use less-popular types (c6a, m6a) or switch to on-demand |
| **Capacity oversubscribed** | AWS running low on capacity; use different AZ |
| **Spot interruption rate >5%/day** | Switch to on-demand or reserve instances |

**Solutions:**

```bash
# Option 1: Use more reliable instance types
# Edit NodePool requirements
kubectl patch nodepool workers --type=merge -p '{
  "spec": {
    "template": {
      "spec": {
        "requirements": [
          {
            "key": "node.kubernetes.io/instance-family",
            "operator": "In",
            "values": ["c6a", "m6a"]
          }
        ]
      }
    }
  }
}'

# Option 2: Reduce Spot usage, increase on-demand
# Change capacity-type weights
kubectl patch nodepool workers --type=merge -p '{
  "spec": {
    "template": {
      "spec": {
        "requirements": [
          {
            "key": "karpenter.sh/capacity-type",
            "operator": "In",
            "values": ["on-demand", "spot"]
          }
        ]
      }
    }
  }
}'
```

---

## Funnel / TES Issues

### Issue: Funnel Pod CrashLoopBackOff

**Symptoms:**
```bash
kubectl get pods -n tes
# Shows funnel pods in CrashLoopBackOff
```

**Diagnosis:**

```bash
# Check pod logs
kubectl logs -n tes -l app=funnel --tail=100

# Check pod events
kubectl describe pod -n tes -l app=funnel

# Check ConfigMap
kubectl get configmap -n tes funnel-config -o yaml | head -50

# Check if config is valid YAML
kubectl get configmap -n tes funnel-config -o yaml | yq . > /dev/null
```

**Common causes & fixes:**

| Cause | Error Message | Fix |
|--------|---------------|-----|
| **Invalid config YAML** | `error: YAML parse error` | Validate ConfigMap with `yq` or online validator |
| **Missing AWS credentials** | `AccessDenied` or `NoCredentialProviders` | Check IRSA ServiceAccount annotations |
| **EFS mount failed** | `permission denied` or `No such file` | Verify EFS security group rules |
| **S3 bucket not accessible** | `NoSuchBucket` or `AccessDenied` | Check S3 IRSA policy |
| **Funnel binary crash** | `Segmentation fault` | Update to latest Funnel version |

**Fix ConfigMap:**

```bash
# 1. Extract current config
kubectl get configmap -n tes funnel-config -o yaml > /tmp/funnel-config.yaml

# 2. Edit and validate
nano /tmp/funnel-config.yaml
yq . /tmp/funnel-config.yaml > /dev/null

# 3. Apply
kubectl apply -f /tmp/funnel-config.yaml

# 4. Restart Funnel
kubectl rollout restart deployment/funnel -n tes
```

---

### Issue: Funnel Tasks Fail with "S3 Access Denied"

**Symptoms:**
- Funnel logs: `AccessDenied` on S3 operations
- Task output: `error accessing s3://bucket/path`

**Diagnosis:**

```bash
# Check IRSA annotation
kubectl get sa -n tes funnel-serviceaccount -o yaml | grep -i annotation

# Verify IAM role exists
aws iam get-role --role-name $(kubectl get sa -n tes funnel-serviceaccount \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' | cut -d/ -f2)

# Check IAM policy
aws iam list-attached-role-policies --role-name <role-name> \
  --query 'AttachedPolicies[*].PolicyName'

# Test S3 access from pod
kubectl exec -it -n tes -c funnel <pod-name> -- \
  aws s3 ls s3://bucket/
```

**Common causes & fixes:**

| Cause | Fix |
|-------|-----|
| **IRSA not configured** | Ensure ServiceAccount has `eks.amazonaws.com/role-arn` annotation |
| **IAM policy too restrictive** | Allow `s3:*` on `arn:aws:s3:::bucket/*` and `arn:aws:s3:::bucket` |
| **IAM trust relationship missing** | Add OIDC provider to trust relationship |
| **Pod using wrong ServiceAccount** | Check Deployment spec: `serviceAccountName: funnel-serviceaccount` |
| **S3 bucket encryption key** | If using KMS, allow key operations in IAM policy |

**Fix IRSA:**

```bash
# 1. Get OIDC provider
OIDC_ID=$(aws eks describe-cluster --name TES \
  --query 'cluster.identity.oidc.issuer' | tr -d '"' | cut -d'/' -f5)

# 2. Create trust policy
cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):oidc-provider/oidc.eks.eu-west-2.amazonaws.com/id/$OIDC_ID"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.eu-west-2.amazonaws.com/id/$OIDC_ID:sub": "system:serviceaccount:tes:funnel-serviceaccount"
        }
      }
    }
  ]
}
EOF

# 3. Create IAM role
aws iam create-role --role-name funnel-s3-access \
  --assume-role-policy-document file:///tmp/trust-policy.json

# 4. Attach policy
aws iam attach-role-policy --role-name funnel-s3-access \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

# 5. Annotate ServiceAccount
kubectl annotate serviceaccount -n tes funnel-serviceaccount \
  eks.amazonaws.com/role-arn=arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/funnel-s3-access \
  --overwrite

# 6. Restart pod
kubectl rollout restart deployment/funnel -n tes
```

---

### Issue: Funnel Tasks Fail with "EFS: Permission denied"

**Symptoms:**
- Funnel logs: `permission denied` on EFS mount
- Task execution dir not writable

**Diagnosis:**

```bash
# Check EFS mount
kubectl get pvc -n tes
kubectl describe pvc -n tes

# Check EFS security group
aws ec2 describe-security-groups --filters 'Name=group-name,Values=*efs*' \
  --query 'SecurityGroups[*].IpPermissions'

# Test mount from pod
kubectl exec -it -n tes -c funnel <pod-name> -- \
  touch /var/lib/funnel/test.txt && rm /var/lib/funnel/test.txt
```

**Common causes & fixes:**

| Cause | Fix |
|-------|-----|
| **EFS SG doesn't allow NFS (port 2049)** | Add inbound rule: Protocol NFS (2049) from node SG |
| **EFS mount target down** | Check EFS console; create in affected AZ |
| **EFS bursting exhausted** | Switch to provisioned throughput (cost) or wait 24h |
| **PVC not mounted** | Check pod spec: `volumeMounts` and `volumes` |
| **Wrong IAM permissions** | Ensure EC2 instances have `elasticfilesystem:*` permissions |

**Fix EFS security group:**

```bash
# 1. Get EFS SG
EFS_SG=$(aws efs describe-file-systems --query 'FileSystems[0].Arn' | \
  grep -o 'sg-[a-z0-9]*')

# 2. Get node SG (via CloudFormation)
NODE_SG=$(aws cloudformation describe-stacks --stack-name TES-stack \
  --query 'Stacks[0].Outputs[?OutputKey==`NodeSecurityGroup`].OutputValue' \
  --output text)

# 3. Add NFS rule
aws ec2 authorize-security-group-ingress --group-id $EFS_SG \
  --protocol tcp --port 2049 --source-group $NODE_SG
```

---

### Issue: Cromwell Tasks Fail with TES 500 "task not found"

**Symptoms:**
- Cromwell logs: `HTTP 500: error retrieving task status`
- Funnel logs: `task not found: taskID=...`
- Workflow aborts instead of retrying

**Diagnosis:**

```bash
# Check Cromwell logs
tail -200 ~/cromwell/cromwell-workflow-logs/*/execution.log | grep -A5 "task not found"

# Identify task ID
grep -o "taskID=[a-z0-9-]*" ~/cromwell/cromwell-workflow-logs/*/execution.log | head -5

# Query Funnel for task
curl -s http://<FUNNEL_IP>:<PORT>/v1/tasks/<TASK_ID> | jq .

# Check Funnel task list
curl -s http://<FUNNEL_IP>:<PORT>/v1/tasks | jq '.tasks[0]'
```

**Root cause:**

This is a **known issue** in Cromwell's TES integration (documented in TODO.md):
- Cromwell submits task to Funnel (TES)
- Funnel returns task ID
- Cromwell polls for status
- If task takes >30s to appear in Funnel's database, Cromwell query returns 404
- Cromwell treats 404 as fatal (not retryable)
- Workflow aborts

**Workarounds:**

1. **Increase Funnel database commit interval** (reduces 404 window):
   ```yaml
   # In ConfigMap
   fastapiRoot: "/v1"
   logger:
     format: "json"
   database:
     # Commit interval (milliseconds)
     # Lower = more frequent commits = lower 404 risk
     # Default: 1000ms
     updateInterval: 500  # 500ms instead
   ```

2. **Increase Cromwell TES polling timeout:**
   ```groovy
   // In cromwell.conf
   backend {
     providers {
       TES {
         actor-factory = "cromwell.backend.impl.tes.TesBackendLifecycleActorFactory"
         config {
           root = "/var/lib/tes"
           
           // Add timeout settings
           tes {
             root = "/var/lib/tes"
             tesEndpoint = "http://funnel-service:8000"
             
             // Wait longer before failing
             requestTimeout = 300  // seconds (increased from 60)
           }
         }
       }
     }
   }
   ```

3. **Implement retry logic** (Cromwell 60+):
   ```groovy
   call myTask
   catch {
     call myTask  // Retry
   }
   ```

**Permanent fix:**

This requires **Cromwell code change** in `TesAsyncBackendJobExecutionActor`:
```scala
// Before (fatal):
case Some(failed: GetTaskStatusResponse) if failed.status == "SYSTEM_ERROR" =>
  throw new Exception(s"Task failed: ${failed.result.failureMessage}")

// After (retryable):
case None =>  // Task not found
  // Return transient failure, not fatal
  sendReply(JobStatus(backendJobId, JobStatus.Failed, ..., isTransient=true))
```

---

## Network & Connectivity Issues

### Issue: Cannot Connect to Funnel Service

**Symptoms:**
```bash
curl http://funnel-service:8000/v1/tasks
# Connection refused or timeout
```

**Diagnosis:**

```bash
# Check service exists
kubectl get svc -n tes funnel-service

# Check endpoints
kubectl get endpoints -n tes funnel-service

# Check pod is running
kubectl get pods -n tes -l app=funnel

# Check service port
kubectl get svc -n tes funnel-service -o yaml | grep -A 5 ports

# Try connecting from pod
kubectl run -it --rm debug --image=alpine --restart=Never -- \
  wget -O- http://funnel-service:8000/v1/tasks
```

**Common causes & fixes:**

| Cause | Fix |
|-------|-----|
| **Service selector mismatch** | Check labels: `kubectl get pods --show-labels` |
| **No endpoints** | Restart pod: `kubectl rollout restart deployment/funnel` |
| **Firewall/SG blocks port** | Allow 8000 from Cromwell host |
| **Service not exposing port** | Check `spec.ports` in Service definition |

---

### Issue: Cromwell Cannot Connect to Funnel (External)

**Symptoms:**
- Cromwell logs: `connection refused` or `timeout` to Funnel TES endpoint
- Funnel service is running in cluster

**Diagnosis:**

```bash
# Get Funnel endpoint
FUNNEL_IP=$(kubectl get svc -n tes funnel-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
FUNNEL_PORT=$(kubectl get svc -n tes funnel-service -o jsonpath='{.spec.ports[0].nodePort}')

# Try from Cromwell host
curl http://$FUNNEL_IP:$FUNNEL_PORT/v1/tasks

# Check SecurityGroup allows traffic
aws ec2 describe-security-groups --group-ids <sg-id> \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==8000]'

# Check if ALB is configured
kubectl get ingress -n tes
```

**Common causes & fixes:**

| Cause | Fix |
|-------|-----|
| **NodePort not exposed** | Service type should be `NodePort` or `LoadBalancer` |
| **Security group blocks 8000** | Add inbound rule 8000 from Cromwell host |
| **ALB not routing** | Check Ingress rules and annotations |
| **Pod not listening on 0.0.0.0:8000** | Check Funnel config: `listenAddress: "0.0.0.0:8000"` |

**Enable ALB ingress:**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: funnel-ingress
  namespace: tes
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
    - host: funnel.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: funnel-service
                port:
                  number: 8000
```

---

## Performance Issues

### Issue: Tasks Complete Slowly

**Symptoms:**
- Funnel tasks take 2–5x longer than local execution
- High CPU/memory on node

**Diagnosis:**

```bash
# Check node resource usage
kubectl top nodes

# Check pod resource usage
kubectl top pods -n tes

# Check EFS performance
kubectl exec -it -n tes -c funnel <pod-name> -- \
  time dd if=/dev/zero bs=1M count=100 of=/var/lib/funnel/test.bin && \
  rm /var/lib/funnel/test.bin

# Check network bandwidth (worker↔EFS)
kubectl exec -it -n tes -c funnel <pod-name> -- \
  iftop -n -s 5
```

**Common causes & fixes:**

| Cause | Fix |
|-------|-----|
| **EFS burst credit exhausted** | Use provisioned throughput (cost $) or wait 24h |
| **Instance type too small** | Increase from c6g.large to c6g.xlarge |
| **Lots of small reads/writes** | Use local /tmp for intermediate files, copy to EFS at end |
| **Network latency (multi-AZ)** | Place nodes and EFS in same AZ |

---

## Related Documentation

- **[Installation Guide](/aws/installation-guide/)** — EKS setup
- **[Karpenter Guide](/karpenter/cloud-providers/aws/)** — Autoscaling configuration
- **[Cost & Capacity](/aws/cost-and-capacity/)** — Budget planning
- **[AWS EKS Documentation](https://docs.aws.amazon.com/eks/)** — Official AWS docs

---

**Last Updated**: March 13, 2026  
**Version**: 1.0
