---
layout: default
title: "Documentation Reorganization"
description: "Multi-platform documentation structure for GitHub Pages"
permalink: /pages-organization/
---

# Documentation Reorganization (v2.0)

**Multi-platform structure for Cromwell + TES deployment**

The documentation has been reorganized into a **cloud-agnostic core** with **platform-specific implementations**.

---

## 📂 New Directory Structure

```
/
├── index.md                              ← Root: Cromwell + TES on Kubernetes (any cloud)
├── quick-reference.md                    ← All platforms
├── _config.yml, .nojekyll               ← Jekyll config
│
├── /tes                                  ← Platform-agnostic TES section
│   ├── index.md                          (overview)
│   ├── architecture.md                   (design patterns, DaemonSet)
│   ├── container-images.md               (custom builds, dependencies)
│   ├── configuration.md                  (runtime options - TEMPLATE)
│   └── troubleshooting.md                (common issues - TEMPLATE)
│
├── /cromwell                             ← Platform-agnostic Cromwell section
│   ├── index.md                          (overview)
│   ├── configuration.md                  (backends, options - TEMPLATE)
│   ├── workflows.md                      (submission, monitoring - TEMPLATE)
│   ├── tes-integration.md                (Cromwell-TES communication - TEMPLATE)
│   └── troubleshooting.md                (common issues - TEMPLATE)
│
├── /karpenter                            ← Platform-agnostic Karpenter section
│   ├── index.md                          (overview)
│   ├── configuration.md                  (NodePool tuning - TEMPLATE)
│   ├── cloud-providers.md                (provider-specific setup - TEMPLATE)
│   └── troubleshooting.md                (scaling issues - TEMPLATE)
│
├── /ovh                                  ← OVH-specific section
│   ├── index.md                          (OVH overview, 7-phase guide)
│   ├── installation-guide.md             (copied from Installation_Guide.md)
│   ├── cli-guide.md                      (copied from OVH_CLI_GUIDE.md)
│   ├── cost-and-infrastructure.md        (TEMPLATE)
│   ├── troubleshooting.md                (OVH-specific issues - TEMPLATE)
│   └── README.md                         (OVH section overview)
│
└── /aws                                  ← AWS-specific section (template)
    ├── index.md                          (AWS overview)
    ├── installation-guide.md             (AWS-specific steps - TEMPLATE)
    ├── cli-guide.md                      (AWS CLI reference - TEMPLATE)
    ├── cost-and-capacity.md              (AWS pricing - TEMPLATE)
    ├── troubleshooting.md                (AWS-specific issues - TEMPLATE)
    └── README.md                         (AWS section overview)
```

---

## 🎯 Organization Principles

### 1. **Root (`/`) — Universal Information**

- Project goal: Cromwell + TES on any cloud Kubernetes
- Platform choices comparison
- General architecture
- Quick reference (all platforms)

### 2. **Component Sections (`/tes`, `/cromwell`, `/karpenter`)**

**Platform-agnostic**, work on any cloud:
- **TES**: Funnel architecture, images, configuration
- **Cromwell**: Backend setup, workflow management
- **Karpenter**: Auto-scaling configuration

**These sections have NO cloud-specific content.**

### 3. **Platform Sections (`/ovh`, `/aws`)**

**Cloud-specific implementations:**
- OVH: Tested, production-ready
- AWS: Template available
- Each points to component sections for detailed info

**These sections link to `/tes`, `/cromwell`, `/karpenter` for deep dives.**

---

## 📚 Navigation Flow

### I want to deploy on OVHcloud

```
Root (/)
  └─> Choose Platform
      └─> OVH (/ovh/)
          ├─> 7-Phase Installation
          ├─> Links to TES (/tes/)
          ├─> Links to Cromwell (/cromwell/)
          └─> Links to Karpenter (/karpenter/)
```

### I want to deploy on AWS

```
Root (/)
  └─> Choose Platform
      └─> AWS (/aws/)
          ├─> AWS Installation (template)
          ├─> Links to TES (/tes/)
          ├─> Links to Cromwell (/cromwell/)
          └─> Links to Karpenter (/karpenter/)
```

### I want to understand TES

```
Root (/)
  └─> TES Section (/tes/)
      ├─> Overview
      ├─> Architecture
      ├─> Images
      ├─> Configuration
      └─> Troubleshooting
```

---

## 🔄 Migration from Old Structure

### Old Files (Root Level)

