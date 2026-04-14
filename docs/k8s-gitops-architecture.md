# Kubernetes GitOps Architecture

## How Infrastructure as Code Works with Upstream Helm Charts

We use **upstream Helm charts** — we don't fork or store them in this repo.
What we store is the **customization layer**:

```
kubernetes/
├── infrastructure/          # Cluster infrastructure (CNI, DNS, certs, storage)
│   ├── cilium/
│   │   └── values.yaml              # Our Helm overrides for Cilium
│   ├── cert-manager/
│   │   ├── values.yaml              # Helm overrides
│   │   ├── cluster-issuer.yaml      # Additional K8s manifests
│   │   └── infisical-secret.yaml    # Declarative secret reference
│   ├── external-dns/
│   │   ├── values.yaml
│   │   └── infisical-secret.yaml
│   └── infisical-operator/
│       └── values.yaml
├── platform/                # Developer platform (GitOps, rollouts)
│   ├── argocd/
│   └── argo-rollouts/
├── observability/           # Monitoring stack
│   ├── kube-prometheus-stack/
│   ├── loki/
│   └── alloy/
└── apps/                    # Application workloads
```

### What's in each component directory?

| File | Purpose |
|------|---------|
| `values.yaml` | Helm chart overrides (version pinned in comment header) |
| `infisical-secret.yaml` | InfisicalSecret CRD — tells Infisical Operator to sync a secret into K8s |
| `*.yaml` (other) | Additional K8s manifests not covered by the Helm chart (ClusterIssuers, etc.) |

### How secrets work (zero secrets in git)

```
Infisical (TrueNAS)
    ↓ Kubernetes Auth (no static creds)
Infisical Operator (in-cluster)
    ↓ creates/syncs
K8s Secrets (pihole-password, cloudflare-api-token, etc.)
    ↓ referenced by
Helm chart values (secretKeyRef)
```

1. Store secrets in Infisical under project `k8s-homelab`, environment `prod`
2. Create `InfisicalSecret` CRDs in git (declarative, no actual secret values)
3. The operator syncs them into K8s Secrets automatically
4. Helm charts consume secrets via `secretKeyRef` as usual

### How deployments work (ArgoCD GitOps)

Once ArgoCD is managing the cluster:

1. ArgoCD `Application` CRDs point to upstream chart repo + version + our values file
2. Push to `main` → ArgoCD detects drift → reconciles cluster state
3. Secrets are handled separately by the Infisical Operator (not ArgoCD)

### Manual deployment (before ArgoCD manages a component)

```bash
# Example: deploy cert-manager
helm upgrade --install cert-manager jetstack/cert-manager \
  --version v1.20.2 \
  --namespace cert-manager --create-namespace \
  -f kubernetes/infrastructure/cert-manager/values.yaml

# Apply additional manifests
kubectl apply -f kubernetes/infrastructure/cert-manager/cluster-issuer.yaml
kubectl apply -f kubernetes/infrastructure/cert-manager/infisical-secret.yaml
```

### Infisical secret naming convention

| Infisical Path | Secret Key | K8s Secret Created | K8s Key |
|----------------|-----------|-------------------|---------|
| `/external-dns` | `PIHOLE_PASSWORD` | `pihole-password` (ns: external-dns) | `password` |
| `/cert-manager` | `CLOUDFLARE_API_TOKEN` | `cloudflare-api-token` (ns: cert-manager) | `api-token` |

Add new secrets by:
1. Creating the secret in Infisical at the appropriate path
2. Creating an `InfisicalSecret` CRD manifest in the component's directory
3. Using Go templates to map UPPER_CASE Infisical keys → expected K8s Secret keys
