# Kubernetes GitOps Architecture

## How Infrastructure as Code Works with Upstream Helm Charts

We use **upstream Helm charts** — we don't fork or store them in this repo.
What we store is the **customization layer**:

```
kubernetes/
├── infrastructure/          # Cluster infrastructure (CNI, DNS, certs, storage)
│   ├── cilium/
│   │   └── values.yaml
│   ├── cert-manager/
│   │   ├── values.yaml              # Helm overrides
│   │   └── manifests/               # Raw K8s manifests (deployed by ArgoCD separately)
│   │       ├── cluster-issuer.yaml
│   │       └── infisical-secret.yaml
│   ├── external-dns/
│   │   ├── values.yaml
│   │   └── manifests/
│   │       └── infisical-secret.yaml
│   └── infisical-operator/
│       └── values.yaml
├── platform/                # Developer platform (GitOps, rollouts)
│   ├── argocd/
│   │   ├── root-app.yaml            # Bootstrap — apply this ONE file manually
│   │   └── apps/                    # App-of-apps: one YAML per component
│   │       ├── cert-manager.yaml
│   │       ├── cert-manager-config.yaml  # Deploys manifests/ directory
│   │       ├── cilium.yaml
│   │       └── ...
│   └── argo-rollouts/
│       └── values.yaml
├── observability/           # Monitoring stack
│   ├── kube-prometheus-stack/
│   │   └── values.yaml
│   ├── loki/
│   │   └── values.yaml
│   └── alloy/
│       └── values.yaml
└── apps/                    # Application workloads
```

### What's in each component directory?

| File/Dir | Purpose |
|----------|---------|
| `values.yaml` | Helm chart overrides (version pinned in comment header) |
| `manifests/` | Raw K8s manifests (ClusterIssuers, InfisicalSecrets, etc.) |

### ArgoCD App-of-Apps Pattern

```
root-app.yaml (manually applied ONCE)
  └── watches: kubernetes/platform/argocd/apps/
       ├── cert-manager.yaml         → Helm: jetstack/cert-manager + our values.yaml
       ├── cert-manager-config.yaml  → Directory: cert-manager/manifests/
       ├── cilium.yaml               → Helm: cilium/cilium + our values.yaml
       ├── infisical-operator.yaml   → Helm: infisical/secrets-operator + our values.yaml
       └── ...
```

Each ArgoCD Application uses **multi-source** to combine upstream chart + our values:

```yaml
sources:
  - repoURL: https://charts.jetstack.io    # Upstream chart repo
    chart: cert-manager
    targetRevision: v1.20.2                 # Pinned chart version
    helm:
      valueFiles:
        - $values/kubernetes/infrastructure/cert-manager/values.yaml
  - repoURL: https://github.com/camcast3/the-basement.git
    targetRevision: main
    ref: values                             # "$values" alias for our repo
```

### Bootstrap (one-time setup)

```bash
# 1. Uninstall any existing Helm releases so ArgoCD can take over
helm uninstall cert-manager -n cert-manager
helm uninstall spegel -n spegel
helm uninstall descheduler -n kube-system

# 2. Apply the root app — ArgoCD creates all other Applications automatically
kubectl apply -f kubernetes/platform/argocd/root-app.yaml
```

After bootstrap, everything is GitOps:
- Push to `main` → ArgoCD detects → auto-syncs
- Add a new app YAML to `argocd/apps/` → ArgoCD creates the Application
- Delete an app YAML → ArgoCD prunes it

### How secrets work (zero secrets in git)

```
Infisical (TrueNAS at infisical.local.negativezone.cc)
    ↓ Kubernetes Auth (no static creds)
Infisical Operator (in-cluster)
    ↓ creates/syncs via InfisicalSecret CRDs
K8s Secrets (pihole-password, cloudflare-api-token, etc.)
    ↓ referenced by
Helm chart values (secretKeyRef)
```

1. Store secrets in Infisical under project `k8s-homelab`, environment `prod`
2. Create `InfisicalSecret` CRDs in `manifests/` directories (no actual secret values in git)
3. The operator syncs them into K8s Secrets automatically
4. Helm charts consume secrets via `secretKeyRef` as usual

### Infisical secret naming convention

| Infisical Path | Secret Key | K8s Secret Created | K8s Key |
|----------------|-----------|-------------------|---------|
| `/external-dns` | `PIHOLE_PASSWORD` | `pihole-password` (ns: external-dns) | `password` |
| `/cert-manager` | `CLOUDFLARE_API_TOKEN` | `cloudflare-api-token` (ns: cert-manager) | `api-token` |

### Adding a new component

1. Create `kubernetes/<layer>/<component>/values.yaml` with Helm overrides
2. If secrets needed: create `manifests/infisical-secret.yaml` with InfisicalSecret CRD
3. Create ArgoCD Application in `kubernetes/platform/argocd/apps/<component>.yaml`
4. If raw manifests exist: create `<component>-config.yaml` ArgoCD app pointing to `manifests/`
5. Push to `main` — ArgoCD handles the rest

### External dependencies (set up outside K8s first)

| Dependency | Where | What to configure |
|------------|-------|-------------------|
| Infisical | TrueNAS | Machine Identity with K8s Auth, project `k8s-homelab` |
| Pi-hole | 192.168.25.19 | Admin password stored in Infisical at `/external-dns/PIHOLE_PASSWORD` |
| Cloudflare | API | API token stored in Infisical at `/cert-manager/CLOUDFLARE_API_TOKEN` |
| Authentik | TrueNAS (Docker) | SSO provider for ArgoCD, Grafana |
