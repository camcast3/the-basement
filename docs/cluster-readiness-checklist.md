# Cluster Readiness Checklist

> **Purpose:** Track every step needed to bring the k8s-homelab cluster from bare hardware to a fully operational state.
> Mark items with `[x]` as you complete them.

---

## Phase 1: Proxmox & Ceph Storage

Complete the Ceph cluster setup on the 3 Proxmox nodes. Full instructions in [Ceph TB4 Setup Guide](ceph-tb4-setup-guide.md).

- [x] Install Ceph packages on all 3 nodes — [Section 1](ceph-tb4-setup-guide.md#1-install-ceph-packages)
- [x] Initialize Ceph on pve01 (`pveceph init`) — [Section 2](ceph-tb4-setup-guide.md#2-initialize-ceph-on-the-first-node)
- [x] Create monitors on all 3 nodes — [Section 3](ceph-tb4-setup-guide.md#3-create-monitors)
- [x] Create managers on all 3 nodes — [Section 4](ceph-tb4-setup-guide.md#4-create-managers)
- [x] Create OSDs (one per node on Samsung 990 PRO) — [Section 5](ceph-tb4-setup-guide.md#5-create-osds)
- [x] Create storage pools (`ceph-block`, `ceph-block-fast`, CephFS, RGW) — [Section 6](ceph-tb4-setup-guide.md#6-create-storage-pools)
- [x] Verify `ceph -s` shows `HEALTH_OK` — [Section 7](ceph-tb4-setup-guide.md#7-verify-ceph-health)
- [x] Migrate Ceph cluster_network to TB4 (`10.100.0.0/24`) — see below
- [x] Verify OSD replication is on TB4 network (`10.100.0.x`) — [Section 7](ceph-tb4-setup-guide.md#7-verify-ceph-health)
- [x] Add Ceph storage to Proxmox (RBD + CephFS) — [Section 8](ceph-tb4-setup-guide.md#8-add-ceph-storage-to-proxmox)
- [x] Apply performance tuning (NVMe, scrub scheduling) — [Section 10](ceph-tb4-setup-guide.md#10-performance-tuning)
- [x] Enable Prometheus metrics (`ceph mgr module enable prometheus`) — [Section 10](ceph-tb4-setup-guide.md#10-performance-tuning)

### TB4 Cluster Network Migration ✅ COMPLETED

> **Status:** Ceph replication traffic is now running over the 40 Gbps Thunderbolt 4 mesh.

**What was done:**

- [x] Added inter-/30 static routes on each node (persistent via `post-up` in `/etc/network/interfaces`):
  ```bash
  # pve01 en06: post-up ip route add 10.100.0.4/30 via 10.100.0.2 dev en06
  # pve02 en05: post-up ip route add 10.100.0.8/30 via 10.100.0.1 dev en05
  # pve03 en06: post-up ip route add 10.100.0.0/30 via 10.100.0.10 dev en06
  ```
- [x] Enabled IP forwarding on all nodes (persistent via `/etc/sysctl.d/99-ceph-forward.conf`)
- [x] Verified full TB4 mesh connectivity (all IPs reachable from all nodes)
- [x] Updated `/etc/pve/ceph.conf`: `cluster_network = 10.100.0.0/24`
- [x] Rolling OSD restarts (one at a time, HEALTH_OK between each)
- [x] Verified OSD back_addrs on TB4:
  - osd.0 → `10.100.0.1` (pve01)
  - osd.1 → `10.100.0.2` (pve02)
  - osd.2 → `10.100.0.6` (pve03)

---

## Phase 2: External Dependencies

These services run outside Kubernetes and must be ready before the cluster can bootstrap.

### Infisical (Secrets Management)

- [x] Infisical instance running (TrueNAS at `infisical.local.negativezone.cc`)
- [x] Create project `k8s-homelab`, environment `prod`
- [x] Add secret: `PIHOLE_PASSWORD`
- [x] Add secret: `CLOUDFLARE_API_TOKEN`
- [ ] Create Machine Identity with Kubernetes Auth method
- [ ] Verify identity can authenticate from the K8s cluster network

### Pi-hole (DNS)

- [ ] Pi-hole running at `192.168.25.19`
- [ ] Admin password matches the value stored in Infisical (`/external-dns/PIHOLE_PASSWORD`)
- [ ] DNS records resolvable from K8s node network (`192.168.86.0/24`)

### Authentik (SSO) — Docker via Portainer

Full setup instructions in [Omni + Authentik Setup Guide](omni-authentik-setup-guide.md).

- [ ] Authentik running on Docker host
- [ ] SAML/OAuth provider configured for **ArgoCD**
- [ ] SAML/OAuth provider configured for **Grafana**
- [ ] SAML/OAuth provider configured for **Omni** — [Omni + Authentik Guide](omni-authentik-setup-guide.md)
- [ ] Test SSO login for each application

---

## Phase 3: Omni & Kubernetes Cluster

Provision the Talos Linux K8s cluster via Omni. Full plan in [K8s Omni Proxmox Plan](k8s-omni-proxmox-plan.md).

- [ ] Omni running with Proxmox infrastructure provider — [Omni + Authentik Guide](omni-authentik-setup-guide.md)
- [ ] Machine classes defined — [K8s Omni Plan: Machine Classes](k8s-omni-proxmox-plan.md#2-machine-classes)
- [ ] Cluster template applied (3 control planes + 6 workers)
- [ ] All nodes show `Ready` in Omni dashboard
- [ ] `omnictl kubeconfig k8s-homelab > ~/.kube/config`
- [ ] `kubectl get nodes` shows all 9 nodes `Ready`

---

## Phase 4: Cluster Bootstrap (ArgoCD)

One-time bootstrap that hands control to GitOps. Architecture details in [K8s GitOps Architecture](k8s-gitops-architecture.md).

```bash
# Install ArgoCD
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace \
  -f kubernetes/platform/argocd/values.yaml

# Apply the root app — ArgoCD creates all other Applications
kubectl apply -f kubernetes/platform/argocd/root-app.yaml
```

- [ ] ArgoCD installed via Helm
- [ ] Root app applied (`kubernetes/platform/argocd/root-app.yaml`)
- [ ] ArgoCD UI accessible and SSO login works (Authentik)

### Verify ArgoCD-managed components sync

**Infrastructure** — [GitOps Architecture: Adding Components](k8s-gitops-architecture.md#adding-a-new-component)

- [ ] Cilium (CNI + Gateway API)
- [ ] MetalLB (L2 LoadBalancer, pool `192.168.86.20-49`)
- [ ] cert-manager + ClusterIssuer (Let's Encrypt via Cloudflare DNS)
- [ ] external-dns (Pi-hole provider)
- [ ] Infisical operator (syncs secrets from Infisical → K8s)
- [ ] Spegel (peer-to-peer image distribution)
- [ ] Descheduler

**Platform**

- [ ] ArgoCD (self-managed after bootstrap)
- [ ] Argo Rollouts

**Observability**

- [ ] kube-prometheus-stack (Prometheus + Grafana)
- [ ] Loki (log aggregation)
- [ ] Alloy (telemetry collector)
- [ ] Grafana SSO login works (Authentik)

---

## Phase 5: Ceph → Kubernetes Storage (Rook External)

Connect the Proxmox Ceph cluster to K8s via Rook. Full instructions in [Ceph TB4 Setup Guide: Section 9](ceph-tb4-setup-guide.md#9-kubernetes-storage-integration-rook-external-cluster).

- [ ] Export cluster config from Proxmox (`create-external-cluster-resources.py`)
- [ ] Deploy Rook operator via Helm
- [ ] Import external cluster (`import-external-cluster.sh`)
- [ ] Apply `CephCluster` CR (external mode)
- [ ] Verify `CephCluster` shows `Connected` / `HEALTH_OK`
- [ ] Create StorageClasses (`ceph-rbd`, `ceph-rbd-fast`, `cephfs`)
- [ ] Test PVC — create, verify `Bound`, delete
- [ ] Add Rook ArgoCD Application to `kubernetes/platform/argocd/apps/`

### RGW (S3 Object Storage)

- [ ] Install and start RGW on all 3 Proxmox nodes — [Ceph Guide: RGW](ceph-tb4-setup-guide.md#ceph-object-gateway-rgw-for-s3)
- [ ] Create RGW user and access keys
- [ ] Store S3 credentials in Infisical
- [ ] Verify S3 access from a K8s pod

---

## Phase 6: Ingress & Networking

- [ ] Create a `Gateway` resource (Cilium Gateway API) for HTTP/HTTPS traffic
- [ ] Verify Gateway gets a MetalLB `LoadBalancer` IP from the homelab pool
- [ ] Create `HTTPRoute` for ArgoCD UI
- [ ] Create `HTTPRoute` for Grafana
- [ ] Verify TLS certificates issued by cert-manager
- [ ] Verify external-dns creates DNS records in Pi-hole

---

## Phase 7: Validation

Final checks before declaring the cluster production-ready.

- [ ] `kubectl get pods -A` — all pods `Running` or `Completed`
- [ ] All ArgoCD Applications show `Synced` and `Healthy`
- [ ] PVC provisioning works (RBD and CephFS)
- [ ] DNS resolution works (external-dns → Pi-hole)
- [ ] TLS certificates auto-issue (cert-manager → Let's Encrypt)
- [ ] Grafana dashboards show cluster metrics (Prometheus)
- [ ] Loki shows pod logs in Grafana
- [ ] SSO works for ArgoCD and Grafana (Authentik)
- [ ] `ceph -s` still shows `HEALTH_OK` on Proxmox

---

## References

| Document | Description |
|----------|-------------|
| [Ceph TB4 Setup Guide](ceph-tb4-setup-guide.md) | Ceph cluster setup, pools, K8s integration via Rook |
| [K8s GitOps Architecture](k8s-gitops-architecture.md) | ArgoCD app-of-apps, Helm values, secrets flow |
| [K8s Omni Proxmox Plan](k8s-omni-proxmox-plan.md) | Cluster provisioning via Omni + Proxmox provider |
| [Omni + Authentik Setup Guide](omni-authentik-setup-guide.md) | Omni deployment with SAML SSO |
| [Tailscale Remote Access Plan](tailscale-remote-access-plan.md) | Remote access (future) |
