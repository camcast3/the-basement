# Ansible Playbooks for Omni Cluster Management

This directory contains Ansible playbooks for preparing and deploying Omni on-prem with Authentik SAML authentication.

## Infrastructure Overview

**Current Homelab Setup:**
- **Omni**: Deployed as a Portainer stack on a dedicated Proxmox VM
  - Running at: `omni.local.example.com`
  - Compose file: `docker/omni/compose.yaml`
  - Managed via Portainer UI
  - **Why a dedicated host?** TrueNAS Shell restricts commands like GPG key
    generation and local cert storage, so Omni requires its own VM.
- **Authentik**: Deployed via docker-compose in homelab
  - Running at: `authentik.local.example.com`
  - Managed independently, not via Ansible
- **Traefik**: Reverse proxy running on separate host
  - Handles TLS termination for Omni web UI
  - Routes traffic to Omni host on port 8080

## Available Playbooks

### 1. setup-new-host.yaml
Sets up a new Ubuntu host with Docker and required dependencies.

```bash
ansible-playbook -i inventory/inventory-ini playbooks/setup-new-host.yaml
```

### 2. setup-proxmox-host.yaml
Configures freshly-installed Proxmox 8.x hosts based on [Techno Tim's guide](https://technotim.com/posts/first-11-things-proxmox/): no-subscription repos, updates, IOMMU/PCI passthrough, VFIO modules, VLAN-aware bridge, SMART monitoring, and optional email alerts.

```bash
ansible-playbook -i inventory/inventory-ini playbooks/setup-proxmox-host.yaml
```

**Key Variables** (set in inventory or extra vars):
- `cpu_vendor`: `intel` or `amd` (default: `intel`)
- `enable_iommu`: Enable PCI passthrough (default: `true`)
- `enable_vlan_aware`: Enable VLAN on vmbr0 (default: `true`)
- `enable_email_alerts`: Configure Gmail SMTP alerts (default: `false`)
- `smtp_relay_email`: Gmail address for sending alerts
- `smtp_relay_password`: Gmail app password

### 3. bootstrap-argocd.yaml
Bootstraps ArgoCD on the Kubernetes cluster and applies the root app-of-apps. This is the GitOps entry point — ArgoCD manages everything else, but needs an initial install.

```bash
ansible-playbook playbooks/bootstrap-argocd.yaml
ansible-playbook playbooks/bootstrap-argocd.yaml -e argocd_version=v3.3.6
ansible-playbook playbooks/bootstrap-argocd.yaml -e kubeconfig=~/.kube/my-cluster
```

**Key Variables**:
- `argocd_version`: ArgoCD version to install (default: `v3.3.6`)
- `kubeconfig`: Path to kubeconfig (default: `$KUBECONFIG` or `~/.kube/config`)

**What it does**:
- Installs ArgoCD from official manifests (pinned version)
- Sets `server.insecure=true` (TLS terminated at Cilium Gateway)
- Applies root Application (app-of-apps from `kubernetes/platform/argocd/apps/`)
- Displays initial admin password

### 4. setup-omni-cluster.yaml
Prepares the dedicated Omni host for deployment — creates directories, generates the GPG encryption key and account UUID. Does **not** deploy the stack (Portainer handles that).

```bash
ansible-playbook -i inventory/inventory-ini playbooks/setup-omni-cluster.yaml
```

**Key Variables**:
- `omni_domain_name`: Domain for Omni (default: `omni.local.example.com`)
- `omni_admin_email`: Admin email address (default: `admin@example.com`)
- `omni_install_dir`: Data directory on host (default: `/opt/omni`)
- `enable_proxmox_provider`: Create Proxmox config file (default: `true`)
- `proxmox_url`: Proxmox API URL (required if provider enabled)
- `proxmox_username`: Proxmox username (default: `root@pam`)
- `proxmox_password`: Proxmox password (required if provider enabled)

## Architecture

```
User → Traefik (TLS termination) → Omni host:8080 (Omni UI)
                                     │
                                     ├── :8090  SideroLink API (own TLS)
                                     ├── :8091  Event sink
                                     ├── :8100  K8s proxy (own TLS)
                                     └── :50180 WireGuard (UDP)
                                     │
                                     ├── Proxmox Provider (sidecar)
                                     └── Authentik (SAML auth)
```

**Components**:
- **Traefik**: Reverse proxy with Cloudflare DNS challenge for the UI TLS certificate (separate host)
- **Omni**: Kubernetes cluster management with embedded etcd, deployed as a Portainer stack
- **Proxmox Provider**: Optional sidecar for managing Proxmox VE infrastructure
- **Authentik**: SAML identity provider for user authentication

## Quick Start

### 1. Prepare the host:
```bash
ansible-playbook -i inventory/inventory-ini playbooks/setup-omni-cluster.yaml
```

### 2. Copy TLS certificates for machine-facing ports:
```bash
scp fullchain.pem privkey.pem omni-host:/opt/omni/certs/
```

### 3. Configure Authentik SAML:
See [docs/omni-authentik-setup-guide.md](../../docs/omni-authentik-setup-guide.md#3-configure-authentik-saml)

### 4. Configure Traefik:
```yaml
# traefik/dynamic/omni.yaml
http:
  routers:
    omni:
      rule: "Host(`omni.local.example.com`)"
      entryPoints:
        - websecure
      service: omni
      tls:
        certResolver: cloudflare
  services:
    omni:
      loadBalancer:
        servers:
          - url: "http://<omni-host-ip>:8080"
```

### 5. Deploy via Portainer:
Use `docker/omni/compose.yaml` and set environment variables from `docker/omni/.env.example`.

### 6. Access Omni:
Navigate to `https://omni.local.example.com` and log in with Authentik SSO.

### 7. Enable Proxmox Provider (optional):
After first login, create an InfraProvider service account in Omni, then update `OMNI_SERVICE_ACCOUNT_KEY` in the Portainer stack.

## Templates

- `templates/proxmox-config.yaml.j2`: Proxmox provider configuration

## Notes

- Omni is deployed via Portainer, not Ansible — the playbook only prepares prerequisites
- Omni needs its own TLS cert/key for machine-facing ports even though Traefik handles the UI
- The compose file is at `docker/omni/compose.yaml` — this is the source of truth
- SAML metadata URL format: `https://authentik.local.example.com/application/saml/<slug>/metadata/`

## Troubleshooting

**Omni container won't start:**
- Check logs: `docker logs omni`
- Verify GPG key exists: `ls -l /opt/omni/omni.asc`
- Verify certs exist: `ls -l /opt/omni/certs/`

**SAML authentication fails:**
- Verify ACS URL and Audience in Authentik match exactly
- Check SAML metadata URL in Portainer stack environment variables

**Talos nodes can't connect:**
- Verify ports 8090, 8100, 50180 are reachable on Omni host IP
- Check that TLS certs are valid for the advertised domain

For detailed troubleshooting, see: [docs/omni-authentik-setup-guide.md](../../docs/omni-authentik-setup-guide.md#troubleshooting)

## Support

- [Omni Documentation](https://docs.siderolabs.com/omni/)
- [Authentik Documentation](https://goauthentik.io/docs/)
- [Authentik + Omni Integration Guide](https://integrations.goauthentik.io/infrastructure/omni/)
