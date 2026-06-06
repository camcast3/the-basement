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

Loki (in-cluster)
  → ts-loki-ingress (LoadBalancer class: tailscale, monitoring ns)
  → Exposed on tailnet (loki-k8s.<tailnet>.ts.net:3100) for VM-side promtail
    log shipping from both the Azure (lobby) and Proxmox (C2E2) stacks.
    Service lives in monitoring (same ns as the loki pod) so kube-proxy
    auto-generates the endpoints via selector; targets the SingleBinary
    loki pod direct (not the loki-gateway nginx — see issue #50).
```

## Pods (5 total, ~0.3 CPU, ~360Mi RAM)

| Pod | Purpose |
|-----|---------|
| Operator | Watches CRs, manages proxy lifecycle |
| Egress proxy — lobby | Bridges to Azure VM |
| Egress proxy — c2e2 | Bridges to Proxmox VM |
| Ingress proxy — Alertmanager | Exposes Alertmanager onto tailnet |
| Ingress proxy — Loki | Exposes Loki HTTP API onto tailnet |

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

### 2. Add Secrets to Infisical

In Infisical project `k8s-homelab` → Environment: `prod` → Path: `/tailscale`:
- `TS_OAUTH_CLIENT_ID` — OAuth client ID from step 1
- `TS_OAUTH_CLIENT_SECRET` — OAuth client secret from step 1

The `InfisicalSecret` CR syncs these into the `tailscale-oauth` K8s Secret automatically.

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
| `ingress-loki.yaml` | Ingress proxy exposing Loki HTTP API (port 3100) on tailnet for VM promtail |
