---
layout: default
title: "Installer Files"
description: "Reference listing of all installer scripts, configuration templates, and YAML manifests"
permalink: /ovh/installer-files/
---

# Installer Files

All files are part of the **OVHcloud MKS + Funnel + Cromwell** installer package. Download the full bundle or individual files as needed.

---

## Complete Bundle

| File | Description | Download |
|------|-------------|----------|
| `ovh_installer.tar.gz` | Full installer package (all scripts, templates, and examples) | [⬇ Download](/ovh/files/ovh_installer.tar.gz) |

---

## Installer Scripts

Located in `installer/` — the main scripts that drive the deployment.

| File | Description | Download |
|------|-------------|----------|
| `install-ovh-mks.sh` | **Main installer** — orchestrates all phases (0–8): creates the MKS cluster, sets up Karpenter, deploys Manila NFS, S3, private registry, and Funnel TES | [⬇ Download](/ovh/files/installer/install-ovh-mks.sh) |
| `env.variables` | **Configuration file** — all mandatory and optional variables (cluster name, region, quotas, storage settings, image tags, registry credentials). Edit this before running the installer | [⬇ Download](/ovh/files/installer/env.variables) |
| `destroy-ovh-mks.sh` | **Teardown script** — cleanly removes all OVH resources created by the installer (cluster, network, Manila share, S3 bucket, registry) | [⬇ Download](/ovh/files/installer/destroy-ovh-mks.sh) |
| `update-nodepool-flavors.sh` | **NodePool updater** — queries the live OVH flavor catalog and regenerates the Karpenter NodePool with filtered instance types based on `env.variables` quota settings. Run post-deploy to adjust scaling limits | [⬇ Download](/ovh/files/installer/update-nodepool-flavors.sh) |
| `test-disk-handling.sh` | **Integration test suite** — submits test TES tasks to verify NFS mount visibility, disk write access, Cinder auto-expansion, and cleanup. Run after full deployment to validate the platform | [⬇ Download](/ovh/files/installer/test-disk-handling.sh) |
| `test-disk-handling-lb.sh` | **LoadBalancer variant of the test suite** — same tests but routes through the external LoadBalancer IP instead of the cluster-internal endpoint | [⬇ Download](/ovh/files/installer/test-disk-handling-lb.sh) |

---

## Funnel TES Task Examples

Located in `installer/funnel_examples/` — ready-to-submit TES task JSON files for smoke testing.

| File | Description | Download |
|------|-------------|----------|
| `hello.json` | Minimal "hello world" TES task — verifies basic task submission, scheduling, and completion | [⬇ Download](/ovh/files/installer/funnel_examples/hello.json) |
| `disk-write-test.json` | Writes data to the task work directory — validates Cinder volume mount and write access at `/var/funnel-work` | [⬇ Download](/ovh/files/installer/funnel_examples/disk-write-test.json) |
| `long-sleep.json` | Long-running sleep task — useful for testing Karpenter node provisioning, node lifetime, and consolidation behaviour | [⬇ Download](/ovh/files/installer/funnel_examples/long-sleep.json) |
| `containerd-location-check.json` | Prints the containerd socket path inside the task container — useful for debugging nerdctl/containerd executor configuration | [⬇ Download](/ovh/files/installer/funnel_examples/containerd-location-check.json) |

---

## Kubernetes YAML Templates

Located in `installer/yamls/` — Kubernetes manifest templates rendered by the installer using `envsubst` from `env.variables`. These are not meant to be applied directly; they are processed during installation.

### Funnel TES

