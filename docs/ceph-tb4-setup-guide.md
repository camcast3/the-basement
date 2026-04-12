# Ceph Cluster Setup on Proxmox 9 — Thunderbolt 4 Mesh Network

> **Runbook** for deploying a 3-node hyper-converged Ceph cluster on the k8s-homelab Proxmox cluster, using a Thunderbolt 4 ring topology for OSD replication traffic.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Network Diagram](#network-diagram)
- [1. Install Ceph Packages](#1-install-ceph-packages)
- [2. Initialize Ceph on the First Node](#2-initialize-ceph-on-the-first-node)
- [3. Create Monitors](#3-create-monitors)
- [4. Create Managers](#4-create-managers)
- [5. Create OSDs](#5-create-osds)
- [6. Create Storage Pools](#6-create-storage-pools)
- [7. Verify Ceph Health](#7-verify-ceph-health)
- [8. Add Ceph Storage to Proxmox](#8-add-ceph-storage-to-proxmox)
- [9. Kubernetes Storage Integration](#9-kubernetes-storage-integration)
- [10. Performance Tuning](#10-performance-tuning)
- [Troubleshooting](#troubleshooting)
- [References](#references)

---

## Prerequisites

### Hardware

| Node   | CPU              | RAM   | OS Drive (Proxmox)      | Ceph OSD Drive          |
|--------|------------------|-------|-------------------------|-------------------------|
| pve01  | Intel i9-12900H  | 32 GB | TEAM TM8FPK002T 1.9T (`/dev/nvme1n1`) | Samsung 990 PRO 1.8T (`/dev/nvme0n1`) |
| pve02  | Intel i9-12900H  | 32 GB | TEAM TM8FPK002T 1.9T (`/dev/nvme0n1`) | Samsung 990 PRO 1.8T (`/dev/nvme1n1`) |
| pve03  | Intel i9-12900H  | 32 GB | TEAM TM8FPK002T 1.9T (`/dev/nvme1n1`) | Samsung 990 PRO 1.8T (`/dev/nvme0n1`) |

> **📝 Note:** pve01 and pve03 have Samsung on `nvme0n1`; pve02 has Samsung on `nvme1n1`. Always verify with `lsblk -d -o NAME,MODEL` before creating OSDs.

#### M.2 Slot Layout

Each mini PC has three M.2 slots with different PCIe capabilities:

| Slot Location | Interface | Bandwidth | Current Drive | Recommended Drive |
|---------------|-----------|-----------|---------------|-------------------|
| **Left** (near U.2 switch) | PCIe 4.0 x4 | ~14 GB/s | Samsung 990 PRO (Ceph OSD) ✅ | Samsung 990 PRO (Ceph OSD) |
| **Middle** | PCIe 3.0 x4 | ~4 GB/s | TEAM TM8FPK002T (OS) ✅ | TEAM TM8FPK002T (OS) |
| **Right** (near WiFi) | PCIe 3.0 x2 | ~2 GB/s | *empty* | *empty* |

> **✅ Verified:** Samsung 990 PRO drives are in the Left slot (PCIe 4.0 x4), negotiating at
> full Gen 4 speed (16 GT/s x4 ≈ 14 GB/s). Confirmed via `lspci -vv` on all 3 nodes.

### Cluster & Network

- **Proxmox cluster**: `k8s-homelab` — all 3 nodes joined and healthy.
- **Management network** (`vmbr0`): `192.168.86.0/24` — client I/O, monitor traffic, Proxmox web UI.
- **Thunderbolt 4 mesh network**: `10.100.0.0/24` — dedicated OSD replication traffic at up to 40 Gbps per link, MTU 65520.
- **Proxmox version**: 9.1+ (Debian Bookworm base).
- Ceph packages are **not yet installed**.

### TB4 Mesh — What's Already Configured

The Thunderbolt 4 ring topology is fully configured, tested, and persistent across reboots. Each link uses a /30 subnet with jumbo frames (MTU 65520):

| Link          | Node A (interface → IP)   | Node B (interface → IP)   | Subnet          |
|---------------|---------------------------|---------------------------|-----------------|
| pve01 ↔ pve02 | pve01 `en06` → 10.100.0.1 | pve02 `en05` → 10.100.0.2 | 10.100.0.0/30   |
| pve02 ↔ pve03 | pve02 `en06` → 10.100.0.5 | pve03 `en05` → 10.100.0.6 | 10.100.0.4/30   |
| pve03 ↔ pve01 | pve03 `en06` → 10.100.0.9 | pve01 `en05` → 10.100.0.10| 10.100.0.8/30   |

---

## Network Diagram

```
                    ┌─────────────────────────────┐
                    │     Management Network       │
                    │     192.168.86.0/24 (vmbr0)  │
                    │   (public_network for Ceph)  │
                    └──────┬──────┬──────┬─────────┘
                           │      │      │
                     .21   │      │ .22  │ .23
                    ┌──────┴──┐┌──┴─────┐┌┴─────────┐
                    │  pve01  ││  pve02  ││  pve03   │
                    │ i9-12900H││ i9-12900H││ i9-12900H│
                    │  32 GB  ││  32 GB  ││  32 GB   │
                    │         ││         ││          │
                    │ OSD:    ││ OSD:    ││ OSD:     │
                    │ nvme0n1 ││ nvme1n1 ││ nvme0n1  │
                    │ 990 PRO ││ 990 PRO ││ 990 PRO  │
                    └──┬───┬──┘└──┬───┬──┘└──┬───┬───┘
                       │   │      │   │      │   │
              en06     │   │ en05 │   │ en06 │   │ en05
          10.100.0.1   │   │10.100│   │10.100│   │10.100.0.6
                       │   │ .0.10│   │ .0.5 │   │
                       │   │      │   │      │   │
    ┌──────────────────┘   │      │   │      │   └──────────────────┐
    │   TB4 Link           │      │   │      │       TB4 Link       │
    │   10.100.0.0/30      │      │   │      │       10.100.0.4/30  │
    │   (pve01 ↔ pve02)    │      │   │      │       (pve02 ↔ pve03)│
    └──────────────────────│──────┘   └──────│──────────────────────┘
                           │                 │
                           │  TB4 Link       │
                           │  10.100.0.8/30  │
                           │  (pve03 ↔ pve01)│
                           │                 │
                           │  en05       en06 │
                           │  10.100.0.10  10.100.0.9
                           └─────────────────┘

    ════════════════════════════════════════════════════
     Thunderbolt 4 Ring (cluster_network 10.100.0.0/24)
      • 40 Gbps per link  •  MTU 65520  •  /30 subnets
    ════════════════════════════════════════════════════
```

---

## 1. Install Ceph Packages

Install Ceph on **all 3 nodes**. Run the following command on each node (pve01, pve02, pve03):

```bash
pveceph install --repository no-subscription
```

This installs the Ceph packages from the no-subscription repository (suitable for homelab use without a Proxmox enterprise subscription).

**What this does:**
- Adds the Ceph apt repository to the node.
- Installs `ceph`, `ceph-mds`, `ceph-fuse`, and related packages.
- The `--repository no-subscription` flag selects the free community repository rather than the enterprise one.

**Verify on each node:**

```bash
ceph --version
```

You should see output like `ceph version 18.x.x (reef)` or the version matching your Proxmox 9.x release.

> **💡 Tip:** You can run this in parallel across all 3 nodes since each installation is independent. Use SSH or open the shell for each node in the Proxmox web UI.

---

## 2. Initialize Ceph on the First Node

Run the following on **pve01 only** to initialize the Ceph cluster:

```bash
pveceph init --network 192.168.86.0/24 --cluster-network 10.100.0.0/24
```

### What the Networks Mean

| Parameter          | Value                | Purpose                                                    |
|--------------------|----------------------|------------------------------------------------------------|
| `--network`        | `192.168.86.0/24`    | **public_network** — Client I/O (VM disk reads/writes), monitor communication, and manager traffic. This is the management LAN that all Proxmox nodes and VMs share. |
| `--cluster-network`| `10.100.0.0/24`      | **cluster_network** — OSD-to-OSD replication, recovery, backfill, and heartbeat traffic. This runs over the dedicated Thunderbolt 4 mesh at 40 Gbps with jumbo frames (MTU 65520). |

### Why This Separation Matters

- **Performance**: OSD replication is the most bandwidth-intensive Ceph operation. By offloading it to the TB4 mesh (40 Gbps, MTU 65520), client I/O on the management network remains uncontested.
- **Latency**: TB4 is a direct point-to-point connection with no switch hops, providing sub-millisecond latency for replication.
- **Reliability**: If the management switch goes down, OSD replication traffic continues uninterrupted over TB4 (and vice versa).

### What This Creates

- `/etc/ceph/ceph.conf` — Ceph configuration file with the network settings.
- `/etc/pve/ceph.conf` — Proxmox-managed copy (synced across the cluster via pmxcfs).
- A Ceph cluster FSID (unique cluster identifier).

**Verify:**

```bash
cat /etc/pve/ceph.conf
```

You should see:

```ini
[global]
   auth_client_required = cephx
   auth_cluster_required = cephx
   auth_service_required = cephx
   cluster_network = 10.100.0.0/24
   fsid = <auto-generated-uuid>
   mon_allow_pool_delete = true
   ms_bind_ipv4 = true
   ms_bind_ipv6 = false
   osd_pool_default_min_size = 2
   osd_pool_default_size = 3
   public_network = 192.168.86.0/24
```

---

## 3. Create Monitors

Ceph Monitors (MONs) maintain the cluster map and consensus. You need an **odd number** (3 is ideal) for quorum. Create one monitor on each node.

### pve01 (already has one from `pveceph init`)

A monitor is automatically created on the init node. Verify:

```bash
ceph mon stat
```

### pve02

Run on **pve02** (or from the Proxmox web UI → pve02 → Ceph → Monitor → Create):

```bash
pveceph mon create
```

### pve03

Run on **pve03**:

```bash
pveceph mon create
```

### Verify All Monitors

```bash
ceph mon stat
```

Expected output:

```
e3: 3 mons at {pve01=[v2:192.168.86.21:3300/0,v1:192.168.86.21:6789/0],
                pve02=[v2:192.168.86.22:3300/0,v1:192.168.86.22:6789/0],
                pve03=[v2:192.168.86.23:3300/0,v1:192.168.86.23:6789/0]},
election epoch 6, leader 0 pve01, quorum 0,1,2 pve01,pve02,pve03
```

> **📝 Note:** Monitors bind on the **public_network** (192.168.86.0/24), not the cluster network. This is by design — clients and OSDs need to reach monitors via the public network.

---

## 4. Create Managers

Ceph Managers (MGRs) provide monitoring, orchestration, and plugin services (dashboard, Prometheus metrics, etc.). Create one on each node for high availability.

### pve01

```bash
pveceph mgr create
```

### pve02

```bash
pveceph mgr create
```

### pve03

```bash
pveceph mgr create
```

### Verify All Managers

```bash
ceph mgr stat
```

Expected output:

```json
{
    "epoch": 5,
    "available": true,
    "active_name": "pve01",
    "num_standby": 2
}
```

One manager will be `active`; the other two are on `standby` and will take over automatically if the active one fails.

---

## 5. Create OSDs

An OSD (Object Storage Daemon) manages a single storage device. Create one OSD per node on the Samsung 990 PRO NVMe drive.

> **⚠️ CRITICAL:** The OSD creation process will **wipe the target drive completely**. Triple-check you are targeting the correct device before proceeding!

### Identify the Correct Drives

Before creating OSDs, confirm the correct device on each node:

```bash
# Run on each node to list NVMe devices and verify serial numbers
lsblk -d -o NAME,SIZE,MODEL,SERIAL | grep nvme
```

| Node   | OSD Device      | Model           | Approximate Size |
|--------|-----------------|-----------------|------------------|
| pve01  | `/dev/nvme0n1`  | Samsung 990 PRO | 1.8T             |
| pve02  | `/dev/nvme1n1`  | Samsung 990 PRO | 1.8T             |
| pve03  | `/dev/nvme0n1`  | Samsung 990 PRO | 1.8T             |

### Create OSD on pve01

Run on **pve01**:

```bash
pveceph osd create /dev/nvme0n1
```

### Create OSD on pve02

Run on **pve02**:

```bash
# pve02 has Samsung on nvme1n1 (opposite of pve01/pve03)
pveceph osd create /dev/nvme1n1
```

### Create OSD on pve03

Run on **pve03**:

```bash
pveceph osd create /dev/nvme0n1
```

### What `pveceph osd create` Does

1. Wipes the target device.
2. Creates a GPT partition table.
3. Formats the device with BlueStore (Ceph's default object store backend).
4. Starts the OSD daemon (`ceph-osd@<id>.service`).
5. Registers the OSD with the Ceph cluster.

### Verify OSDs

```bash
ceph osd tree
```

Expected output:

```
ID  CLASS  WEIGHT   TYPE NAME       STATUS  REWEIGHT  PRI-AFF
-1         5.24658  root default
-3         1.74886      host pve01
 0    ssd  1.74886          osd.0       up   1.00000  1.00000
-5         1.74886      host pve02
 1    ssd  1.74886          osd.1       up   1.00000  1.00000
-7         1.74886      host pve03
 2    ssd  1.74886          osd.2       up   1.00000  1.00000
```

All 3 OSDs should show `up` status and be classified as `ssd`.

---

## 6. Create Storage Pools

You need pools for VM/container storage and Kubernetes workloads. The pools below are organized by workload type: **RBD** (block storage for VM disks and K8s PVCs), **CephFS** (POSIX filesystem for shared storage), and **RGW** (S3-compatible object storage).

### Pool A: `ceph-block` — General RBD Pool (VM Disks & K8s PVCs)

This is the primary pool for Proxmox VM disk images and general Kubernetes persistent volumes (SQL databases, stateful apps).

**Via Proxmox Web UI:**

1. Navigate to **Datacenter → pve01 → Ceph → Pools**.
2. Click **Create**.
3. Set:
   - **Name**: `ceph-block`
   - **Size**: `3` (3 replicas — one copy on each node)
   - **Min. Size**: `2` (cluster stays operational if 1 node is down)
   - **Add as Storage**: ✅ checked
4. Click **Create**.

**Via CLI (on any node):**

```bash
# Create the general block storage pool
pveceph pool create ceph-block --size 3 --min_size 2 --pg_autoscale_mode on --add_storages 1
```

**Parameters explained:**

| Parameter             | Value | Meaning                                                     |
|-----------------------|-------|-------------------------------------------------------------|
| `--size`              | 3     | Store 3 copies of every object (one per node). Full redundancy. |
| `--min_size`          | 2     | Allow I/O to continue with only 2 copies available (1 node down). |
| `--pg_autoscale_mode` | on    | Let Ceph automatically adjust placement groups as data grows. |
| `--add_storages`      | 1     | Automatically register the pool as Proxmox storage.          |

### Pool B: `ceph-block-fast` — Low-Latency RBD Pool (Redis, Caches)

A separate pool for latency-sensitive workloads like Redis and other caches. Uses `size=2` to reduce write amplification (2 writes instead of 3), trading some redundancy for lower latency.

**Via CLI:**

```bash
pveceph pool create ceph-block-fast --size 2 --min_size 1 --pg_autoscale_mode on
```

| Parameter    | Value | Meaning                                                                  |
|--------------|-------|--------------------------------------------------------------------------|
| `--size`     | 2     | 2 replicas — lower write amplification means lower latency per write.    |
| `--min_size` | 1     | Allow I/O with a single copy (use only for ephemeral/cache data).        |

> **⚠️ Warning:** This pool tolerates 1 node failure but with only 1 surviving copy. Only use it for data that can be rebuilt (caches, session stores). SQL databases should use `ceph-block` with full 3-way replication.

### Pool C: `ceph-rgw` — Object Storage Pool (S3 via RADOS Gateway)

Pool backing the Ceph Object Gateway for S3-compatible storage. RGW creates additional internal pools on first start, but this pool is the primary data pool.

**Via CLI:**

```bash
# Create the RGW data pool
ceph osd pool create ceph-rgw 32 32 replicated
ceph osd pool set ceph-rgw size 3
ceph osd pool set ceph-rgw min_size 2
ceph osd pool set ceph-rgw pg_autoscale_mode on
```

> **📝 Note:** RGW will also create `.rgw.root`, `default.rgw.log`, `default.rgw.control`, `default.rgw.meta`, and `default.rgw.buckets.data` pools automatically when it starts. These are managed by RGW and should not be modified manually.

### Pool D: CephFS (For Shared Filesystem)

CephFS provides a POSIX filesystem that can be mounted by multiple VMs/containers simultaneously. Useful for shared data, container templates, or ISO storage.

**Step 1: Create a Metadata Server (MDS) on each node:**

```bash
# Run on each node
pveceph mds create
```

**Step 2: Create the CephFS:**

**Via Proxmox Web UI:**

1. Navigate to **Datacenter → pve01 → Ceph → CephFS**.
2. Click **Create CephFS**.
3. Set:
   - **Name**: `cephfs`
   - **Placement Groups**: leave default (let autoscaler handle it)
   - **Add as Storage**: ✅ checked
4. Click **Create**.

**Via CLI:**

```bash
pveceph fs create --name cephfs --pg_num 64 --add-storage 1
```

This creates two pools behind the scenes:
- `cephfs_data` — stores file data (size=3, min_size=2 by default).
- `cephfs_metadata` — stores filesystem metadata.

### Verify Pool(s)

```bash
ceph osd pool ls detail
```

---

## 7. Verify Ceph Health

After all components are deployed, run these verification commands from **any node**:

### Cluster Status

```bash
ceph status
```

Expected healthy output:

```
  cluster:
    id:     <fsid>
    health: HEALTH_OK

  services:
    mon: 3 daemons, quorum pve01,pve02,pve03 (age ...)
    mgr: pve01(active, since ...), standbys: pve02, pve03
    osd: 3 osds: 3 up (since ...), 3 in (since ...)

  data:
    pools:   1 pools, 1 pgs
    objects: 0 objects, 0 B
    usage:   3.0 GiB used, 5.2 TiB / 5.2 TiB avail
    pgs:     1 active+clean
```

The key indicator is **`HEALTH_OK`**. If you see `HEALTH_WARN`, check the warning messages — some are benign at initial setup (e.g., "mons are allowing insecure global_id reclaim").

### OSD Tree

```bash
ceph osd tree
```

Verify all 3 OSDs are `up` and distributed one-per-host.

### Storage Usage

```bash
ceph df
```

Shows raw capacity and per-pool usage.

### OSD Performance Stats

```bash
ceph osd perf
```

Shows commit and apply latency for each OSD. On NVMe, expect sub-millisecond values.

### Network Verification

Confirm replication traffic is using the TB4 cluster network:

```bash
ceph osd find 0 | grep -A5 cluster_addrs
ceph osd find 1 | grep -A5 cluster_addrs
ceph osd find 2 | grep -A5 cluster_addrs
```

The `cluster_addrs` should show `10.100.0.x` addresses (TB4 mesh), not `192.168.86.x`.

### Quick Bench Test

Run a simple benchmark to confirm end-to-end functionality:

```bash
# Write test (creates a temporary pool, runs bench, cleans up)
rados bench -p ceph-block 30 write --no-cleanup
# Read test
rados bench -p ceph-block 30 seq
# Cleanup
rados -p ceph-block cleanup
```

---

## 8. Add Ceph Storage to Proxmox

If you used `--add_storages 1` during pool creation, the pool is already registered. Otherwise, add it manually.

### RBD Storage

**Via Proxmox Web UI:**

1. Navigate to **Datacenter → Storage → Add → RBD**.
2. Set:
   - **ID**: `ceph-block`
   - **Pool**: `ceph-block`
   - **Monitor(s)**: auto-detected
   - **Content**: `Disk image, Container` (select what you need)
3. Click **Add**.

**Via CLI:**

```bash
pvesm add rbd ceph-block --pool ceph-block --content images,rootdir
```

### CephFS Storage

**Via Proxmox Web UI:**

1. Navigate to **Datacenter → Storage → Add → CephFS**.
2. Set:
   - **ID**: `cephfs`
   - **Monitor(s)**: auto-detected
   - **Content**: as needed (ISO images, Container templates, Snippets, etc.)
3. Click **Add**.

**Via CLI:**

```bash
pvesm add cephfs cephfs --content iso,vztmpl,snippets
```

### Verify Storage in Proxmox

```bash
pvesm status
```

The Ceph storage should appear as `active` with the correct total/available space.

You can now create VMs and containers using Ceph-backed storage. When creating a VM disk, select the `ceph-block` storage in the disk configuration dialog.

---

## 9. Kubernetes Storage Integration

This section covers connecting the Ceph cluster to a Kubernetes cluster (3 control planes + 6 workers on Talos Linux via Omni) for persistent storage. The setup provides block storage (RBD), shared filesystem (CephFS), and S3-compatible object storage (RGW).

### Ceph CSI Driver for Kubernetes

The [Ceph CSI driver](https://github.com/ceph/ceph-csi) allows Kubernetes to dynamically provision and mount Ceph volumes. You need two components: **RBD CSI** (for block storage) and **CephFS CSI** (for shared filesystems).

#### Step 1: Create Ceph User for Kubernetes

On any Ceph/Proxmox node, create a dedicated CephX user for Kubernetes CSI access:

```bash
# Create a user with access to the block and CephFS pools
ceph auth get-or-create client.kubernetes \
  mon 'profile rbd, allow r' \
  osd 'profile rbd pool=ceph-block, profile rbd pool=ceph-block-fast, allow rwx pool=cephfs_data' \
  mds 'allow rw' \
  -o /etc/ceph/ceph.client.kubernetes.keyring
```

Retrieve the key and cluster ID for Kubernetes secrets:

```bash
# Get the user key
ceph auth get-key client.kubernetes

# Get the cluster FSID
ceph fsid

# Get monitor addresses
ceph mon dump | grep "mon\." | awk '{print $2}' | sed 's|/0||'
```

#### Step 2: Deploy Ceph CSI Driver via Helm

On a machine with `kubectl` and `helm` configured for your K8s cluster:

```bash
# Add the Ceph CSI Helm repo
helm repo add ceph-csi https://ceph.github.io/csi-charts
helm repo update

# Create namespace
kubectl create namespace ceph-csi

# Deploy RBD CSI driver
helm install ceph-csi-rbd ceph-csi/ceph-csi-rbd \
  --namespace ceph-csi \
  --set csiConfig[0].clusterID=<ceph-fsid> \
  --set csiConfig[0].monitors[0]=192.168.86.21:6789 \
  --set csiConfig[0].monitors[1]=192.168.86.22:6789 \
  --set csiConfig[0].monitors[2]=192.168.86.23:6789

# Deploy CephFS CSI driver
helm install ceph-csi-cephfs ceph-csi/ceph-csi-cephfs \
  --namespace ceph-csi \
  --set csiConfig[0].clusterID=<ceph-fsid> \
  --set csiConfig[0].monitors[0]=192.168.86.21:6789 \
  --set csiConfig[0].monitors[1]=192.168.86.22:6789 \
  --set csiConfig[0].monitors[2]=192.168.86.23:6789
```

> **📝 Note:** Replace `<ceph-fsid>` with the output of `ceph fsid`. The monitor IPs are on the public/management network (`192.168.86.0/24`) because Kubernetes nodes connect as Ceph clients, not over the TB4 cluster network.

#### Step 3: Create Kubernetes Secrets

```yaml
# ceph-csi-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: csi-rbd-secret
  namespace: ceph-csi
stringData:
  userID: kubernetes
  userKey: <output-of-ceph-auth-get-key>
---
apiVersion: v1
kind: Secret
metadata:
  name: csi-cephfs-secret
  namespace: ceph-csi
stringData:
  adminID: kubernetes
  adminKey: <output-of-ceph-auth-get-key>
```

```bash
kubectl apply -f ceph-csi-secret.yaml
```

#### Step 4: Create StorageClasses

**`ceph-rbd` — Default StorageClass for general block storage (SQL databases, general PVCs):**

```yaml
# storageclass-ceph-rbd.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-rbd
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rbd.csi.ceph.com
parameters:
  clusterID: <ceph-fsid>
  pool: ceph-block
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: csi-rbd-secret
  csi.storage.k8s.io/provisioner-secret-namespace: ceph-csi
  csi.storage.k8s.io/controller-expand-secret-name: csi-rbd-secret
  csi.storage.k8s.io/controller-expand-secret-namespace: ceph-csi
  csi.storage.k8s.io/node-stage-secret-name: csi-rbd-secret
  csi.storage.k8s.io/node-stage-secret-namespace: ceph-csi
reclaimPolicy: Retain
allowVolumeExpansion: true
mountOptions:
  - discard
```

**`ceph-rbd-fast` — Low-latency block storage for cache workloads (Redis, session stores):**

```yaml
# storageclass-ceph-rbd-fast.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-rbd-fast
provisioner: rbd.csi.ceph.com
parameters:
  clusterID: <ceph-fsid>
  pool: ceph-block-fast
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: csi-rbd-secret
  csi.storage.k8s.io/provisioner-secret-namespace: ceph-csi
  csi.storage.k8s.io/controller-expand-secret-name: csi-rbd-secret
  csi.storage.k8s.io/controller-expand-secret-namespace: ceph-csi
  csi.storage.k8s.io/node-stage-secret-name: csi-rbd-secret
  csi.storage.k8s.io/node-stage-secret-namespace: ceph-csi
reclaimPolicy: Delete
allowVolumeExpansion: true
mountOptions:
  - discard
```

> **📝 Note:** `ceph-rbd-fast` uses `reclaimPolicy: Delete` since cache data is ephemeral. `ceph-rbd` uses `Retain` to protect database data from accidental PVC deletion.

**`cephfs` — Shared filesystem for ReadWriteMany workloads:**

```yaml
# storageclass-cephfs.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: cephfs
provisioner: cephfs.csi.ceph.com
parameters:
  clusterID: <ceph-fsid>
  fsName: cephfs
  pool: cephfs_data
  csi.storage.k8s.io/provisioner-secret-name: csi-cephfs-secret
  csi.storage.k8s.io/provisioner-secret-namespace: ceph-csi
  csi.storage.k8s.io/controller-expand-secret-name: csi-cephfs-secret
  csi.storage.k8s.io/controller-expand-secret-namespace: ceph-csi
  csi.storage.k8s.io/node-stage-secret-name: csi-cephfs-secret
  csi.storage.k8s.io/node-stage-secret-namespace: ceph-csi
reclaimPolicy: Retain
allowVolumeExpansion: true
```

```bash
kubectl apply -f storageclass-ceph-rbd.yaml
kubectl apply -f storageclass-ceph-rbd-fast.yaml
kubectl apply -f storageclass-cephfs.yaml
```

#### StorageClass Selection Guide

| StorageClass   | Ceph Pool         | Access Mode      | Use Case                                         |
|----------------|-------------------|------------------|--------------------------------------------------|
| `ceph-rbd`     | `ceph-block`      | ReadWriteOnce    | PostgreSQL, MySQL, general stateful apps (default)|
| `ceph-rbd-fast`| `ceph-block-fast` | ReadWriteOnce    | Redis, Memcached, session stores, caches          |
| `cephfs`       | `cephfs_data`     | ReadWriteMany    | Shared config, static assets, multi-pod access    |

### Ceph Object Gateway (RGW) for S3

The RADOS Gateway provides an S3-compatible API for object storage. RGW runs on the Ceph/Proxmox nodes (not inside Kubernetes) and is accessed by K8s workloads via the S3 HTTP endpoint.

#### Step 1: Deploy RGW on Ceph Nodes

Install and enable RGW on each Proxmox/Ceph node:

```bash
# On each node (pve01, pve02, pve03)
apt install -y radosgw

# Create RGW instance (run on each node)
# pve01:
radosgw -n client.rgw.pve01 --rgw-frontends="beast port=7480"
# pve02:
radosgw -n client.rgw.pve02 --rgw-frontends="beast port=7480"
# pve03:
radosgw -n client.rgw.pve03 --rgw-frontends="beast port=7480"
```

Add RGW configuration to `/etc/pve/ceph.conf`:

```ini
[client.rgw.pve01]
   host = pve01
   rgw_frontends = beast port=7480
   rgw_dns_name = s3.homelab.local

[client.rgw.pve02]
   host = pve02
   rgw_frontends = beast port=7480
   rgw_dns_name = s3.homelab.local

[client.rgw.pve03]
   host = pve03
   rgw_frontends = beast port=7480
   rgw_dns_name = s3.homelab.local
```

Create CephX auth keys for each RGW instance:

```bash
ceph auth get-or-create client.rgw.pve01 \
  mon 'allow rw' osd 'allow rwx' \
  -o /etc/ceph/ceph.client.rgw.pve01.keyring

ceph auth get-or-create client.rgw.pve02 \
  mon 'allow rw' osd 'allow rwx' \
  -o /etc/ceph/ceph.client.rgw.pve02.keyring

ceph auth get-or-create client.rgw.pve03 \
  mon 'allow rw' osd 'allow rwx' \
  -o /etc/ceph/ceph.client.rgw.pve03.keyring
```

Enable and start the RGW services:

```bash
# On each respective node
systemctl enable --now ceph-radosgw@rgw.pve01.service  # pve01
systemctl enable --now ceph-radosgw@rgw.pve02.service  # pve02
systemctl enable --now ceph-radosgw@rgw.pve03.service  # pve03
```

Verify RGW is running:

```bash
curl http://192.168.86.21:7480
```

You should get an XML response with `ListAllMyBucketsResult` (empty buckets list).

#### Step 2: Create RGW User and Access Keys

```bash
radosgw-admin user create \
  --uid=k8s-s3 \
  --display-name="Kubernetes S3 Access" \
  --access-key=<generate-a-key> \
  --secret-key=<generate-a-secret>
```

> **💡 Tip:** Generate keys with `openssl rand -hex 20` for the access key and `openssl rand -hex 40` for the secret key.

#### Step 3: Using S3 from Kubernetes Workloads

Store the RGW credentials as a Kubernetes secret:

```yaml
# rgw-s3-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: ceph-rgw-s3
  namespace: default
stringData:
  AWS_ACCESS_KEY_ID: <access-key>
  AWS_SECRET_ACCESS_KEY: <secret-key>
  AWS_ENDPOINT_URL: http://192.168.86.21:7480
```

Applications can connect using any S3-compatible client (AWS SDK, MinIO client, `s3cmd`, etc.):

```bash
# Example: Using MinIO client from a pod
mc alias set homelab http://192.168.86.21:7480 <access-key> <secret-key>
mc mb homelab/my-bucket
mc ls homelab/
```

> **📝 Note:** For production, put a load balancer or DNS round-robin in front of the 3 RGW instances (`192.168.86.21:7480`, `192.168.86.22:7480`, `192.168.86.23:7480`) so workloads don't depend on a single node.

### etcd Storage Considerations

> **💡 etcd Storage Recommendation:**
>
> With 3 control plane nodes, etcd already has built-in 3-way replication across nodes, independent of Ceph. Here are the storage options:
>
> | Option | Latency | Redundancy | Backup Ease | Recommendation |
> |--------|---------|------------|-------------|----------------|
> | **Local NVMe** (Talos default) | ⚡ Lowest (~0.1 ms) | ✅ etcd Raft replication | Manual snapshots | ✅ **Use this** |
> | **CephFS mount** | 🐢 Higher (~1-3 ms network RTT) | ✅ Ceph + etcd replication | Ceph snapshots | ❌ Unnecessary overhead |
> | **Ceph RBD volume** | 🐢 Higher (~1-3 ms network RTT) | ✅ Ceph + etcd replication | Ceph snapshots | ❌ Unnecessary overhead |
>
> **Recommendation:** Keep etcd on the local VM disk (Talos default). The 250 GiB control plane disk is more than sufficient for etcd data (typically < 8 GB). etcd is highly latency-sensitive — adding network storage introduces unnecessary risk. Use Ceph for etcd **backups** instead:
>
> ```bash
> # Example: Periodic etcd snapshot to CephFS or S3
> etcdctl snapshot save /backup/etcd-snapshot-$(date +%Y%m%d).db
> # Upload to Ceph S3
> mc cp /backup/etcd-snapshot-*.db homelab/etcd-backups/
> ```

---

## 10. Performance Tuning

### BlueStore Tuning (NVMe-Specific)

BlueStore is Ceph's default storage backend and is already optimized for SSDs, but these tweaks can further improve NVMe performance.

Edit `/etc/pve/ceph.conf` (changes propagate to all nodes via pmxcfs):

```ini
[osd]
   # OSD memory target — 8 GB per OSD (recommended for NVMe)
   # Per host: 1 CP VM (8 GiB) + 2 worker VMs (12 GiB) + Proxmox (~2 GiB) + OSD (8 GiB) = ~30 GiB
   # pve01 adds Omni VM (2 GiB) = ~32 GiB — fully utilized
   osd_memory_target = 8589934592

   # BlueStore cache is auto-tuned by osd_memory_target (Reef+)
   # No need to set bluestore_cache_size_ssd explicitly

   # Increase recovery/backfill limits (NVMe can handle more parallelism)
   osd_max_backfills = 4
   osd_recovery_max_active = 8

   # NVMe can handle more concurrent operations
   osd_op_num_threads_per_shard = 2
```

> **📝 Note:** `osd_memory_target = 8589934592` is 8 GB — the recommended minimum for NVMe OSDs. With 32 GB RAM per node, the memory budget per host is: 1 CP VM (8 GiB) + 2 worker VMs (12 GiB) + Proxmox (~2 GiB) + OSD (8 GiB) ≈ 30 GiB. pve01 adds the Omni VM (2 GiB) for a total of ~32 GiB. CPU is modestly overcommitted (24 threads vs 20 available) which is normal for virtualization. This configuration maximizes Ceph throughput on the Samsung 990 PRO drives.

After editing, restart OSDs to apply:

```bash
# On each node
systemctl restart ceph-osd.target
```

Or restart one at a time to avoid cluster degradation:

```bash
# On pve01
systemctl restart ceph-osd@0.service
# Wait for cluster to return to HEALTH_OK, then pve02
systemctl restart ceph-osd@1.service
# Wait, then pve03
systemctl restart ceph-osd@2.service
```

### TB4 Network Tuning

The TB4 mesh is already configured with MTU 65520 (jumbo frames). Verify Ceph is using it:

```bash
# Check that OSD cluster addresses are on the TB4 network
ceph osd dump | grep cluster_addr
```

### CRUSH Map Considerations

With 3 nodes and `size=3`, CRUSH distributes one replica to each host by default (the `host` failure domain). This means:

- **1 node failure**: Cluster continues operating normally (min_size=2).
- **2 node failures**: Cluster blocks I/O (less than min_size copies available).

This is the correct behavior for a 3-node cluster. Do not change the failure domain to `osd` — that would defeat the purpose of host-level redundancy.

### Monitoring

Enable the Prometheus module for metrics collection:

```bash
ceph mgr module enable prometheus
```

The Prometheus endpoint will be available at `http://<active-mgr-ip>:9283/metrics`.

### Scrub Scheduling

On NVMe, scrubs are fast but can still impact latency. Schedule deep scrubs during off-peak hours:

```ini
[osd]
   # Run deep scrubs between 2 AM and 6 AM
   osd_scrub_begin_hour = 2
   osd_scrub_end_hour = 6
```

---

## Troubleshooting

### Ceph Status Shows HEALTH_WARN

```bash
ceph health detail
```

**Common warnings and fixes:**

| Warning | Cause | Fix |
|---------|-------|-----|
| `mons are allowing insecure global_id reclaim` | Default after init | `ceph config set mon auth_allow_insecure_global_id_reclaim false` |
| `too few PGs per OSD` | Pool PG count too low | Enable PG autoscaler: `ceph osd pool set <pool> pg_autoscale_mode on` |
| `1 pool(s) have no replicas configured` | Pool misconfiguration | `ceph osd pool set <pool> size 3` |
| `clock skew detected` | NTP drift between nodes | Sync NTP: `chronyc makestep` on all nodes |
| `OSD near full` | Disk usage > 85% | Add capacity or delete data. Ceph blocks writes at 95%. |

### OSD Won't Start

```bash
# Check OSD status
systemctl status ceph-osd@<id>.service

# Check OSD logs
journalctl -u ceph-osd@<id>.service -n 50 --no-pager

# Verify the device is present
lsblk /dev/nvme0n1   # (or nvme1n1 on pve02)
```

### OSD Replication Not Using TB4

If `ceph osd find <id>` shows `cluster_addrs` on `192.168.86.x` instead of `10.100.0.x`:

1. Verify `cluster_network` is set correctly:
   ```bash
   ceph config get osd cluster_network
   ```
2. Verify TB4 interfaces are up and have IPs in `10.100.0.0/24`:
   ```bash
   ip addr show | grep 10.100.0
   ```
3. Ensure the `/etc/pve/ceph.conf` has `cluster_network = 10.100.0.0/24` in the `[global]` section.
4. Restart OSDs after fixing configuration.

### TB4 Link Down

```bash
# Check interface status
ip link show en05
ip link show en06

# Ping across each link
ping -c 3 -I en06 10.100.0.2    # pve01 → pve02
ping -c 3 -I en05 10.100.0.9    # pve01 → pve03

# Check for Thunderbolt device enumeration
cat /sys/bus/thunderbolt/devices/*/device_name
```

If a TB4 link drops, Ceph will re-route replication over remaining links. The ring topology provides redundancy — every node has two TB4 paths to every other node.

### Monitor Quorum Lost

If a monitor goes down and quorum is lost (2 of 3 monitors must be healthy):

```bash
# Check quorum status
ceph quorum_status | python3 -m json.tool

# If a monitor is stuck, restart it
systemctl restart ceph-mon@<hostname>.service
```

### Slow OSD Performance

```bash
# Check OSD latency
ceph osd perf

# Look for slow ops
ceph daemon osd.<id> dump_historic_slow_ops

# Check if BlueStore compaction is running
ceph daemon osd.<id> bluestore allocator score block
```

Expected NVMe commit latency: < 1 ms. If significantly higher, check for:
- Thermal throttling (`sensors` command)
- NVMe firmware issues (`smartctl -a /dev/nvmeXn1`)
- Insufficient `osd_memory_target`

### Nuclear Option: Removing and Recreating an OSD

If an OSD is irreparably broken:

```bash
# Mark OSD out (starts data migration)
ceph osd out <osd-id>

# Wait for rebalance to complete
ceph -w   # watch until HEALTH_OK

# Stop the OSD daemon
systemctl stop ceph-osd@<osd-id>.service

# Remove from CRUSH map, auth, and cluster
ceph osd purge <osd-id> --yes-i-really-mean-it

# Wipe the device
ceph-volume lvm zap /dev/nvmeXn1 --destroy

# Recreate
pveceph osd create /dev/nvmeXn1
```

---

## References

- [Proxmox VE Ceph Documentation](https://pve.proxmox.com/wiki/Deploy_Hyper-Converged_Ceph_Cluster)
- [Ceph Documentation — Architecture](https://docs.ceph.com/en/reef/architecture/)
- [Ceph Documentation — BlueStore Config](https://docs.ceph.com/en/reef/rados/configuration/bluestore-config-ref/)
- [Ceph Performance Tuning](https://docs.ceph.com/en/reef/rados/configuration/osd-config-ref/)
- [Ceph CSI Driver — GitHub](https://github.com/ceph/ceph-csi) — RBD and CephFS CSI provisioner for Kubernetes
- [Ceph CSI Helm Charts](https://ceph.github.io/csi-charts) — Helm deployment for Ceph CSI drivers
- [Ceph RADOS Gateway (RGW)](https://docs.ceph.com/en/reef/radosgw/) — S3-compatible object storage on Ceph
- [taslabs-net Thunderbolt 4 Networking Guide](https://github.com/taslabs-net/thunderbolt-networking) — TB4 mesh setup reference for Proxmox clusters
- [Proxmox VE No-Subscription Repository](https://pve.proxmox.com/wiki/Package_Repositories#sysadmin_no_subscription_repo)