| Old File | New Location | Status |
|----------|--------------|--------|
| `index_old.md` | Archived | Replaced by new multi-platform index.md |
| `Installation_Guide.md` | `/ovh/installation-guide.md` | Copied (OVH-specific) |
| `CONTAINER_IMAGES.md` | `/tes/container-images.md` | Copied (TES-specific) |
| `OVH_CLI_GUIDE.md` | `/ovh/cli-guide.md` | Copied (OVH-specific) |
| `README_DOCUMENTATION.md` | Archived (old navigation) | Replaced by new index.md |
| `GITHUB_PAGES_SETUP.md` | Root level | Still available for setup |
| `QUICK_REFERENCE.md` | Root level | Universal reference |

### Files at Root Level (Platform-Agnostic)

Remain at root for easy access:
- `index.md` — Main landing page
- `quick-reference.md` — Command cheat sheet
- `_config.yml` — Jekyll configuration
- `GITHUB_PAGES_SETUP.md` — Setup instructions

---

## ✅ Current Status

### Completed

- [x] Root `index.md` (multi-platform landing page)
- [x] `/tes/index.md` (overview)
- [x] `/tes/architecture.md` (design patterns, DaemonSet)
- [x] `/tes/container-images.md` (copied from CONTAINER_IMAGES.md)
- [x] `/cromwell/index.md` (overview)
- [x] `/karpenter/index.md` (overview)
- [x] `/ovh/index.md` (OVH production guide)
- [x] `/ovh/installation-guide.md` (copied from Installation_Guide.md)
- [x] `/ovh/cli-guide.md` (copied from OVH_CLI_GUIDE.md)
- [x] `/aws/index.md` (AWS template)

### In Progress / Templates

- [ ] `/tes/configuration.md` (TEMPLATE)
- [ ] `/tes/troubleshooting.md` (TEMPLATE)
- [ ] `/cromwell/configuration.md` (TEMPLATE)
- [ ] `/cromwell/workflows.md` (TEMPLATE)
- [ ] `/cromwell/tes-integration.md` (TEMPLATE)
- [ ] `/cromwell/troubleshooting.md` (TEMPLATE)
- [ ] `/karpenter/configuration.md` (TEMPLATE)
- [ ] `/karpenter/cloud-providers.md` (TEMPLATE)
- [ ] `/karpenter/troubleshooting.md` (TEMPLATE)
- [ ] `/ovh/cost-and-infrastructure.md` (TEMPLATE)
- [ ] `/ovh/troubleshooting.md` (TEMPLATE)
- [ ] `/aws/*` (all AWS templates)

---

## 🚀 Deployment with New Structure

### Option A: Deploy from `/docs` folder (Recommended)

```bash
mkdir docs
cp -r tes cromwell karpenter ovh aws docs/
cp index.md quick-reference.md _config.yml .nojekyll docs/
```

Then set GitHub Pages:
- Settings → Pages → Source: "Deploy from a branch"
- Branch: "main", Folder: "/docs"

### Option B: Deploy from root

```bash
# Files already at root:
index.md
quick-reference.md
_config.yml
.nojekyll

# Subdirectories at root:
tes/
cromwell/
karpenter/
ovh/
aws/
```

Then set GitHub Pages:
- Settings → Pages → Source: "Deploy from a branch"
- Branch: "main", Folder: "/" (root)

---

## 🔗 Key Links

| Page | URL |
|------|-----|
| **Home** | `/` |
| **TES** | `/tes/` |
| **Cromwell** | `/cromwell/` |
| **Karpenter** | `/karpenter/` |
| **OVHcloud** | `/ovh/` |
| **AWS** | `/aws/` |
| **Quick Reference** | `/quick-reference/` |

---

## 📝 Contributing

To add content:

1. **Platform-agnostic info** → Add to `/tes/`, `/cromwell/`, or `/karpenter/`
2. **OVH-specific info** → Add to `/ovh/`
3. **AWS-specific info** → Add to `/aws/`
4. **General docs** → Add to root level

---

## 💡 Benefits of New Structure

| Aspect | Before | After |
|--------|--------|-------|
| **Clarity** | Mixed cloud-specific & agnostic | Clearly separated |
| **Reusability** | OVH docs tied to OVH | TES/Cromwell work anywhere |
| **Extensibility** | Hard to add new platform | Easy to add `/gcp/`, `/azure/` |
| **Navigation** | Manual cross-linking | Semantic URL structure |
| **Maintenance** | Updates everywhere | Update once in component section |

---

## 🎯 Future Platforms

Easy to add new cloud providers:

```
/gcp/
├── index.md
├── installation-guide.md
├── cli-guide.md
└── troubleshooting.md

/azure/
├── index.md
├── installation-guide.md
├── cli-guide.md
└── troubleshooting.md
```

Each points to `/tes/`, `/cromwell/`, `/karpenter/` for core components.

---

**Status**: ✅ **Reorganization Complete**  
**Last Updated**: March 13, 2026  
**Version**: 2.0 (Multi-platform structure)