| File | Description | Download |
|------|-------------|----------|
| `funnel-namespace.template.yaml` | Kubernetes Namespace for all Funnel resources | [⬇ Download](/ovh/files/installer/yamls/funnel-namespace.template.yaml) |
| `funnel-serviceaccount.template.yaml` | ServiceAccount used by Funnel pods | [⬇ Download](/ovh/files/installer/yamls/funnel-serviceaccount.template.yaml) |
| `funnel-rbac.template.yaml` | Role and RoleBinding granting Funnel the permissions to create/manage task Jobs and Pods | [⬇ Download](/ovh/files/installer/yamls/funnel-rbac.template.yaml) |
| `funnel-configmap.template.yaml` | Funnel server configuration (nerdctl executor, S3 backend, NFS paths, task work directory, logging) | [⬇ Download](/ovh/files/installer/yamls/funnel-configmap.template.yaml) |
| `funnel-deployment.template.yaml` | Funnel server Deployment (REST API + gRPC listener, runs on the system node) | [⬇ Download](/ovh/files/installer/yamls/funnel-deployment.template.yaml) |
| `funnel-loadbalancer-service.template.yaml` | LoadBalancer Service exposing Funnel externally on ports 8000 (HTTP) and 9090 (gRPC) | [⬇ Download](/ovh/files/installer/yamls/funnel-loadbalancer-service.template.yaml) |
| `funnel-tes-service.template.yaml` | ClusterIP Service for internal gRPC communication between Funnel components | [⬇ Download](/ovh/files/installer/yamls/funnel-tes-service.template.yaml) |
| `funnel-db-pvc.template.yaml` | PersistentVolumeClaim for the Funnel task database (BoltDB) | [⬇ Download](/ovh/files/installer/yamls/funnel-db-pvc.template.yaml) |
| `funnel-shared-pvc.template.yaml` | PersistentVolumeClaim binding to the Manila NFS share for `/mnt/shared` | [⬇ Download](/ovh/files/installer/yamls/funnel-shared-pvc.template.yaml) |
| `funnel-disk-setup.template.yaml` | DaemonSet that mounts/formats the per-node Cinder volume at `/var/funnel-work`, handles LUKS encryption, LVM auto-expansion, and NFS keepalive | [⬇ Download](/ovh/files/installer/yamls/funnel-disk-setup.template.yaml) |
| `funnel-disk-monitor.template.yaml` | DaemonSet sidecar that monitors disk usage and triggers LVM volume extension when the fill threshold is reached | [⬇ Download](/ovh/files/installer/yamls/funnel-disk-monitor.template.yaml) |

### Karpenter

| File | Description | Download |
|------|-------------|----------|
| `karpenter-nodeclass.template.yaml` | OVHcloud NodeClass defining the base node configuration (OS image, private network, SSH key, Cinder volume spec) | [⬇ Download](/ovh/files/installer/yamls/karpenter-nodeclass.template.yaml) |
| `nodepool.template.json` | Karpenter NodePool specification (allowed instance types, resource limits, consolidation policy) — rendered as JSON for the OVH Karpenter provider | [⬇ Download](/ovh/files/installer/yamls/nodepool.template.json) |
| `karpenter-node-overhead.template.yaml` | Ghost DaemonSet that reserves a small amount of CPU and memory on each worker node to account for system processes, ensuring accurate Karpenter scheduling decisions | [⬇ Download](/ovh/files/installer/yamls/karpenter-node-overhead.template.yaml) |

### Manila NFS Storage

| File | Description | Download |
|------|-------------|----------|
| `manila-storageclass.template.yaml` | StorageClass for the Manila NFS CSI driver | [⬇ Download](/ovh/files/installer/yamls/manila-storageclass.template.yaml) |
| `manila-pvc.template.yaml` | PersistentVolumeClaim requesting a Manila NFS share of the configured size | [⬇ Download](/ovh/files/installer/yamls/manila-pvc.template.yaml) |
| `manila-csi-values.template.yaml` | Helm values file for the Manila CSI driver (OpenStack credentials, share type, region) | [⬇ Download](/ovh/files/installer/yamls/manila-csi-values.template.yaml) |
| `nfs-ssh-mount.yaml` | Static manifest for manually mounting an NFS share via SSH tunnel (diagnostic/fallback use) | [⬇ Download](/ovh/files/installer/yamls/nfs-ssh-mount.yaml) |

### S3 & Secrets

| File | Description | Download |
|------|-------------|----------|
| `s3-secret.template.yaml` | Kubernetes Secret holding the OVH S3 access key and secret key for use by Funnel and init containers | [⬇ Download](/ovh/files/installer/yamls/s3-secret.template.yaml) |

---

> **Note**: Template files (`.template.yaml`, `.template.json`) contain `${VARIABLE}` placeholders and are rendered by `envsubst` during installation. Do not apply them directly with `kubectl apply`.

---

**Last Updated**: March 28, 2026
