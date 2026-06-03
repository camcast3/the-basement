# Tailscale Kubernetes Operator

Bridges the monitoring stack into the Tailscale network for scraping Minecraft
game server metrics without exposing any ports publicly.

## Architecture

```
Prometheus (in-cluster)
  → ts-lobby-proxy.tailscale.svc (ClusterIP)  → Azure VM (100.x.x.x)
  → ts-c2e2-proxy.tailscale.svc (ClusterIP)   → Proxmox VM (100.x.x.x)

Alertmanager (in-cluster)
  → ts-alertmanager-ingress (LoadBalancer class: tailscale)
  → Exposed on tailnet for VM graceful-shutdown silence webhooks
```

## Pods (4 total, ~0.25 CPU, ~320Mi RAM)

| Pod | Purpose |
|-----|---------|
| Operator | Watches CRs, manages proxy lifecycle |
| Egress proxy — lobby | Bridges to Azure VM |
| Egress proxy — c2e2 | Bridges to Proxmox VM |
| Ingress proxy — Alertmanager | Exposes Alertmanager onto tailnet |

## Deployment

ArgoCD handles deployment automatically via two Applications
(defined in `kubernetes/platform/argocd/apps/`):

- **`tailscale-operator`** — installs the Helm chart using `values.yaml`
- **`tailscale-proxies`** — applies the egress/ingress manifests

Once merged to `main`, ArgoCD will sync both automatically.

## One-Time Setup (manual)

### 1. Create OAuth Client

In [Tailscale Admin Console](https://login.tailscale.com/admin/settings/oauth):
- Name: `k8s-operator`
- Scopes: `devices:write`, `auth_keys:write`

### 2. Create Secret

```bash
kubectl create namespace tailscale
kubectl create secret generic tailscale-oauth \
  --from-literal=client-id=<CLIENT_ID> \
  --from-literal=client-secret=<CLIENT_SECRET> \
  -n tailscale
```

### 3. Verify

```bash
kubectl get pods -n tailscale
# All pods should be Running

# Test scraping through the proxy
kubectl run curl-test --rm -it --image=curlimages/curl -- \
  curl -s ts-lobby-proxy.tailscale.svc:9100/metrics | head
```

## Tailnet FQDNs

Update `tailscale.com/tailnet-fqdn` annotations in egress manifests to match
the actual machine names in your tailnet. Find them with:

```bash
tailscale status
# or check Tailscale Admin Console → Machines
```

## Files

| File | Description |
|------|-------------|
| `values.yaml` | Helm values for the operator chart |
| `egress-lobby.yaml` | Egress proxy service for Azure VM (Lobby) |
| `egress-c2e2.yaml` | Egress proxy service for Proxmox VM (C2E2) |
| `ingress-alertmanager.yaml` | Ingress proxy exposing Alertmanager on tailnet |
