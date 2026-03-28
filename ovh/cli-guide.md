---
layout: default
title: "OVHcloud CLI Guide"
description: "OVHcloud / OpenStack CLI commands for managing infrastructure."
permalink: /ovh/cli-guide/
---

# OVHcloud CLI Guide

This page documents all **OVHcloud** (`ovhcloud`) and **OpenStack** (`openstack`) CLI commands used in the deployment and operation of the Cromwell + Funnel TES platform on OVHcloud MKS.

> **Note on access errors:** If a command returns an authentication or authorization error, verify that `ovhcloud login` was completed, that `~/.ovh.conf` exists with valid credentials, and that the OpenStack `clouds.yaml` is sourced correctly. Most API calls below require the project-level `cloud_compute` or `cloud_network` roles assigned to the OVH cloud user. See [Installation Prerequisites](ovh/installation-guide/#prerequisites) for details.

---

## `ovhcloud` CLI

### Authentication: Login
```
ovhcloud login
```
- Initiates an interactive OAuth flow; opens a browser to authorize the OVH CLI.
- On success, writes `~/.ovh.conf` containing `application_key`, `application_secret`, and `consumer_key`.

### Authentication: Verify Login
```
ovhcloud cloud project list -o json
```
- Lists all Public Cloud projects visible to the authenticated account.
- Response: JSON array — `[{"project_id": "abc123...", "description": "...", "status": "ok"}]`
- Used by the installer to confirm the CLI is authenticated before proceeding.

---

### Networking: List Private Networks
```
ovhcloud cloud network private list \
    --cloud-project <OVH_PROJECT_ID> \
    -o json
```
- `--cloud-project` — Public Cloud project UUID.
- `-o json` — machine-readable output for scripted parsing.
- Response: JSON array — `[{"id":"pn-...","name":"tes-private-net","openstackId":"<uuid>","region":"GRA9","status":"ACTIVE"}]`
- The `openstackId` is the Neutron UUID needed by OpenStack commands; `id` is the OVH shorthand (`pn-...` form).

### Networking: Create Private Network
```
ovhcloud cloud network private create <REGION> \
    --cloud-project <OVH_PROJECT_ID> \
    --name <NETWORK_NAME> \
    --wait
```
- `<REGION>` — positional, e.g. `GRA9`.
- `--name` — friendly name for the private (Neutron) network.
- `--wait` — blocks until the network is fully provisioned.
- Response: `{"name":"tes-private-net"}`. The `openstackId` (Neutron UUID) is not included in the create response; re-list with `network private list` to obtain it.

### Networking: Create Subnet
```
ovhcloud cloud network private subnet create <OPENSTACK_NET_ID> \
    --cloud-project <OVH_PROJECT_ID> \
    --region <REGION> \
    --name <SUBNET_NAME> \
    --cidr 192.168.100.0/24 \
    --ip-version 4 \
    --enable-dhcp \
    -o json
```
- `<OPENSTACK_NET_ID>` — Neutron UUID of the parent network (not the `pn-...` OVH ID).
- `--cidr` — CIDR block for the subnet.
- `--enable-dhcp` — enables DHCP address assignment.
- Response: `{"details":{"id":"<subnet-uuid>","cidr":"192.168.100.0/24",...}}`

### Networking: Delete Private Network
```
ovhcloud cloud network private delete <PRIV_NET_ID> \
    --cloud-project <OVH_PROJECT_ID>
```
- `<PRIV_NET_ID>` — the OVH `pn-...` ID (not the Neutron UUID).
- Must be run **after** the MKS cluster is deleted and all router ports are removed; otherwise the delete fails with a port-in-use error.

---

### Kubernetes (MKS): List Clusters
```
ovhcloud cloud kube list \
    --cloud-project <OVH_PROJECT_ID> \
    -o json
```
- Returns all MKS clusters in the project.
- Response: JSON array — `[{"id":"<kube-id>","name":"tes-cluster","region":"GRA9","status":"READY","version":"1.31"}]`

### Kubernetes (MKS): Create Cluster
```
ovhcloud cloud kube create \
    --cloud-project <OVH_PROJECT_ID> \
    --name <K8S_CLUSTER_NAME> \
    --region <OVH_REGION> \
    --version <K8S_VERSION> \
    --private-network-id <OPENSTACK_NET_ID> \
    --nodes-subnet-id <OPENSTACK_SUBNET_ID> \
    -o json
```
- `--version` — Kubernetes version, e.g. `1.31`.
- `--private-network-id` — Neutron UUID of the private network (created above).
- `--nodes-subnet-id` — Neutron UUID of the private subnet; nodes will be placed here.
- Response: `{"id":"<kube-id>","name":"...","status":"INSTALLING",...}`

### Kubernetes (MKS): Get Cluster Status
```
ovhcloud cloud kube get \
    --cloud-project <OVH_PROJECT_ID> \
    <KUBE_ID> \
    -o status
```
- `-o status` — returns only the `status` field value, e.g. `READY`, `INSTALLING`, `UPDATING`.
- Used in polling loops to wait until the cluster reaches `READY`.

### Kubernetes (MKS): Download Kubeconfig
```
ovhcloud cloud kube kubeconfig generate <KUBE_ID> \
    --cloud-project <OVH_PROJECT_ID> \
    -o json
```
- Downloads the cluster's kubeconfig as a JSON wrapper; the YAML content is in the `message` field.
- Response: `{"message":"apiVersion: v1\nclusters:\n...","details":{"content":"..."}}`

### Kubernetes (MKS): Delete Cluster
```
ovhcloud cloud kube delete <KUBE_ID> \
    --cloud-project <OVH_PROJECT_ID>
```
- Deletes the MKS cluster and all its node pools. Instances are terminated by OVH automatically.
- Does **not** remove the private network or Manila NFS share; those require separate cleanup.

### Kubernetes (MKS): List Node Pools
```
ovhcloud cloud kube nodepool list <KUBE_ID> \
    --cloud-project <OVH_PROJECT_ID> \
    -o json
```
- Response: JSON array — `[{"id":"<pool-id>","name":"system","flavor":"b3-8","desiredNodes":1,"autoscale":false,"status":"READY"}]`

### Kubernetes (MKS): Disable Autoscale on Node Pool
```
ovhcloud cloud kube nodepool edit <KUBE_ID> <POOL_ID> \
    --cloud-project <OVH_PROJECT_ID> \
    --autoscale=false
```
- Disables the built-in MKS Cluster Autoscaler on a specific pool; required when Karpenter takes over as the autoscaler to avoid conflicts.

---

### Flavors: List Available Instance Types
```
ovhcloud cloud reference list-flavors \
    --cloud-project <OVH_PROJECT_ID> \
    --region <FLAVOR_LOOKUP_REGION> \
    -o json
```
- `--region` — region to query, e.g. `GRA9`. Flavor availability varies by region.
- Response: JSON array — `[{"name":"b3-8","vcpus":4,"ram":8,"disk":50,"type":"cpu","region":"GRA9"}]`
- RAM is returned in **GB** (unlike OpenStack CLI which uses MB).

---

### Container Registry (MPR): List Available Plans
```
ovhcloud cloud reference container-registry list-plans \
    --cloud-project <OVH_PROJECT_ID> \
    -o json
```
- Returns Harbor plan sizes (S/M/L) and their IDs, filtered by region.
- Response: `[{"id":"<plan-id>","name":"Small","region":"GRA",...}]`

### Container Registry (MPR): List Registries
```
ovhcloud cloud container-registry list \
    --cloud-project <OVH_PROJECT_ID> \
    -o json
```
- Response: `[{"id":"<reg-id>","name":"tes-registry","url":"<hash>.gra.container-registry.ovh.net","status":"READY"}]`

### Container Registry (MPR): Create Registry
```
ovhcloud cloud container-registry create \
    --cloud-project <OVH_PROJECT_ID> \
    --name <MPR_REGISTRY_NAME> \
    --region <REGISTRY_REGION> \
    --plan-id <PLAN_ID> \
    -o json
```
- `<REGISTRY_REGION>` — short region code without trailing digits, e.g. `GRA` (not `GRA9`).
- `<PLAN_ID>` — obtained from `container-registry list-plans`.
- Response: `{"details":{"id":"<reg-id>","name":"...","status":"INSTALLING"}}`

### Container Registry (MPR): Get Registry Status
```
ovhcloud cloud container-registry get <REGISTRY_ID> \
    --cloud-project <OVH_PROJECT_ID> \
    -o json
```
- Returns current registry status and URL once ready.
- Response: `{"id":"<reg-id>","url":"<hash>.gra.container-registry.ovh.net","status":"READY"}`

### Container Registry (MPR): Delete Registry
```
ovhcloud cloud container-registry delete <REGISTRY_ID> \
    --cloud-project <OVH_PROJECT_ID>
```
- Deletes the MPR instance and all Harbor images and users within it.

---

### Object Storage (S3): Create S3 Credentials
```
ovhcloud cloud storage-s3 credentials create <KUBE_USER_ID> \
    --cloud-project <OVH_PROJECT_ID> \
    -o json
```
- `<KUBE_USER_ID>` — positional; the OVH cloud user ID (not username) that will own the bucket.
- Response: `{"access":"<access-key>","secret":"<secret-key>"}` — the `secret` is only returned **once** at creation time.

### Object Storage (S3): List S3 Credentials
```
ovhcloud cloud storage-s3 credentials list <KUBE_USER_ID> \
    --cloud-project <OVH_PROJECT_ID> \
    -o json
```
- Returns existing credentials for the user; the `secret` key is **not** re-exposed.
- Response: `[{"access":"<access-key>"}]`

### Object Storage (S3): Delete S3 Credentials
```
ovhcloud cloud storage-s3 credentials delete <KUBE_USER_ID> <ACCESS_KEY> \
    --cloud-project <OVH_PROJECT_ID>
```
- Removes the S3 RadosGW credentials for the user. Must be done before re-creating them.

---

### Users: List Cloud Users
```
ovhcloud cloud user list \
    --cloud-project <OVH_PROJECT_ID> \
    -o json
```
- Lists all OVH cloud users (Public Cloud → Users & Roles) in the project.
- Response: `[{"id":"<user-id>","username":"user-xyz","status":"ok","roles":[...]}]`
- Used to resolve the numeric `id` from an OpenStack `username` sourced from `clouds.yaml`.

---

## `openstack` CLI

### Network: List Networks
```
openstack network list
```
- Lists all Neutron networks visible to the authenticated user.
- Response: table with `ID`, `Name`, `Subnets` columns.

### Network: Show Network
```
openstack network show <NETWORK_NAME_OR_ID> \
    -c id -f value
```
- Returns the Neutron UUID for a network looked up by name.

### Network: List Subnets
```
openstack subnet list \
    --network <OPENSTACK_NET_ID> \
    -c ID -f value
```
- `--network` — Neutron UUID of the parent network.
- Response: one UUID per line (plain value output).

### Network: Show Subnet
```
openstack subnet show <SUBNET_ID> \
    -f value -c gateway_ip
```
- Returns a single field value; `-c gateway_ip` prints only the gateway IP.
- Example response: `192.168.100.253` (or `None` if unset).

### Network: Set Subnet Gateway
```
openstack subnet set --no-allocation-pool <SUBNET_ID>
openstack subnet set --gateway 192.168.100.253 <SUBNET_ID>
openstack subnet set \
    --allocation-pool start=192.168.100.1,end=192.168.100.252 \
    <SUBNET_ID>
```
- Three-step sequence: clear the DHCP pool → set the gateway IP → restore the pool excluding the gateway.
- Required because OVH CCM needs a `gateway_ip` on the subnet to auto-provision an OVHcloud Gateway (Octavia router) for LoadBalancer services.

### Network: List Ports
```
openstack port list \
    --network <OPENSTACK_NET_ID> \
    -c device_id -c device_owner -f json
```
- Lists all ports on a network with their device owner and device ID.
- Used to identify lingering router ports that block network deletion after cluster teardown.

### Network: Remove Router from Subnet
```
openstack router remove subnet <ROUTER_ID> <SUBNET_ID>
```
- Detaches a router's internal interface from a subnet; must be done before deleting the router.

### Network: Unset Router Gateway
```
openstack router unset --external-gateway <ROUTER_ID>
```
- Clears the external gateway port on a router before deleting it.

### Network: Delete Router
```
openstack router delete <ROUTER_ID>
```
- Deletes the OVHcloud Gateway (Neutron router) auto-provisioned when a LoadBalancer service was created. Must be deleted before the private network can be removed.

---

### Compute: List Instances
```
openstack server list
```
- Lists all running instances in the project.
- Response: table with `ID`, `Name`, `Status`, `Networks`, `Image`, `Flavor`.

### Compute: List Flavors
```
openstack flavor list --all -f json
```
- `--all` — includes all flavors (including unlisted memory-optimized tiers).
- `-f json` — returns JSON; each object has `Name`, `VCPUs`, `RAM` (in **MB**), `Disk` fields.
- Used as a fallback when the `ovhcloud` CLI is not available.

---

### Block Storage (Cinder): List Volumes
```
openstack volume list \
    --format value -c ID -c Name -c Status
```
- Lists all Cinder (block storage) volumes in the project.
- Response: tab-separated lines — `<uuid>  funnel-work-<task-id>  available`
- Used to baseline-snapshot volumes before a test and confirm cleanup after node drain.

### Block Storage (Cinder): Show Volume
```
openstack volume show <VOLUME_ID> \
    -f value -c status
```
- Returns the current status of a single volume: `available`, `in-use`, `deleting`, or `deleted` / `NOT_FOUND`.

---

### File Storage (Manila NFS): List Share Networks
```
openstack share network list \
    -c ID -c Name -f value
```
- Lists all Manila share networks (ties a Manila share to a Neutron network).
- Response: one line per share network — `<uuid>  tes-share-network`.

### File Storage (Manila NFS): Create Share Network
```
openstack share network create \
    --neutron-net-id    <OPENSTACK_NET_ID> \
    --neutron-subnet-id <OPENSTACK_SUBNET_ID> \
    --name <SHARE_NET_NAME> \
    -c id -f value
```
- Associates the Manila service with the private Neutron network so the NFS server is reachable from cluster nodes.
- Response: single UUID of the created share network.

### File Storage (Manila NFS): Delete Share Network
```
openstack share network delete <SHARE_NET_ID>
```
- Removes the share network binding. The Manila share itself must be deleted first.

### File Storage (Manila NFS): Create Share
```
openstack share create NFS <SIZE_GiB> \
    --name         <SHARE_NAME> \
    --share-type   <SHARE_TYPE> \
    --share-network <MANILA_SHARE_NET_ID> \
    -c id -f value
```
- `NFS` — protocol type.
- `<SIZE_GiB>` — size in GiB, e.g. `100`.
- `--share-type` — OVH share type, e.g. `standard-1az` (DHSS=True; server provisioned on private network).
- Response: UUID of the created share.

### File Storage (Manila NFS): List Shares
```
openstack share list \
    -c ID -c Name -f value
```
- Response: one line per share — `<uuid>  tes-nfs-share`.

### File Storage (Manila NFS): Show Share Status
```
openstack share show <SHARE_ID> \
    -c status -f value
```
- Returns the share status: `creating`, `available`, `error`, `deleted`.

### File Storage (Manila NFS): Get NFS Export Path
```
openstack share export location list <SHARE_ID> \
    -c Path -f value
```
- Returns the NFS mount path, e.g. `10.X.X.X:/path/to/share`.
- Note: the correct subcommand is `export location list` (space-separated); the older hyphenated form `export-location list` is deprecated.

### File Storage (Manila NFS): List Access Rules
```
openstack share access list <SHARE_ID>
```
- Lists existing IP-based or user-based access rules on the share.
- Response: table with `id`, `access_type`, `access_to`, `access_level`, `state`.

### File Storage (Manila NFS): Grant Access
```
openstack share access create <SHARE_ID> ip 0.0.0.0/0 \
    --access-level rw \
    -c id -f value
```
- Grants read-write NFS access to all IPs (`0.0.0.0/0`); restricting to the private subnet CIDR is recommended for production.
- Response: UUID of the created access rule.

### File Storage (Manila NFS): Revoke Access
```
openstack share access delete <SHARE_ID> <ACCESS_ID>
```
- Removes the access rule. Must be done before deleting the share.

### File Storage (Manila NFS): Delete Share
```
openstack share delete <SHARE_ID>
```
- Initiates share deletion. Poll `openstack share show <id> -c status -f value` until it returns `deleted`.

---

## Resources

- [OVHcloud Public Cloud Documentation](https://docs.ovh.com/)
- [OVHcloud CLI (ovhcloud)](https://github.com/ovh/ovhcloud-cli)
- [OVH API Token Manager](https://api.ovh.com/createToken/)
- [OpenStack CLI Reference](https://docs.openstack.org/python-openstackclient/latest/cli/)
- [python-manilaclient (share commands)](https://docs.openstack.org/python-manilaclient/latest/)
