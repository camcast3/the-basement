# Kubernetes Cluster Plan — Omni + Proxmox Infrastructure Provider

Deploy a Kubernetes cluster on Talos Linux, fully managed by Omni on-prem, with nodes provisioned automatically on Proxmox VE via the Proxmox infrastructure provider.

> **Prerequisite:** Omni must already be running with the Proxmox provider sidecar enabled.
> See [Omni + Authentik Setup Guide](omni-authentik-setup-guide.md) for the initial deployment.

---

## Table of Contents

1. [Omni + Proxmox Provider Setup](#1-omni--proxmox-provider-setup)
2. [Machine Classes](#2-machine-classes)
3. [Cluster Template](#3-cluster-template)
4. [Infrastructure as Code Approach](#4-infrastructure-as-code-approach)
5. [Network Considerations](#5-network-considerations)
6. [Day 2 Operations](#6-day-2-operations)

---

## 1. Omni + Proxmox Provider Setup

### How the Proxmox Infrastructure Provider Works

The Proxmox infrastructure provider is a sidecar container that runs alongside Omni. It bridges Omni's machine lifecycle with the Proxmox VE API:

```
                    ┌───────────────────────────────────┐
                    │  Omni Host (Docker)                │
                    │                                    │
                    │  ┌────────────┐   gRPC   ┌──────┐ │
                    │  │  Proxmox   │◄────────►│ Omni │ │
                    │  │  Provider  │          └──────┘ │
                    │  └─────┬──────┘                    │
                    └────────┼──────────────────────────┘
                             │ Proxmox API (HTTPS :8006)
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
         ┌────────┐    ┌────────┐    ┌────────┐
         │ pve01  │    │ pve02  │    │ pve03  │
         │ .86.2  │    │ .86.3  │    │ .86.4  │
         └────────┘    └────────┘    └────────┘
```

**Flow when Omni creates a cluster:**

1. You apply a cluster template (via `omnictl` or the Omni UI).
2. Omni determines how many machines are needed based on machine classes.
3. The Proxmox provider receives a request to provision a machine.
4. The provider calls the Proxmox API to create a VM with the specified resources.
5. The VM boots from the Talos ISO (automatically attached by the provider).
6. Talos boots and connects back to Omni via SideroLink.
7. Omni configures the Talos node and joins it to the Kubernetes cluster.

### proxmox-config.yaml Structure

The Proxmox provider needs a configuration file that tells it how to talk to the Proxmox cluster and where to place VMs. This file is mounted into the provider container at `/config.yaml`.

The repo includes an Ansible template at `ansible/playbooks/templates/proxmox-config.yaml.j2` that generates the base config. However, for full cluster provisioning the config needs additional fields beyond what the current template provides. The complete structure is:

```yaml
# /opt/omni/proxmox-config.yaml
# Full reference: https://github.com/siderolabs/omni-infra-provider-proxmox

proxmox:
  # Proxmox API endpoint — use any node or the cluster VIP
  url: "https://192.168.86.2:8006/api2/json"

  # Authentication — use a dedicated API token (preferred) or username/password
  # Option A: API token (recommended for automation)
  tokenId: "omni@pve!omni-provider"
  tokenSecret: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  # Option B: Username/password (less secure)
  # username: "omni@pve"
  # password: "secret"
  # realm: pve

  # Skip TLS verification for self-signed Proxmox certs
  insecureSkipVerify: true

  # Storage for VM disks — must exist on all target Proxmox nodes
  storage: "local-lvm"

  # ISO storage — where the Talos ISO is stored/downloaded
  isoStorage: "local"

  # Default network bridge for VM NICs
  bridge: "vmbr0"

  # VLAN tag (optional — omit if not using VLANs)
  # vlanTag: 100

  # Memory ballooning (set to false for predictable resource allocation)
  memoryBallooning: false
```

> **Important:** The current Ansible template (`proxmox-config.yaml.j2`) only generates the `url`, `username`, `password`, `realm`, and `insecureSkipVerify` fields. You will need to extend it or manually add the `storage`, `isoStorage`, `bridge`, and other fields for the provider to work correctly. See [Section 4](#4-infrastructure-as-code-approach) for the proposed IaC approach.

### Service Account Setup

The Proxmox provider authenticates to Omni using a service account key. This key must have the **InfraProvider** role — not Operator or Admin.

1. Log in to Omni at `https://omni.local.example.com`
2. Navigate to **Settings → Service Accounts**
3. Click **Create Service Account**
4. Configure:
   - **Name:** `proxmox_sa`
   - **Role:** **InfraProvider**
5. Copy the generated key immediately (it won't be shown again)
6. Set the key as `OMNI_SERVICE_ACCOUNT_KEY` in the Portainer stack environment variables
7. Redeploy the stack

### Proxmox API Token Setup

Create a dedicated Proxmox user and API token for the infrastructure provider:

```bash
# On any Proxmox node — create user and assign permissions
pveum user add omni@pve --comment "Omni infrastructure provider"
pveum aclmod / -user omni@pve -role PVEVMAdmin
pveum aclmod /storage -user omni@pve -role PVEDatastoreUser

# Create API token (save the output!)
pveum user token add omni@pve omni-provider --privsep 0
```

The `--privsep 0` flag gives the token the same permissions as the user, which is required for VM lifecycle management. The token output will include a `tokenId` and `tokenSecret` — use these in `proxmox-config.yaml`.

---

## 2. Machine Classes

Machine classes define VM resource profiles in Omni. When a cluster template references a machine class, the Proxmox provider uses it to determine the VM specs.

### Resource Plan

| Node Type | vCPUs | RAM | System Disk | Proxmox Placement |
|-----------|-------|-----|-------------|-------------------|
| Control Plane (`cp`) | 4 | 8 GiB | 250 GiB | 1 per host (pve01, pve02, pve03) |
| Worker (`worker`) | 6 | 6 GiB | 500 GiB | 2 per host (pve01, pve02, pve03) |

**Talos Linux minimum requirements** (for reference):
- Control plane: 2 vCPU, 4 GiB RAM, 10 GiB disk
- Worker: 1 vCPU, 2 GiB RAM, 10 GiB disk

Our specs exceed minimums to leave headroom for workloads and etcd performance.

### Per-Host Resource Budget

Each Proxmox host has **32 GiB RAM** and **20 threads** (Intel i9-12900H).

| Component | RAM | vCPU | Notes |
|-----------|-----|------|-------|
| Proxmox host OS | ~2 GiB | ~2 | Hypervisor overhead |
| Ceph OSD | ~8 GiB | ~6 | NVMe-optimized (recommended minimum) |
| 1× Control Plane VM | 8 GiB | 4 | etcd + K8s control plane |
| 2× Worker VMs | 12 GiB | 12 | 6 GiB / 6 vCPU each |
| **Total per host** | **~30 GiB** | **~24** | |
| **Free headroom** | **~2 GiB** | — | CPU overcommit is normal for virtualization |

**pve01 additionally runs the Omni host VM** (VM 100: 2 GiB RAM, 2 vCPU), bringing its total to **~32 GiB RAM, ~26 vCPU** — fully utilized but within budget.

### Machine Class Definitions

Machine classes are Omni resources defined as YAML and applied with `omnictl`.

#### Control Plane Machine Class

```yaml
# kubernetes/clusters/machine-classes/cp.yaml
metadata:
  namespace: default
  type: InfraProviderMachineClasses.omni.sidero.dev
  id: cp
spec:
  provider: proxmox_provider
  cores: 4
  memory: 8192        # MiB
  diskSize: 262144     # MiB (250 GiB)
  # Optional: pin to a specific Proxmox node
  # proxmoxNode: pve01
```

#### Worker Machine Class

```yaml
# kubernetes/clusters/machine-classes/worker.yaml
metadata:
  namespace: default
  type: InfraProviderMachineClasses.omni.sidero.dev
  id: worker
spec:
  provider: proxmox_provider
  cores: 6
  memory: 6144         # MiB
  diskSize: 524288     # MiB (500 GiB)
  # With 6 workers across 3 hosts, workers are distributed 2 per host
  # To force placement, use proxmoxNode per-machine or anti-affinity
```

### Applying Machine Classes

```bash
omnictl apply -f kubernetes/clusters/machine-classes/cp.yaml
omnictl apply -f kubernetes/clusters/machine-classes/worker.yaml

# Verify
omnictl get infraproviderstatuses
```

---

## 3. Cluster Template

Omni cluster templates define the desired state of a Kubernetes cluster: how many nodes, which machine classes, and which Talos/Kubernetes versions to use.

### Cluster Template Definition

```yaml
# kubernetes/clusters/k8s-homelab/cluster-template.yaml
kind: Cluster
name: k8s-homelab
kubernetes:
  version: v1.32.3
talos:
  version: v1.9.5
patches:
  - name: cluster-wide-patches
    inline:
      cluster:
        # Pod CIDR (default: 10.244.0.0/16)
        clusterNetwork:
          podSubnets:
            - 10.244.0.0/16
          serviceSubnets:
            - 10.96.0.0/12
        # Allow scheduling on control plane (optional for homelab)
        allowSchedulingOnControlPlanes: false
controlPlanes:
  - name: control-planes
    machineClass:
      name: cp
      size: 3
workers:
  - name: workers
    machineClass:
      name: worker
      size: 6
```

> **Version selection:** Check compatible Talos/Kubernetes version pairs at
> [Talos support matrix](https://www.talos.dev/latest/introduction/support-matrix/).
> Omni also shows available versions in the UI under cluster creation.

### Applying the Cluster Template

```bash
# Apply machine classes first
omnictl apply -f kubernetes/clusters/machine-classes/cp.yaml
omnictl apply -f kubernetes/clusters/machine-classes/worker.yaml

# Create the cluster
omnictl cluster template sync -f kubernetes/clusters/k8s-homelab/cluster-template.yaml

# Monitor provisioning progress
omnictl get machines --watch

# Once the cluster is ready, get the kubeconfig
omnictl kubeconfig -c k8s-homelab > ~/.kube/config-k8s-homelab
export KUBECONFIG=~/.kube/config-k8s-homelab

# Verify the cluster
kubectl get nodes
kubectl get pods -A
```

### What Happens After `apply`

1. Omni reads the cluster template and determines 9 machines are needed (3 CP + 6 workers).
2. The Proxmox provider creates 9 VMs across the Proxmox cluster using the machine class specs.
3. Each VM boots from the Talos ISO, downloads its config from Omni, and joins the cluster.
4. Omni reports the cluster as ready once all nodes are healthy and Kubernetes components are running.

Typical provisioning time: **5–10 minutes** for a 9-node cluster.

### Deleting the Cluster

```bash
# This destroys all VMs and removes the cluster from Omni
omnictl cluster template delete -f kubernetes/clusters/k8s-homelab/cluster-template.yaml

# Or delete by name
omnictl cluster delete k8s-homelab
```

---

## 4. Infrastructure as Code Approach

### Proposed Directory Structure

```
the-basement/
├── ansible/
│   ├── playbooks/
│   │   ├── setup-omni-cluster.yaml          # Omni host prep (existing)
│   │   └── templates/
│   │       └── proxmox-config.yaml.j2       # Proxmox provider config (existing)
│   └── inventory/
├── docker/
│   └── omni/
│       ├── compose.yaml                      # Omni + provider (existing)
│       └── .env.example                      # Env vars reference (existing)
├── kubernetes/
│   ├── clusters/
│   │   ├── machine-classes/
│   │   │   ├── cp.yaml                       # Control plane machine class
│   │   │   └── worker.yaml                   # Worker machine class
│   │   └── k8s-homelab/
│   │       └── cluster-template.yaml         # Cluster definition
│   ├── apps/                                 # Application manifests / Helm values
│   │   └── .gitkeep
│   └── infrastructure/                       # Cluster infra components
│       ├── flux-system/                      # Flux bootstrap (if using Flux)
│       ├── cert-manager/
│       ├── ingress-nginx/
│       └── metallb/
└── docs/
    ├── omni-authentik-setup-guide.md         # Omni setup (existing)
    └── k8s-omni-proxmox-plan.md             # This document
```

### omnictl vs Omni UI

| Task | omnictl (CLI) | Omni UI |
|------|--------------|---------|
| Create machine classes | ✅ `omnictl apply -f` | ✅ Manual form |
| Create clusters | ✅ `omnictl cluster template sync` | ✅ Wizard |
| Scale nodes | ✅ Edit template + re-sync | ✅ Click to scale |
| Upgrade Talos/K8s | ✅ Edit template + re-sync | ✅ One-click upgrade |
| Monitor nodes | ✅ `omnictl get machines` | ✅ Dashboard |
| Get kubeconfig | ✅ `omnictl kubeconfig` | ✅ Download button |
| Automation / CI | ✅ Scriptable, idempotent | ❌ Not automatable |

**Recommendation:** Use `omnictl` for all declarative operations. Store all YAML in Git. Use the Omni UI for monitoring, troubleshooting, and one-off tasks. This gives you reproducibility (everything is in the repo) with a visual dashboard for day-to-day observation.

### omnictl Configuration

Configure `omnictl` to connect to your Omni instance:

```bash
# Set the Omni endpoint
omnictl config set omni-url https://omni.local.example.com

# Authenticate (opens browser for SAML login)
omnictl auth login

# Verify connection
omnictl get clusters
```

For CI/CD automation, use a service account key instead of interactive login:

```bash
export OMNI_ENDPOINT=https://omni.local.example.com
export OMNI_SERVICE_ACCOUNT_KEY=<key-from-omni-ui>
omnictl get clusters
```

### GitOps for Workload Management

Once the cluster is running, use a GitOps controller to manage workloads declaratively.

**Flux CD** (recommended for simplicity):

```bash
# Bootstrap Flux into the cluster, pointing at this repo
flux bootstrap github \
  --owner=<github-user> \
  --repository=the-basement \
  --branch=main \
  --path=kubernetes/apps \
  --personal

# Flux will reconcile all manifests under kubernetes/apps/ automatically
```

**ArgoCD** (alternative — more UI-oriented):

```bash
# Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Create an Application pointing at the repo
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<user>/the-basement.git
    targetRevision: main
    path: kubernetes/apps
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
```

**Which to choose?**
- **Flux** if you prefer a lightweight, Git-native approach with no extra UI.
- **ArgoCD** if you want a dashboard to visualize sync status and app health.

Both work well with Omni-managed clusters since the kubeconfig is standard.

---

## 5. Network Considerations

### Omni ↔ Talos Node Connectivity

Talos nodes (VMs on Proxmox) must be able to reach the Omni host on these ports:

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 8090 | TCP (TLS) | Talos → Omni | SideroLink API (node registration, config) |
| 8100 | TCP (TLS) | Talos → Omni | Kubernetes API proxy |
| 50180 | UDP | Bidirectional | WireGuard tunnel (Omni ↔ nodes) |

These ports are exposed directly on the Omni host IP (not through Traefik). Ensure no firewall rules block them on the `192.168.86.0/24` network.

### VM Network Configuration

All Talos VMs are attached to bridge `vmbr0` on their respective Proxmox hosts, placing them on the same `192.168.86.0/24` LAN.

| Address Source | Details |
|---------------|---------|
| **DHCP** (simpler) | Talos VMs get IPs from the network's DHCP server. Works well if your DHCP server has enough leases available. |
| **Static** (more control) | Assign IPs via Talos machine config patches in the cluster template. Useful for stable DNS entries. |

**DHCP is recommended** for a homelab unless you need predictable IPs. Omni identifies nodes by machine ID, not IP address.

### IP Address Map

| Host | IP | Role |
|------|----|------|
| pve01 | 192.168.86.2 | Proxmox node (hosts omni-host VM) |
| pve02 | 192.168.86.3 | Proxmox node |
| pve03 | 192.168.86.4 | Proxmox node |
| omni-host | 192.168.86.10 | Omni + Proxmox provider (VM on pve01) |
| K8s CP-1 | DHCP | Talos control plane (pve01) |
| K8s CP-2 | DHCP | Talos control plane (pve02) |
| K8s CP-3 | DHCP | Talos control plane (pve03) |
| K8s Worker-1 | DHCP | Talos worker (pve01) |
| K8s Worker-2 | DHCP | Talos worker (pve01) |
| K8s Worker-3 | DHCP | Talos worker (pve02) |
| K8s Worker-4 | DHCP | Talos worker (pve02) |
| K8s Worker-5 | DHCP | Talos worker (pve03) |
| K8s Worker-6 | DHCP | Talos worker (pve03) |

### Kubernetes Network CIDRs

| Network | CIDR | Purpose |
|---------|------|---------|
| Pod network | `10.244.0.0/16` | Pod-to-pod communication (CNI — Flannel by default on Talos) |
| Service network | `10.96.0.0/12` | ClusterIP services |
| Node network | `192.168.86.0/24` | Physical/VM network |

These CIDRs must not overlap with each other or with any existing subnets on your network. The defaults above are standard and should work unless you have conflicting ranges.

### DNS

Talos nodes need to resolve:
- `omni.local.example.com` → Omni host IP (for SideroLink)
- External DNS for pulling container images

Ensure your local DNS server (or `/etc/hosts` equivalent in Talos machine config) resolves the Omni domain. If using split-horizon DNS, verify that Talos nodes resolve to the internal IP, not an external one.

---

## 6. Day 2 Operations

### Scaling Workers

To add or remove worker nodes, edit the cluster template and re-sync:

```yaml
# kubernetes/clusters/k8s-homelab/cluster-template.yaml
workers:
  - name: workers
    machineClass:
      name: worker
      size: 8   # Changed from 6 → 8
```

```bash
omnictl cluster template sync -f kubernetes/clusters/k8s-homelab/cluster-template.yaml
```

Omni will instruct the Proxmox provider to create a new VM. The node boots Talos, joins the cluster, and becomes schedulable automatically.

To scale down, reduce the `size` value. Omni will cordon, drain, and destroy the extra node(s).

### Upgrading Talos

Update the Talos version in the cluster template:

```yaml
talos:
  version: v1.10.0   # Updated from v1.9.5
```

```bash
omnictl cluster template sync -f kubernetes/clusters/k8s-homelab/cluster-template.yaml
```

Omni performs a rolling upgrade — one node at a time, waiting for each to rejoin healthy before proceeding. Control plane nodes are upgraded first, then workers.

**Via Omni UI:** Navigate to the cluster → click **Upgrade Talos** → select the new version.

### Upgrading Kubernetes

Update the Kubernetes version in the cluster template:

```yaml
kubernetes:
  version: v1.33.0   # Updated from v1.32.3
```

```bash
omnictl cluster template sync -f kubernetes/clusters/k8s-homelab/cluster-template.yaml
```

Omni handles the Kubernetes upgrade by updating components in the correct order (API server, controller manager, scheduler, then kubelets). Always check the [Talos support matrix](https://www.talos.dev/latest/introduction/support-matrix/) for compatible Talos + Kubernetes version pairs.

### Backup Strategy

| Component | What to Back Up | How |
|-----------|----------------|-----|
| **Omni state** | `/opt/omni/omni.db`, `/opt/omni/etcd/` | Snapshot the omni-host VM or rsync to NAS |
| **Omni encryption key** | `/opt/omni/omni.asc` | Copy to secure offline storage (needed to restore etcd) |
| **Cluster templates** | `kubernetes/clusters/` | Already in Git |
| **Kubernetes workloads** | App manifests in `kubernetes/apps/` | Already in Git (via GitOps) |
| **Persistent volumes** | PVC data on worker nodes | Use Velero or storage-level snapshots |
| **etcd (Kubernetes)** | Managed by Talos/Omni | Omni handles etcd snapshots; can also use `talosctl etcd snapshot` |

**Recommended backup schedule:**
- **Omni host VM snapshot:** Weekly (or before upgrades)
- **Git push:** After every change (CI/CD handles this)
- **PV backups (Velero):** Daily for stateful workloads

### Disaster Recovery

If the Omni host is lost:
1. Restore the VM from snapshot (or reprovision with Ansible + restore `/opt/omni` data).
2. Existing Talos nodes will automatically reconnect to Omni via SideroLink once it's back online.
3. The Kubernetes cluster continues to run independently of Omni — Omni is the management plane, not the data plane.

If a Talos node is lost:
1. Omni detects the missing node and marks it unhealthy.
2. For workers: scale up the cluster template to replace the node. The Proxmox provider creates a new VM.
3. For control plane: with 3 CP nodes, etcd has full HA and can survive 1 CP failure without data loss. If 2 CPs are lost, restore quorum from etcd snapshot.

---

## Quick Reference — Commands

```bash
# --- omnictl basics ---
omnictl config set omni-url https://omni.local.example.com
omnictl auth login

# --- Machine classes ---
omnictl apply -f kubernetes/clusters/machine-classes/cp.yaml
omnictl apply -f kubernetes/clusters/machine-classes/worker.yaml
omnictl get infraproviderstatuses

# --- Cluster lifecycle ---
omnictl cluster template sync -f kubernetes/clusters/k8s-homelab/cluster-template.yaml
omnictl cluster template delete -f kubernetes/clusters/k8s-homelab/cluster-template.yaml
omnictl get clusters
omnictl get machines

# --- Kubeconfig ---
omnictl kubeconfig -c k8s-homelab > ~/.kube/config-k8s-homelab
export KUBECONFIG=~/.kube/config-k8s-homelab
kubectl get nodes

# --- Upgrades ---
# Edit cluster-template.yaml, then:
omnictl cluster template sync -f kubernetes/clusters/k8s-homelab/cluster-template.yaml
```
