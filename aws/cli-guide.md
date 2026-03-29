---
layout: default
title: "AWS CLI Guide"
description: "AWS CLI and eksctl commands for managing EKS, EC2, EFS, S3, IAM, and Karpenter."
permalink: /aws/cli-guide/
---

# AWS CLI Guide

Reference for every **AWS CLI** (`aws`) and **eksctl** command used in the
Cromwell + Funnel TES installer and operations scripts.  Each entry documents
the exact syntax, expected output format, and how the installer parses the
result.

> **Conventions used below**
>
> - `<CLUSTER>` — value of `CLUSTER_NAME` from `env.variables`
> - `<REGION>` — value of `AWS_DEFAULT_REGION`
> - `<ACCOUNT>` — AWS account ID (12-digit number)
> - `# parse:` — the exact `--query` + `--output` used by the installer
> - `# output:` — representative JSON response (abbreviated)

---

## Tools

| Tool | Purpose | Install |
|---|---|---|
| `aws` | AWS CLI v2 — all service APIs | [docs](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| `eksctl` | EKS cluster lifecycle | [eksctl.io](https://eksctl.io/installation/) |
| `kubectl` | Kubernetes management | [k8s docs](https://kubernetes.io/docs/tasks/tools/) |
| `helm` | Chart-based deployments | [helm.sh](https://helm.sh/docs/intro/install/) |

---

## `aws sts`

### Get caller identity
```bash
aws sts get-caller-identity
```
- **Output:** `{"UserId":"AIDAEXAMPLE","Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/alice"}`
- **Parse (account ID):** `--query Account --output text` → `123456789012`
- **Used in:** Phase 0 — resolve `AWS_ACCOUNT_ID` when blank in `env.variables`

---

## `aws eks`

### Update kubeconfig
```bash
aws eks update-kubeconfig --name <CLUSTER> --region <REGION>
```
- **Output:** `Updated context arn:aws:eks:<REGION>:<ACCOUNT>:cluster/<CLUSTER> in ~/.kube/config`
- **Note:** Run after cluster creation to point `kubectl` at the new cluster.

### Describe cluster (status)
```bash
aws eks describe-cluster --name <CLUSTER> --region <REGION> \
  --query "cluster.status" --output text
```
- **Output (text):** `ACTIVE`
- **Possible values:** `ACTIVE` | `CREATING` | `UPDATING` | `PENDING` | `DELETING` | `FAILED`
- **Used in:** Phase 2 — wait loop polls until `ACTIVE`

### Describe cluster (endpoint)
```bash
aws eks describe-cluster --name <CLUSTER> --region <REGION> \
  --query "cluster.endpoint" --output text
```
- **Output (text):** `https://ABCD1234.gr7.eu-north-1.eks.amazonaws.com`
- **Used in:** Phase 2 — exported as `CLUSTER_ENDPOINT`

### Describe cluster (VPC ID)
```bash
aws eks describe-cluster --name <CLUSTER> --region <REGION> \
  --query "cluster.resourcesVpcConfig.vpcId" --output text
```
- **Output (text):** `vpc-0abc1234def567890`
- **Used in:** Phase 2 — exported as `VPC_ID` for subnet tagging and EFS

### Describe cluster (OIDC issuer → OIDC ID)
```bash
aws eks describe-cluster --name <CLUSTER> --region <REGION> \
  --query 'cluster.identity.oidc.issuer' --output text \
| cut -d'/' -f5
```
- **Full output (text):** `https://oidc.eks.eu-north-1.amazonaws.com/id/ABCD1234EFGH5678`
- **After `cut -d'/' -f5`:** `ABCD1234EFGH5678`
- **Used in:** Phase 7 — `OIDC_ID` is embedded in the IAM trust policy

### Create EKS addon
```bash
aws eks create-addon \
  --cluster-name <CLUSTER> --region <REGION> \
  --addon-name aws-efs-csi-driver \
  --resolve-conflicts OVERWRITE
```
- **Output:** `{"addon":{"addonName":"aws-efs-csi-driver","status":"CREATING",...}}`
- **Note:** `--resolve-conflicts OVERWRITE` updates config fields if the addon already exists. If the addon is already installed, use `update-addon` instead (the installer tries `create-addon` first and falls back to `update-addon`).

### Describe addon (status poll)
```bash
aws eks describe-addon \
  --cluster-name <CLUSTER> --region <REGION> \
  --addon-name aws-efs-csi-driver \
  --query 'addon.status' --output text
```
- **Output (text):** `ACTIVE`
- **Possible values:** `CREATING` | `ACTIVE` | `UPDATE_IN_PROGRESS` | `DELETING` | `DEGRADED` | `FAILED`
- **Used in:** Phase 5 — wait loop; `DEGRADED` is treated as acceptable (continue).

---

## `eksctl`

### Create cluster from config
```bash
eksctl create cluster -f cluster.yaml
```
- **Output:** Progress lines ending with `EKS cluster "<CLUSTER>" in "<REGION>" region is ready`
- **Duration:** ~10–15 minutes
- **Note:** `cluster.yaml` is rendered from `yamls/cluster.template.yaml` by `envsubst`.
  The config declares the managed nodegroup, OIDC, pod identity associations, and addons.

### Create IRSA service account
```bash
eksctl create iamserviceaccount \
  --cluster <CLUSTER> --region <REGION> \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::<ACCOUNT>:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve
```
- **Output:** CloudFormation stack events, then `created serviceaccount "kube-system/aws-load-balancer-controller"`
- **Note:** `--approve` skips the interactive confirmation prompt.

---

## `aws cloudformation`

### Deploy stack
```bash
aws cloudformation deploy \
  --region <REGION> \
  --stack-name EKS-<CLUSTER> \
  --template-file yamls/eks-cluster-cloudformation.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=<CLUSTER>"
```
- **Output (success):** `Successfully created/updated stack - EKS-<CLUSTER>`
- **Note:** Creates Karpenter IAM policies, the node IAM role, the SQS interruption queue, and EventBridge rules.

### Describe stack status
```bash
aws cloudformation describe-stacks \
  --stack-name EKS-<CLUSTER> \
  --query "Stacks[0].StackStatus" --output text
```
- **Output (text):** `CREATE_COMPLETE`
- **Possible terminal states:** `CREATE_COMPLETE` | `UPDATE_COMPLETE` | `CREATE_FAILED` | `ROLLBACK_COMPLETE` | `ROLLBACK_FAILED`
- **In-progress states:** `CREATE_IN_PROGRESS` | `UPDATE_IN_PROGRESS` | `ROLLBACK_IN_PROGRESS`
- **Used in:** Phase 1 — wait loop polls until `CREATE_COMPLETE` or `UPDATE_COMPLETE`

---

## `aws iam`

### Get role (existence check)
```bash
aws iam get-role --role-name <ROLE_NAME>
```
- **Output:** `{"Role":{"RoleName":"...","Arn":"arn:aws:iam::<ACCOUNT>:role/<ROLE_NAME>",...}}`
- **Exit code:** `0` if role exists, `254` if not found (`NoSuchEntity`)
- **Used in:** Phase 7 — skip role creation if it already exists

### Create role
```bash
aws iam create-role \
  --role-name <ROLE_NAME> \
  --assume-role-policy-document file://tmp/tes-trust-policy.json
```
- **Output:** `{"Role":{"RoleName":"...","Arn":"arn:aws:iam::<ACCOUNT>:role/TES-iam-role",...}}`
- **Note:** Trust policy is rendered from `policies/iam-trust-policy.template.json` using `envsubst`.

### Put inline role policy (idempotent)
```bash
aws iam put-role-policy \
  --role-name <ROLE_NAME> \
  --policy-name <POLICY_NAME> \
  --policy-document file://policies/EBSAutoscaleAndArtifactsPolicy.json
```
- **Output:** (empty on success)
- **Note:** Overwrites any existing inline policy with the same name — fully idempotent.
- **Used in:** Phase 3 (EBS + EFS policies on `KarpenterNodeRole-<CLUSTER>`), Phase 7 (S3 policy on TES role)

### Create managed policy
```bash
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://policies/AWSLoadBalancerControllerIAMPolicy.json \
  --query 'Policy.Arn' --output text
```
- **Output (text):** `arn:aws:iam::<ACCOUNT>:policy/AWSLoadBalancerControllerIAMPolicy`
- **Exit code:** Non-zero (and empty output) if the policy already exists.
- **Used in:** Phase 6 — installer falls back to `list-policies` to get the ARN if `create-policy` fails.

### List managed policies (fetch ARN of existing policy)
```bash
aws iam list-policies \
  --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].Arn" \
  --output text
```
- **Output (text):** `arn:aws:iam::<ACCOUNT>:policy/AWSLoadBalancerControllerIAMPolicy`
- **Note:** Returns `None` (literal string) if no policy matches. Always check for empty result.

### List attached role policies
```bash
aws iam list-attached-role-policies \
  --role-name <CLUSTER>-karpenter \
  --query "AttachedPolicies[].PolicyArn" --output text
```
- **Output (text):** Space-separated list of ARNs, one per line
- **Used in:** Phase 4 — verify five required Karpenter controller policies are attached

### Attach managed policy to role
```bash
aws iam attach-role-policy \
  --role-name <ROLE_NAME> \
  --policy-arn arn:aws:iam::<ACCOUNT>:policy/<POLICY_NAME>
```
- **Output:** (empty on success)

---

## `aws ec2`

### Describe subnets in a VPC
```bash
aws ec2 describe-subnets \
  --region <REGION> \
  --filters "Name=vpc-id,Values=<VPC_ID>" \
  --query 'Subnets[].SubnetId' --output text
```
- **Output (text):** `subnet-aaa subnet-bbb subnet-ccc` (space-separated)
- **Used in:** Phase 4 — subnet tagging loop; Phase 5 — EFS mount target creation

### Describe private subnets (no public IP)
```bash
aws ec2 describe-subnets \
  --region <REGION> \
  --filters "Name=vpc-id,Values=<VPC_ID>" "Name=map-public-ip-on-launch,Values=false" \
  --query 'Subnets[].[SubnetId]' --output text
```
- **Output (text):** One subnet ID per line
- **Note:** `[SubnetId]` (array projection) returns one column per row with `--output text`.
- **Used in:** Phase 5 — create EFS mount targets only in private subnets

### Check tag existence on a resource
```bash
aws ec2 describe-tags \
  --region <REGION> \
  --filters "Name=resource-id,Values=<SUBNET_ID>" \
            "Name=key,Values=karpenter.sh/discovery" \
  --query 'Tags | length(@)' --output text
```
- **Output (text):** `0` (not tagged) or `1` (tag exists)
- **Note:** `length(@)` counts matching tag objects. Compare as integer: `[ "$count" -eq 0 ]`
- **Used in:** Phase 4 — skip tagging if tag already exists

### Tag a resource
```bash
aws ec2 create-tags \
  --region <REGION> \
  --resources <SUBNET_ID> \
  --tags Key=karpenter.sh/discovery,Value=<CLUSTER>
```
- **Output:** (empty on success)

### Describe instance types (Spot eligible)
```bash
aws ec2 describe-instance-types \
  --region <REGION> \
  --filters "Name=supported-usage-class,Values=spot" \
  --query "InstanceTypes[*].{Type:InstanceType,VCPU:VCpuInfo.DefaultVCpus,MemoryMiB:MemoryInfo.SizeInMiB}" \
  --output json
```
- **Output (JSON):** `[{"Type":"c5.xlarge","VCPU":4,"MemoryMiB":8192}, ...]`
- **Note:** This endpoint is paginated. `--output json` with a query projection automatically collects all pages.
- **Used in:** `update-nodepool-types.sh` — generates the Karpenter NodePool instance-type list

### Describe security groups (Karpenter-tagged)
```bash
aws ec2 describe-security-groups \
  --region <REGION> \
  --filters "Name=tag:karpenter.sh/discovery,Values=<CLUSTER>" \
  --query 'SecurityGroups[0].GroupId' --output text
```
- **Output (text):** `sg-0abc1234def56789`
- **Note:** Returns `None` (literal) if no matching SG; always check.

### Describe security groups (EKS cluster SG)
```bash
aws ec2 describe-security-groups \
  --region <REGION> \
  --filters "Name=tag:aws:eks:cluster-name,Values=<CLUSTER>" \
            "Name=group-name,Values=eks-cluster-sg-<CLUSTER>-*" \
  --query 'SecurityGroups[0].GroupId' --output text
```
- **Output (text):** `sg-0abc1234def56789` (the EKS cluster SG, shared by the managed nodegroup)

### Create security group
```bash
aws ec2 create-security-group \
  --group-name efs-mount-sg-<CLUSTER> \
  --description "EFS mount targets for <CLUSTER>" \
  --vpc-id <VPC_ID> \
  --region <REGION> \
  --query 'GroupId' --output text
```
- **Output (text):** `sg-0newsg1234`
- **Exit code:** Non-zero if a group with the same name already exists in the VPC. The installer falls back to `describe-security-groups` in this case.

### Authorize inbound rule (NFS from another SG)
```bash
aws ec2 authorize-security-group-ingress \
  --region <REGION> \
  --group-id <MOUNT_SG> \
  --ip-permissions \
  '[{"IpProtocol":"tcp","FromPort":2049,"ToPort":2049,"UserIdGroupPairs":[{"GroupId":"<NODE_SG>"}]}]'
```
- **Output:** (empty on success)
- **Exit code:** Non-zero if the rule already exists — use `|| true` to make idempotent.

---

## `aws efs`

### Create EFS filesystem
```bash
aws efs create-file-system \
  --region <REGION> \
  --creation-token <CLUSTER>-efs \
  --encrypted \
  --tags Key=Name,Value=<CLUSTER>-efs Key=karpenter.sh/discovery,Value=<CLUSTER> \
  --query FileSystemId --output text
```
- **Output (text):** `fs-0abc1234def56789`
- **Note:** `--creation-token` makes this idempotent — a duplicate call returns the existing `FileSystemId` without error.

### Create EFS mount target
```bash
aws efs create-mount-target \
  --file-system-id fs-0abc1234def56789 \
  --subnet-id subnet-aaa \
  --security-groups sg-efs-mount \
  --region <REGION>
```
- **Output:** `{"MountTargetId":"fsmt-...","FileSystemId":"fs-...","SubnetId":"subnet-aaa","LifeCycleState":"creating",...}`
- **Exit code:** Non-zero if a mount target already exists in this subnet — use `|| true`.

---

## `aws s3` / `aws s3api`

### Create bucket
```bash
aws s3 mb s3://<BUCKET> --region <REGION>
```
- **Output:** `make_bucket: <BUCKET>`

### Check bucket existence
```bash
aws s3 ls s3://<BUCKET>
```
- **Exit code:** `0` if bucket exists and is accessible, non-zero otherwise.
- **Used in:** Phase 7 — skip `s3 mb` if bucket already exists.

### Block public access
```bash
aws s3api put-public-access-block \
  --bucket <BUCKET> \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```
- **Output:** (empty on success)

---

## `aws service-quotas`

### Get Standard Spot vCPU quota
```bash
aws service-quotas list-service-quotas \
  --service-code ec2 \
  --region <REGION> \
  --query "Quotas[?QuotaName=='All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests'].Value" \
  --output text
```
- **Output (text):** `100.0` (float as a string — **must be converted to integer**)
- **Convert:** pipe through `awk '{print int($1)}'` → `100`
- **Note:** The quota name must match exactly, including the parenthesised letter list.
- **Used in:** Phase 0 / `update-nodepool-types.sh` — sets `SPOT_QUOTA`; the NodePool cpu limit is set to `SPOT_QUOTA - 2`.

---

## `aws ssm`

### Get recommended EKS AMI ID
```bash
aws ssm get-parameter \
  --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" \
  --region <REGION> \
  --query Parameter.Value --output text
```
- **Output (text):** `ami-0abc1234def56789`
- **Used in:** Phase 0 — resolve the AMI ID, then pass to `ec2 describe-images` to get the version tag.

### Get AMI name (to extract alias version tag)
```bash
aws ec2 describe-images \
  --region <REGION> \
  --image-ids <AMI_ID> \
  --query 'Images[0].Name' --output text \
| sed -r 's/^.*(v[0-9]+).*$/\1/'
```
- **Image name example:** `al2023-ami-2023.6.20260223.0-kernel-6.1-x86_64`
- **After `sed`:** `v20260223`
- **Used in:** Phase 0 — exported as `ALIAS_VERSION` for the EC2NodeClass `amiSelectorTerms`

---

## `helm`

### Log out of public ECR (avoid stale credential errors)
```bash
helm registry logout public.ecr.aws
```
- **Output:** `Removing login credentials for public.ecr.aws`
- **Note:** Run before any `helm upgrade --install` that pulls from `oci://public.ecr.aws/`.

### Install / upgrade Karpenter from public ECR OCI registry
```bash
helm upgrade --install karpenter \
  oci://public.ecr.aws/karpenter/karpenter \
  --version <KARPENTER_VERSION> \
  --namespace kube-system \
  --create-namespace \
  --set settings.clusterName=<CLUSTER> \
  --set settings.interruptionQueue=<CLUSTER> \
  --set replicas=1 \
  --wait --timeout 10m
```
- **Output:** `Release "karpenter" has been upgraded. Happy Helming!`
- **Note:** `oci://` charts require no `helm repo add`. `--wait` blocks until all pods are Ready or timeout.

### Add eks Helm repo and update
```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update
```
- **Output:** `"eks" has been added to your repositories` / `Update Complete.`

### Install AWS Load Balancer Controller
```bash
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 3.0.0 \
  -n kube-system \
  --set clusterName=<CLUSTER> \
  --set serviceAccount.create=false \
  --set region=<REGION> \
  --set vpcId=<VPC_ID> \
  --set serviceAccount.name=aws-load-balancer-controller
```
- **Output:** `Release "aws-load-balancer-controller" has been upgraded.`
- **Note:** The service account must already exist (created by `eksctl create iamserviceaccount`).

---

## `kubectl` (operations used by installer)

### Apply a resource (retry helper)
```bash
kubectl apply -f <file.yaml>
```
- The installer wraps this in `retry_kubectl` with up to 5 retries and 10 s delay.

### Wait for deployment to be Available
```bash
kubectl -n kube-system wait deployment aws-load-balancer-controller \
  --for=condition=Available --timeout=600s
```

### Wait for pods to be Ready (all in namespace)
```bash
kubectl wait --namespace funnel --for=condition=Ready pods --all --timeout=600s
```

### Patch deployment replica count
```bash
kubectl patch deployment efs-csi-controller -n kube-system \
  -p '{"spec":{"replicas":1}}'
```
- **Used in:** Phase 5 — reduces EFS CSI controller to 1 replica to conserve CPU on t4g.medium.

### Annotate a ServiceAccount (IRSA)
```bash
kubectl -n kube-system annotate sa karpenter \
  eks.amazonaws.com/role-arn=arn:aws:iam::<ACCOUNT>:role/<CLUSTER>-karpenter \
  --overwrite
```

### Apply resources server-side (Karpenter CRs)
```bash
kubectl apply --server-side --force-conflicts -f <generated-nodepool.yaml>
```
- **Note:** `--server-side` is required for resources managed by multiple controllers (Karpenter CRDs). `--force-conflicts` prevents errors when field ownership changes between runs.
- **Used in:** `update-nodepool-types.sh`

### Label nodes
```bash
kubectl label nodes -l eksctl.io/nodegroup=<NG> \
  karpenter.io/bootstrap=true workload-type=system --overwrite
```

### Get ingress endpoint (after ALB provisioning)
```bash
kubectl -n funnel get ingress tes-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```
- **Output:** `k8s-funnel-tesingre-abc123.eu-north-1.elb.amazonaws.com`

---

## Resources

- [AWS CLI Command Reference](https://docs.aws.amazon.com/cli/latest/reference/)
- [eksctl Documentation](https://eksctl.io/)
- [EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/)
- [Karpenter Getting Started (AWS)](https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/)
- [AWS EC2 Instance Types](https://aws.amazon.com/ec2/instance-types/)
- [AWS Service Quotas Console](https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas)

