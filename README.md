# GitHub Pages - Cromwell + TES Multi-Platform Documentation

This folder contains the complete documentation for deploying Cromwell (workflow orchestration) + Funnel TES (task execution service) on any cloud Kubernetes cluster.

## 🚀 Quick Start

### 1. Initialize Git (if not already done)

```bash
cd /home/gvandeweyer/VSCode/k8s/github.io
git init
git add .
git commit -m "Initial commit: Cromwell + TES multi-platform documentation"
```

### 2. Connect to GitHub

```bash
git remote add origin https://github.com/YOUR_USERNAME/YOUR_REPO.git
git branch -M main
git push -u origin main
```

### 3. Enable GitHub Pages

1. Go to your repository on GitHub
2. Settings → Pages
3. Build and deployment:
   - Source: "Deploy from a branch"
   - Branch: "main"
   - Folder: "/" (root)
4. Click Save

### 4. Access Your Site

After 2-5 minutes, your site will be available at:
- `https://YOUR_USERNAME.github.io/YOUR_REPO/`
- Or your custom domain if configured

---

## 📂 Directory Structure

```
github.io/
├── index.md                              ← Homepage (landing page)
├── quick-reference.md                    ← Commands cheat sheet
├── PAGES_ORGANIZATION.md                 ← Structure documentation
├── _config.yml                           ← Jekyll configuration
├── .nojekyll                             ← GitHub Pages config
│
├── /tes/                                 ← Platform-agnostic TES
│   ├── index.md                          (overview)
│   ├── architecture.md                   (DaemonSet pattern)
│   └── container-images.md               (custom builds)
│
├── /cromwell/                            ← Platform-agnostic Cromwell
│   ├── index.md                          (overview)
│   ├── cromwell.env                      (environment template)
│   └── cromwell-tes.conf                 (configuration)
│
├── /karpenter/                           ← Platform-agnostic Karpenter
│   └── index.md                          (overview)
│
├── /ovh/                                 ← OVHcloud deployment (PRODUCTION ✅)
│   ├── index.md                          (OVH overview)
│   ├── installation-guide.md             (7-phase setup)
│   └── cli-guide.md                      (OpenStack commands)
│
└── /aws/                                 ← AWS deployment (TEMPLATE)
    └── index.md                          (AWS overview)
```

---

## 📖 Documentation Organization

### **Universal (Root Level)**
- General information about Cromwell + TES
- Platform choices and comparison
- Quick reference for all platforms

### **Platform-Agnostic Components**
- `/tes/` — Funnel TES (Task Execution Service)
- `/cromwell/` — Cromwell (Workflow Orchestration)
- `/karpenter/` — Kubernetes Auto-scaling

These sections work on **any cloud** and are referenced by platform-specific guides.

### **Platform-Specific Sections**
- `/ovh/` — Complete OVHcloud deployment guide (tested, production-ready ✅)
- `/aws/` — AWS template for future implementation

Each platform section links to component sections for detailed information.

---

## 🎯 Navigation

### To Deploy on OVHcloud
1. Start at homepage (`/`)
2. Click "OVHcloud" → `/ovh/`
3. Follow 7-phase installation guide
4. Reference `/tes/`, `/cromwell/`, `/karpenter/` for component details

### To Understand TES
1. Start at homepage (`/`)
2. Click "Funnel TES" → `/tes/`
3. Read overview, architecture, images, troubleshooting

### To Add a New Cloud (AWS, GCP, Azure)
1. Copy `/ovh/` structure to `/aws/`, `/gcp/`, etc.
2. Update cloud-specific commands and configurations
3. Keep `/tes/`, `/cromwell/`, `/karpenter/` unchanged
4. Link to platform-agnostic components

---

## ✨ Key Features

✅ **Multi-platform**: Structured for any cloud provider  
✅ **Component-focused**: Core components documented once, used by all platforms  
✅ **Production-ready**: OVH deployment fully tested  
✅ **Extensible**: Easy to add new clouds  
✅ **Professional**: Jekyll theme with responsive design  
✅ **SEO-optimized**: Proper metadata and structure  

---

## 🔧 Customization

### Change Jekyll Theme

Edit `_config.yml`:
```yaml
theme: jekyll-theme-slate  # or cayman, hacker, midnight, etc.
```

### Update Site Title

Edit `_config.yml`:
```yaml
title: "Your Custom Title"
description: "Your description"
```

### Add Custom Domain

1. Create `CNAME` file in root with your domain
2. Configure DNS records pointing to GitHub Pages
3. In GitHub Settings → Pages → Custom domain: enter your domain

---

## 📚 Content Organization

| Section | Status | Purpose |
|---------|--------|---------|
| Root (/) | ✅ Complete | Universal info, navigation |
| /tes/ | ✅ Complete | Funnel TES (platform-agnostic) |
| /cromwell/ | ✅ Complete | Cromwell (platform-agnostic) |
| /karpenter/ | ✅ Complete | Karpenter (platform-agnostic) |
| /ovh/ | ✅ Production | OVHcloud deployment (tested) |
| /aws/ | 📋 Template | AWS deployment (template) |

---

## 🚀 Deployment Checklist

Before pushing to GitHub:

- [ ] All markdown files have Jekyll front matter (YAML)
- [ ] All permalinks are unique
- [ ] All internal links use Jekyll routes (no `.md` extensions)
- [ ] `_config.yml` has correct `baseurl`
- [ ] `.nojekyll` exists at root
- [ ] All images and assets are in place

Then:

- [ ] `git add .`
- [ ] `git commit -m "docs: Initial multi-platform documentation"`
- [ ] `git push -u origin main`
- [ ] Check GitHub Pages in Settings for build status
- [ ] Wait 2-5 minutes for site to go live

---

## 📞 Support

- **Issues**: GitHub Issues with documentation prefix `[DOCS]`
- **Updates**: Submit PRs with improvements
- **Questions**: Check relevant section or search documentation

---

## 📝 Files Included

### Configuration
- `_config.yml` — Jekyll configuration
- `.nojekyll` — GitHub Pages marker

### Main Pages
- `index.md` — Landing page
- `quick-reference.md` — Commands cheat sheet
- `PAGES_ORGANIZATION.md` — Documentation structure

### Components (Platform-Agnostic)
- `/tes/index.md`, `/tes/architecture.md`, `/tes/container-images.md`
- `/cromwell/index.md`, `/cromwell/cromwell.env`, `/cromwell/cromwell-tes.conf`
- `/karpenter/index.md`

### Platforms
- `/ovh/index.md`, `/ovh/installation-guide.md`, `/ovh/cli-guide.md`
- `/aws/index.md`

---

## 🔗 Related Projects

- **Funnel TES**: https://github.com/ohsu-comp-bio/funnel
- **Cromwell**: https://github.com/broadinstitute/cromwell
- **Karpenter**: https://github.com/aws/karpenter
- **OVH MKS**: https://www.ovhcloud.com/en/public-cloud/kubernetes/

---

## 📄 License

This documentation is provided as-is for educational and operational purposes.

---

**Last Updated**: March 13, 2026  
**Version**: 2.0 (Multi-platform)  
**Status**: ✅ Ready for GitHub Pages deployment
