# OVHcloud MKS — CLI & Operations Guide

**Platform**: Cromwell + Funnel TES on OVHcloud Managed Kubernetes (MKS)  
**Project**: CMG_UZA_k8s (`c386d174c0974008bac7b36c4dfafb23`)  
**Region**: GRA9

---

## Table of Contents

1. [Environment Setup](#1-environment-setup)
2. [Cluster Management](#2-cluster-management)
3. [Node Pools](#3-node-pools)
4. [Kubeconfig](#4-kubeconfig)
5. [Manila NFS File Storage](#5-manila-nfs-file-storage)
6. [S3 Object Storage](#6-s3-object-storage)
7. [Disk Auto-Expander](#7-disk-auto-expander)
8. [Cromwell Configuration](#8-cromwell-configuration)
9. [Troubleshooting](#9-troubleshooting)
10. [Quota Reference](#10-quota-reference)
11. [Cost Reference](#11-cost-reference)

---

## 1. Environment Setup

### Activate the `ovh` micromamba environment

All commands require tools from this environment:

```bash
micromamba activate ovh
# or prefix every command with:
micromamba run -n ovh <command>
```

Tools installed: `ovhcloud`, `kubectl`, `helm`, `openstack`, `envsubst`, `jq`

### Authenticate with OVHcloud

```bash
# First-time login — opens browser for OAuth
ovhcloud login

# Verify authentication
ovhcloud cloud project list
```

### Load installer environment variables

```bash
cd OVH_installer/installer
set -a && source env.variables && set +a
```

After sourcing, all `$OVH_PROJECT_ID`, `$KUBE_ID`, etc. are available in the shell.

### OpenStack RC file (required for Manila + Cinder)

Download from the OVH console:  
**Public Cloud → Project → API access → OpenStack users → Download RC file (v3)**

```bash
source ~/openrc-tes-pilot.sh   # prompts for your OVH password
# Verify
openstack token issue
```

### clouds.yaml (alternative to RC file — no password prompt)

Create `~/.config/openstack/clouds.yaml`:

```yaml
clouds:
  ovh-gra9:
    auth:
      auth_url: https://auth.cloud.ovh.net/v3
      username: "user-xxxxxxx"        # from OVH console → OpenStack users
      password: "yourpassword"
      project_id: "c386d174c0974008bac7b36c4dfafb23"
      project_name: "CMG_UZA_k8s"
      user_domain_name: "Default"
    region_name: "GRA9"
    interface: "public"
    identity_api_version: 3
```

```bash
export OS_CLOUD=ovh-gra9
openstack token issue   # verify
```

---

## 2. Cluster Management

```bash
# Create cluster (handled by installer — for reference)
ovhcloud cloud kube create \
  --cloud-project ${OVH_PROJECT_ID} \
  --name tes-pilot \
  --region GRA9 \
  --version 1.31

# List clusters
ovhcloud cloud kube list --cloud-project ${OVH_PROJECT_ID}

# Get cluster status (READY / INSTALLING / REDEPLOYING / ...)
ovhcloud cloud kube get \
  --cloud-project ${OVH_PROJECT_ID} \
  --kube-id ${KUBE_ID} \
  -f status

# Get full cluster info as JSON
ovhcloud cloud kube get \
  --cloud-project ${OVH_PROJECT_ID} \
  --kube-id ${KUBE_ID} \
  --json

# Update Kubernetes version
ovhcloud cloud kube update \
  --cloud-project ${OVH_PROJECT_ID} \
  --kube-id ${KUBE_ID} \
  --version 1.32

# Delete cluster (DESTRUCTIVE — also removes all node pools and VMs)
ovhcloud cloud kube delete \
  --cloud-project ${OVH_PROJECT_ID} \
  --kube-id ${KUBE_ID}
```

---

## 3. Node Pools

### Architecture

The installer creates **one nodepool per flavor** across the configured instance families (`WORKER_FAMILIES`). All worker pools share the label `nodepool=workers`. Cluster Autoscaler picks the cheapest pool that satisfies a pending pod's resource request.

```
system            d2-2    1 vCPU (shared)   2 GB    fixed 1 node   kube-system + Funnel server
workers-b2-7      b2-7    2 vCPU            7 GB    0–5 nodes       light tasks
workers-b3-16     b3-16   4 vCPU           16 GB    0–5 nodes
workers-r3-64     r3-64   8 vCPU           64 GB    0–5 nodes
workers-r3-256    r3-256  32 vCPU         256 GB    0–5 nodes       large RAM tasks
... (38 pools total across b2,b3,c2,c3,r2,r3 families)
```

CA scaling behaviour:
- New pod `Pending` → CA finds the cheapest pool whose flavor fits the resource request → scales up by 1
- Node idle for ~10 min at <50% utilisation → CA scales down (node drained + terminated)
- Existing ready nodes are **always preferred** by the K8s scheduler before CA is invoked

### Node pool commands

```bash
# List all node pools
ovhcloud cloud kube nodepool list \
  --cloud-project ${OVH_PROJECT_ID} \
  --kube-id ${KUBE_ID}

# Get a specific pool
ovhcloud cloud kube nodepool get \
  --cloud-project ${OVH_PROJECT_ID} \
  --kube-id ${KUBE_ID} \
  --nodepool-id <POOL_ID>

# Manually scale a pool (override autoscaler temporarily)
ovhcloud cloud kube nodepool edit \
  --cloud-project ${OVH_PROJECT_ID} \
  --kube-id ${KUBE_ID} \
  --nodepool-id <POOL_ID> \
  --desired-nodes 2

# Delete a pool (terminates all VMs in it)
ovhcloud cloud kube nodepool delete \
  --cloud-project ${OVH_PROJECT_ID} \
  --kube-id ${KUBE_ID} \
  --nodepool-id <POOL_ID>

# List available flavors for the project
ovhcloud cloud reference list-flavors \
  --cloud-project ${OVH_PROJECT_ID} \
  --region GRA9 \
  --json | python3 -c "
import sys, json
data = json.load(sys.stdin)
skip = ['gpu','win','nvme','baremetal','flex']
rows = [(f['ram'], f['vcpus'], f['name'], f['disk']) for f in data
        if f.get('vcpus',0) > 0 and not any(x in f['name'].lower() for x in skip)]
rows.sort()
print(f'  {\"Flavor\":<16} {\"vCPU\":>5} {\"RAM GB\":>7} {\"Disk GB\":>8}')
for ram, vcpu, name, disk in rows:
    print(f'  {name:<16} {vcpu:>5} {ram:>7} {disk:>8}')
"
```

### Node-level kubectl commands

```bash
# Show all nodes with their labels
kubectl get nodes --show-labels

# Show nodes with pool affiliation
kubectl get nodes -L nodepool

# Check node resource availability
kubectl describe node <node-name> | grep -A5 "Allocatable\|Requests"

# Cordon a node (stop scheduling new pods, keep existing)
kubectl cordon <node-name>

# Drain a node (evict all pods before maintenance / manual scale-down)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```

---

## 4. Kubeconfig

```bash
# Download kubeconfig for tes-pilot cluster
ovhcloud cloud kube kubeconfig generate \
  --cloud-project ${OVH_PROJECT_ID} \
  --kube-id ${KUBE_ID} \
  -f content \
  > ~/.kube/ovh-tes.yaml

export KUBECONFIG=~/.kube/ovh-tes.yaml

# Verify connection
kubectl cluster-info
kubectl get nodes
```

To use alongside other kubeconfigs:

```bash
export KUBECONFIG=~/.kube/config:~/.kube/ovh-tes.yaml
kubectl config get-contexts
kubectl config use-context <ovh-context-name>
```

---

## 5. Manila NFS File Storage

Manila is managed via the **OpenStack CLI** (OVH does not expose it in `ovhcloud`).

```bash
# List existing shares
openstack share list

# Show share details (including export path)
openstack share show tes-shared

# Get the NFS export path for use in PV manifest
openstack share show tes-shared -c export_locations -f json

# Get share ID (needed for access rules)
SHARE_ID=$(openstack share show tes-shared -c id -f value)

# List access rules for a share
openstack share access list ${SHARE_ID}

# Grant access (already applied by installer — for reference)
openstack share access create ${SHARE_ID} ip 0.0.0.0/0 --access-level rw

# Get access rule ID (needed in PV volumeAttributes)
openstack share access list ${SHARE_ID} -c id -f value | head -1

# Extend a share (if 150 GiB becomes insufficient)
openstack share extend ${SHARE_ID} 300   # new size in GiB

# Delete share (DESTRUCTIVE — installer teardown does this)
openstack share delete tes-shared
```

### Verify NFS mount in a running pod

```bash
# Check the shared volume is mounted in the Funnel server
kubectl exec -n funnel deploy/funnel -- df -h /mnt/shared

# Check in a worker pod
kubectl exec -n funnel <worker-pod-name> -- ls -la /mnt/shared
```

---

## 6. S3 Object Storage

OVH S3 is API-compatible with AWS S3. Use either `ovhcloud` CLI or the `aws` CLI with `--endpoint-url`.

### Manage buckets and credentials via ovhcloud

```bash
# List S3 buckets in project
ovhcloud cloud storage-s3 list --cloud-project ${OVH_PROJECT_ID}

# Create a bucket
ovhcloud cloud storage-s3 create \
  --cloud-project ${OVH_PROJECT_ID} \
  --name ${OVH_S3_BUCKET} \
  --region ${OVH_REGION}

# List cloud users
ovhcloud cloud user list --cloud-project ${OVH_PROJECT_ID}

# Create S3 credentials for a user
ovhcloud cloud storage-s3 credentials create \
  --cloud-project ${OVH_PROJECT_ID} \
  --user-id ${KUBE_USER_ID}

# List existing credentials
ovhcloud cloud storage-s3 credentials list \
  --cloud-project ${OVH_PROJECT_ID} \
  --user-id ${KUBE_USER_ID}
```

### Access bucket contents via aws CLI

```bash
# Configure aws CLI to use OVH S3 endpoint
export AWS_ACCESS_KEY_ID="${OVH_S3_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${OVH_S3_SECRET_KEY}"
export AWS_DEFAULT_REGION="${OVH_S3_REGION}"   # "gra"

alias s3ovh="aws s3 --endpoint-url ${OVH_S3_ENDPOINT}"

# List objects
s3ovh ls s3://${OVH_S3_BUCKET}/

# List cromwell executions
s3ovh ls s3://${OVH_S3_BUCKET}/cromwell-executions/ --recursive | head -30

# Download a file
s3ovh cp s3://${OVH_S3_BUCKET}/cromwell-executions/<workflow>/<call>/output.txt ./

# Check task staging area
s3ovh ls s3://${OVH_S3_BUCKET}/ --recursive | grep "funnel-work"
```

### Update S3 credentials in the cluster (rotation)

```bash
# Create new credentials
NEW_CREDS=$(ovhcloud cloud storage-s3 credentials create \
  --cloud-project ${OVH_PROJECT_ID} \
  --user-id ${KUBE_USER_ID} \
  --json)

NEW_KEY=$(echo "$NEW_CREDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['access'])")
NEW_SECRET=$(echo "$NEW_CREDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['secret'])")

# Patch the K8s secret live (no restart needed — pods re-read env vars on next start)
kubectl create secret generic ovh-s3-credentials \
  --from-literal=s3_access_key="${NEW_KEY}" \
  --from-literal=s3_secret_key="${NEW_SECRET}" \
  -n funnel \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## 7. Disk Auto-Expander

Each worker node gets a per-node Cinder PVC named `funnel-work-<nodename>`, mounted at `/var/funnel-work`. A DaemonSet monitor expands it automatically.

### Expansion trigger (AND logic)

Both conditions must be true simultaneously:

| Condition | Default | Purpose |
|-----------|---------|---------|
| `used% >= WORK_DIR_EXPAND_THRESHOLD` | 80% | Prevents expansion when disk is genuinely underused |
| `free < WORK_DIR_MIN_FREE_GB` | 75 GB | Prevents runaway expansion on large disks (e.g. 2 TB at 80% still has 400 GB free) |

Expansion step: `WORK_DIR_EXPAND_GB` (50 GB) per trigger. Stabilises naturally once free space exceeds the floor.

### Monitor commands

```bash
# Check monitor logs on a specific worker node
NODE=<worker-node-name>
kubectl logs -n funnel -l app=funnel-disk-monitor \
  --field-selector spec.nodeName=${NODE} -f

# Check all per-node PVCs
kubectl get pvc -n funnel -l app=funnel-disk-monitor

# Check current PVC size for a node
kubectl get pvc funnel-work-${NODE} -n funnel \
  -o jsonpath='{.spec.resources.requests.storage}'

# Manually trigger an expansion (patch PVC directly)
kubectl patch pvc funnel-work-${NODE} -n funnel \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/resources/requests/storage","value":"250Gi"}]'

# Watch the Cinder resize progress
kubectl describe pvc funnel-work-${NODE} -n funnel | grep -A5 Conditions
```

---

## 8. Cromwell Configuration

Add this to your `cromwell-tes.conf` (substitute live values for `<LB_IP>` and credential placeholders):

```hocon
backend {
  providers {
    TES {
      actor-factory = "cromwell.backend.impl.tes.TesBackendLifecycleActorFactory"
      config {
        endpoint = "http://<LB_IP>/v1/tasks"
        root = "s3://${OVH_S3_BUCKET}/cromwell-executions"

        filesystems {
          s3 {
            auth = "default"
            endpoint = "${OVH_S3_ENDPOINT}"
          }
        }

        use_tes_11_preview_backend_parameters = true
        default-runtime-attributes {
          backoff_limit: "3"
        }
      }
    }
  }
}

aws {
  application-name = "cromwell"
  auths = [{
    name    = "default"
    scheme  = "custom_keys"
    access-key = "${OVH_S3_ACCESS_KEY}"
    secret-key = "${OVH_S3_SECRET_KEY}"
  }]
  region = "${OVH_S3_REGION}"
}
```

### Find the LoadBalancer IP

```bash
kubectl get svc funnel-lb -n funnel \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

### Test the Funnel endpoint

```bash
LB_IP=$(kubectl get svc funnel-lb -n funnel \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

curl -s http://${LB_IP}/v1/service-info | python3 -m json.tool

# Submit a minimal TES task
curl -s -X POST http://${LB_IP}/v1/tasks \
  -H "Content-Type: application/json" \
  -d '{"name":"hello","executors":[{"image":"alpine","command":["echo","hello"]}]}' \
  | python3 -m json.tool
```

---

## 9. Troubleshooting

### Funnel pod not starting

```bash
kubectl describe pod -n funnel -l app=funnel
kubectl logs -n funnel deploy/funnel
kubectl logs -n funnel deploy/funnel --previous   # if crashed
```

### Worker jobs stuck Pending

```bash
# Check why pod is not scheduled
kubectl describe pod -n funnel <worker-pod-name> | grep -A10 Events

# Check CA is active and considering the pod
kubectl logs -n kube-system -l app=cluster-autoscaler -f | tail -50

# Check node pool scale-up is not blocked by quota
ovhcloud cloud quota list --cloud-project ${OVH_PROJECT_ID} --region GRA9
```

### NFS mount failures

```bash
# Check Manila CSI driver is running
kubectl get pods -n kube-system -l app=csi-driver-manila

# Check PV/PVC binding
kubectl get pv,pvc -n funnel | grep manila

# Describe the PVC for events
kubectl describe pvc manila-shared-pvc -n funnel
```

### S3 access denied in worker

```bash
# Verify the secret exists and is correct
kubectl get secret ovh-s3-credentials -n funnel -o jsonpath='{.data.s3_access_key}' | base64 -d

# Test S3 access from a worker pod
kubectl exec -n funnel <worker-pod> -- \
  env | grep AWS

kubectl exec -n funnel <worker-pod> -- \
  aws s3 ls s3://${OVH_S3_BUCKET}/ \
    --endpoint-url ${OVH_S3_ENDPOINT}
```

### Node pool not scaling up

```bash
# Check CA logs for scale-up decisions
kubectl logs -n kube-system deploy/cluster-autoscaler | grep -E "scale-up|workers-"

# Verify the nodepool autoscale flag is set
ovhcloud cloud kube nodepool list \
  --cloud-project ${OVH_PROJECT_ID} \
  --kube-id ${KUBE_ID} \
  --json | python3 -c "
import sys,json
for p in json.load(sys.stdin):
    print(p.get('name','?'), '  autoscale:', p.get('autoscale'), '  size:', p.get('currentNodes'), '/', p.get('maxNodes'))
"
```

---

## 10. Quota Reference

This setup touches **five independent quota namespaces** across OVH services.
Exhausting any one of them causes silent or misleading failures, so monitor
them proactively — especially after a cluster incident that produces orphaned resources.

---

### 10.1 OVH Public Cloud — Compute / Instance Quotas

**What it governs**: number of VMs (instances) and total vCPU that Karpenter
can spawn as worker nodes.

| Limit | Typical default | Effect when hit |
|---|---|---|
| `maxTotalInstances` | 20 | Karpenter NodeClaim provisioned but VM never appears; workers stuck Pending indefinitely |
| `maxTotalCores` | 20–40 | Same — Karpenter silently cannot create the requested flavor |
| `maxTotalRAMSize` | varies | Same |

**How to check (CLI)**:
```bash
# OVHcloud CLI — project quota for region GRA9
ovhcloud cloud quota list --cloud-project ${OVH_PROJECT_ID} --region GRA9

# OpenStack CLI — more detail
openstack limits show --absolute -f table | grep -E 'Instances|Cores|Ram'
```

**How to check (Console)**:
Public Cloud → *(project)* → Quota
<https://www.ovh.com/manager/#/public-cloud/pci/projects/c386d174c0974008bac7b36c4dfafb23/quota>

**How to increase**: submit a support ticket from the quota page
("Increase quota"). OVH usually responds within a few hours.

---

### 10.2 OVH MKS — Free-tier Node / Pod limit

**What it governs**: on the free MKS control plane tier, OVH imposes a cap
on the total number of Kubernetes nodes and/or running pods across all
node pools.  The exact figures are not prominently documented but have been
observed to bite when a large number of Karpenter NodeClaims are created
simultaneously (e.g. during a cascade restart).

| Observed limit | ~100 pods per free MKS cluster (unconfirmed) |
|---|---|
| Effect when hit | New pods stay `Pending`; Karpenter may try to provision extra nodes that never become Ready |

**How to check**:
```bash
# Total running pods across all namespaces
kubectl get pods -A --no-headers | wc -l

# Active NodeClaims (Karpenter)
kubectl get nodeclaims -A

# Node count
kubectl get nodes
```

**Mitigation**: keep `maxTotalNodePool` counts conservative in Karpenter
NodePool configs. Cancel stuck tasks before they accumulate retry pods.

---

### 10.3 Cinder Block Volume Quota

**What it governs**: total number of Cinder (block) volumes the project may
own at any time. Each LUKS-encrypted worker disk created by `funnel-disk-setup`
counts as one volume. **Volumes are NOT deleted automatically when a pod
crashes** — they persist until `cleanup.sh` runs or they are removed manually.

| Limit | Default | Effect when hit |
|---|---|---|
| `maxTotalVolumes` | **100** | `funnel-disk-setup` init container fails: `ERROR: volume creation failed:` (empty body because `curl -sf` swallows the 400 response). Workers never start. |
| `maxTotalVolumeGigabytes` | 10 000 GiB | Rare at 100 GiB/volume but reachable |

**Root cause in this cluster**: `setup.sh` was not idempotent — every
CrashLoopBackOff restart created a *new* 100 GiB volume, consuming the
quota within minutes. Fixed in v16 (check-before-create).

**How to check**:
```bash
# Via OpenStack CLI
openstack volume list --all-projects -f table | head -20
openstack quota show | grep volumes

# Via direct Cinder API (no openstack CLI needed)
OS_TOKEN=$(openstack token issue -f value -c id)
curl -s -H "X-Auth-Token: $OS_TOKEN" \
  "https://volume.compute.gra9.cloud.ovh.net/v3/${OS_PROJECT_ID}/limits" \
  | python3 -c "import sys,json; l=json.load(sys.stdin)['limits']['absolute']; print('volumes:', l['totalVolumesUsed'], '/', l['maxTotalVolumes'])"
```

**Emergency cleanup** (delete all unattached volumes):
```bash
# List unattached volumes
openstack volume list --status available -f value -c ID

# Delete all unattached volumes in parallel (Python)
python3 -c "
import subprocess, concurrent.futures
vols = subprocess.check_output(['openstack','volume','list','--status','available','-f','value','-c','ID']).decode().split()
print(f'Deleting {len(vols)} volumes...')
def rm(v): return subprocess.run(['openstack','volume','delete',v], capture_output=True).returncode
with concurrent.futures.ThreadPoolExecutor(max_workers=10) as ex:
    list(ex.map(rm, vols))
print('Done.')
"
```

---

### 10.4 Barbican Key Manager — Secrets Quota

**What it governs**: number of Barbican *secrets* (individual key blobs)
the project may store. Each LUKS-encrypted Cinder volume causes Cinder
to store one Barbican secret (the AES-256 LUKS key).

| Limit | Default | Effect when hit |
|---|---|---|
| `secrets` | **200** | Cinder returns `400 Key manager error` on any new LUKS volume creation. Not directly obvious from error message. |

**Orphaning behaviour**: deleting a Cinder volume via the Cinder API does
**not** delete the corresponding Barbican secret. Over time (especially after
crash-loop events) secrets accumulate until the quota is hit.

**How to check**:
```bash
BARBICAN_URL="https://key-manager.gra.cloud.ovh.net"
OS_TOKEN=$(openstack token issue -f value -c id)
curl -s -H "X-Auth-Token: $OS_TOKEN" "${BARBICAN_URL}/v1/secrets?limit=1" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('secrets:', d['total'], '/ 200')"
```

**Emergency cleanup** (delete all orphaned secrets after volumes are gone):
```bash
python3 << 'EOF'
import subprocess, json, urllib.request, urllib.error, base64, concurrent.futures

OS_TOKEN = subprocess.check_output(['openstack','token','issue','-f','value','-c','id']).decode().strip()
BARBICAN = "https://key-manager.gra.cloud.ovh.net/v1"
H = {"X-Auth-Token": OS_TOKEN}

def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=H), timeout=15) as r:
        return json.loads(r.read())

def delete(href):
    req = urllib.request.Request(href, method="DELETE", headers=H)
    try: urllib.request.urlopen(req, timeout=15); return "ok"
    except urllib.error.HTTPError as e: return f"err {e.code}"

hrefs = []
offset = 0
while True:
    d = get(f"{BARBICAN}/secrets?limit=100&offset={offset}")
    batch = d.get("secrets", [])
    if not batch: break
    hrefs += [s["secret_ref"] for s in batch]
    offset += len(batch)
    if len(hrefs) >= d.get("total", 0): break

print(f"Deleting {len(hrefs)} secrets...")
with concurrent.futures.ThreadPoolExecutor(max_workers=20) as ex:
    results = list(ex.map(delete, hrefs))
print(f"ok={results.count('ok')}, errors={len(results)-results.count('ok')}")
EOF
```

> **Note**: some secrets may return 500 and refuse to delete — these are
> internally broken records on OVH's side and do not count against your
> quota despite appearing in the list. Ignore them.

---

### 10.5 Barbican Key Manager — Orders Quota

**What it governs**: number of Barbican *orders* (asynchronous key-generation
requests) the project may have. When Cinder creates a LUKS volume it calls
`POST /v1/orders` to ask Barbican to generate an AES-256 key. **This is the
actual blocker for LUKS volume creation, not the secrets quota.**

| Limit | Default | Effect when hit |
|---|---|---|
| `orders` | **400** | Cinder returns `400 Key manager error`. Identical error to the secrets quota hit — only distinguishable by checking both counters. |

**Orphaning behaviour**: same as secrets — deleting a Cinder volume leaves
the Barbican order behind. 400 volumes = 400 orders = quota exhausted.

**How to check**:
```bash
BARBICAN_URL="https://key-manager.gra.cloud.ovh.net"
OS_TOKEN=$(openstack token issue -f value -c id)
curl -s -H "X-Auth-Token: $OS_TOKEN" "${BARBICAN_URL}/v1/orders?limit=1" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('orders:', d['total'], '/ 400')"
```

**Emergency cleanup** (delete all orphaned orders):
```bash
python3 << 'EOF'
import subprocess, json, urllib.request, urllib.error, base64, concurrent.futures

OS_TOKEN = subprocess.check_output(['openstack','token','issue','-f','value','-c','id']).decode().strip()
BARBICAN = "https://key-manager.gra.cloud.ovh.net/v1"
H = {"X-Auth-Token": OS_TOKEN}

def get(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=H), timeout=15) as r:
        return json.loads(r.read())

def delete(href):
    req = urllib.request.Request(href, method="DELETE", headers=H)
    try: urllib.request.urlopen(req, timeout=15); return "ok"
    except urllib.error.HTTPError as e: return f"err {e.code}"

hrefs = []
offset = 0
while True:
    d = get(f"{BARBICAN}/orders?limit=100&offset={offset}")
    batch = d.get("orders", [])
    if not batch: break
    hrefs += [o["order_ref"] for o in batch]
    offset += len(batch)
    if len(hrefs) >= d.get("total", 0): break

print(f"Deleting {len(hrefs)} orders...")
with concurrent.futures.ThreadPoolExecutor(max_workers=30) as ex:
    results = list(ex.map(delete, hrefs))
print(f"ok={results.count('ok')}, errors={len(results)-results.count('ok')}")
EOF
```

---

### 10.6 All-in-one Quota Health Check

Run this at any time to get a snapshot of all relevant quotas:

```bash
python3 << 'EOF'
import subprocess, json, urllib.request, base64

KUBECONFIG = "/home/gvandeweyer/.kube/ovh-tes.yaml"
OS_USERNAME = "user-u3Tb6tBzF86J"
OS_TENANT_ID = "c386d174c0974008bac7b36c4dfafb23"
OS_AUTH_URL = "https://auth.cloud.ovh.net/v3"

# Get creds from k8s secret
pw = subprocess.check_output(
    ["kubectl","--kubeconfig",KUBECONFIG,"get","secret","funnel-openstack-creds",
     "-n","funnel","-o","jsonpath={.data.OS_PASSWORD}"]).decode()
OS_PASSWORD = base64.b64decode(pw).decode()

# Authenticate
auth = json.dumps({"auth":{"identity":{"methods":["password"],"password":{"user":{"name":OS_USERNAME,"domain":{"name":"Default"},"password":OS_PASSWORD}}},"scope":{"project":{"id":OS_TENANT_ID}}}}).encode()
with urllib.request.urlopen(urllib.request.Request(f"{OS_AUTH_URL}/auth/tokens",data=auth,headers={"Content-Type":"application/json"},method="POST"),timeout=15) as r:
    TOKEN = r.headers["X-Subject-Token"]

H = {"X-Auth-Token": TOKEN}

def get(url):
    with urllib.request.urlopen(urllib.request.Request(url,headers=H),timeout=15) as r:
        return json.loads(r.read())

# Cinder volumes
cinlim = get(f"https://volume.compute.gra9.cloud.ovh.net/v3/{OS_TENANT_ID}/limits")["limits"]["absolute"]
# Barbican
barb = "https://key-manager.gra.cloud.ovh.net/v1"
secrets_total = get(f"{barb}/secrets?limit=1").get("total", "?")
orders_total  = get(f"{barb}/orders?limit=1").get("total", "?")

print("\n==== OVH Quota Health Check ====")
print(f"  Cinder volumes  : {cinlim['totalVolumesUsed']:>4} / {cinlim['maxTotalVolumes']}")
print(f"  Cinder GiB      : {cinlim['totalGigabytesUsed']:>4} / {cinlim['maxTotalVolumeGigabytes']}")
print(f"  Barbican secrets: {secrets_total:>4} / 200")
print(f"  Barbican orders : {orders_total:>4} / 400")
print()
print("For compute/instance quota:")
print("  ovhcloud cloud quota list --cloud-project c386d174c0974008bac7b36c4dfafb23 --region GRA9")
EOF
```

---

## 11. Cost Reference

All prices are OVH Public Cloud hourly rates (ex-VAT, GRA9). MKS control plane is **free**. (ex-VAT, GRA9). MKS control plane is **free**.

| Resource | Type | vCPU | RAM | Hourly | Monthly est. |
|---|---|---|---|---|---|
| System node | d2-2 | 1 (shared) | 2 GB | €0.010 | €7.30 |
| Worker — small | b2-7 | 2 | 7 GB | €0.034 | €24.80 |
| Worker — medium | b3-16 | 4 | 16 GB | €0.068 | €49.60 |
| Worker — large | r3-64 | 8 | 64 GB | €0.168 | €122.60 |
| Worker — XL | r3-256 | 32 | 256 GB | €0.630 | €459.90 |
| Manila NFS 150 GiB | standard-1az | — | — | €0.030 | €21.90 |
| Cinder block 100 GiB | high-speed gen2 | — | — | €0.008 | €5.84 |
| S3 storage | per GiB | — | — | €0.001 | €0.73/100GB |

**Idle baseline** (system node + Manila share only): ~€7.30 + €21.90 = **≈ €29/month**

Worker nodes cost **only while running** — CA scales to 0 when idle.

### OVH console links

- Project overview: https://www.ovh.com/manager/#/public-cloud/pci/projects/c386d174c0974008bac7b36c4dfafb23
- MKS clusters: https://www.ovh.com/manager/#/public-cloud/pci/projects/c386d174c0974008bac7b36c4dfafb23/kubernetes
- Object Storage: https://www.ovh.com/manager/#/public-cloud/pci/projects/c386d174c0974008bac7b36c4dfafb23/storages/objects
- File Storage: https://www.ovh.com/manager/#/public-cloud/pci/projects/c386d174c0974008bac7b36c4dfafb23/storages/file-storage
- Quotas: https://www.ovh.com/manager/#/public-cloud/pci/projects/c386d174c0974008bac7b36c4dfafb23/quota
