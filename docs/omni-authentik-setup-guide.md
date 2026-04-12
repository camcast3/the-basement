# Omni + Authentik Setup Guide

Deploy Omni on-prem as a Portainer stack on a dedicated Docker host (Proxmox VM), with SAML authentication via Authentik and Traefik as the web UI reverse proxy.

> **Why a dedicated host?** TrueNAS Shell is sandboxed and restricts commands like
> `gpg --gen-key`, `certbot`, and local file writes needed for cert/key generation.
> A dedicated Proxmox VM (Ubuntu/Debian) provides full shell access for provisioning
> and avoids TrueNAS limitations.

## Architecture

```
                    ┌─── Traefik (existing host) ───┐
User browser ──────►  TLS termination               │
                    │  proxies to Omni host:8080     │
                    └────────────┬───────────────────┘
                                 │ HTTP
                    ┌────────────▼───────────────────┐
                    │  Omni Host (Proxmox VM)         │
                    │  Docker + Portainer              │
                    │                                  │
                    │  ┌──────────────────────────┐   │
                    │  │  Omni (bridge network)    │   │
                    │  │  :8080  → UI (Traefik)    │   │
                    │  │  :8090  → SideroLink (TLS)│──────► Talos nodes
                    │  │  :8091  → Event sink      │   │
                    │  │  :8100  → K8s proxy (TLS) │   │
                    │  │  :50180 → WireGuard (UDP) │   │
                    │  └──────────┬───────────────┘   │
                    │             │ grpc://omni:8080   │
                    │  ┌──────────▼───────────────┐   │
                    │  │  Proxmox Provider        │   │
                    │  └──────────────────────────┘   │
                    └──────────────────────────────────┘
```

**Hybrid TLS model:**
- Traefik terminates TLS for the Omni web UI (port 443 → 8080)
- Omni holds its own TLS cert/key for machine-facing ports (8090, 8100) — required by Talos nodes

## 1. Prerequisites

- **Dedicated Docker host** (Proxmox VM with Ubuntu/Debian) running Docker and Portainer
- **Traefik** on a separate host with HTTPS configured
- **Authentik** running at `authentik.local.example.com`
- **TLS certificates** for `omni.local.example.com` (fullchain.pem + privkey.pem)
- **DNS** record for `omni.local.example.com` pointing to Traefik

---

## 2. Prepare the Host (Ansible)

Run the Ansible playbook to create directories, generate the GPG encryption key, and generate the account UUID:

```bash
cd ~/repos/the-basement/ansible
ansible-playbook playbooks/setup-omni-cluster.yaml -i inventory/inventory-ini
```

### What the Playbook Does:
- ✅ Verifies Docker is installed on the Omni host
- ✅ Creates directory structure (`/opt/omni`)
- ✅ Generates GPG encryption key for etcd
- ✅ Generates unique account UUID
- ✅ Outputs Portainer stack deployment instructions

### Manual Alternative

If you prefer not to use Ansible:

```bash
# SSH to Omni host
mkdir -p /opt/omni/{certs,etcd}

# Generate GPG key
gpg --batch --passphrase '' --quick-generate-key \
  "Omni (Used for etcd data encryption) omni@omni.local.example.com" \
  rsa4096 cert never
FINGERPRINT=$(gpg --list-secret-keys --with-colons | grep fpr | head -n1 | cut -d: -f10)
gpg --batch --passphrase '' --quick-add-key $FINGERPRINT rsa4096 encr never
gpg --batch --export-secret-key --armor omni@omni.local.example.com > /opt/omni/omni.asc
chmod 600 /opt/omni/omni.asc

# Generate account UUID
uuidgen > /opt/omni/.account_uuid
```

### Copy TLS Certificates

```bash
# Copy your certificates for machine-facing ports
cp fullchain.pem /opt/omni/certs/fullchain.pem
cp privkey.pem /opt/omni/certs/privkey.pem
```

---

## 3. Configure Authentik SAML

Log in to **Authentik Admin UI** at `https://authentik.local.example.com`

### a. Create SAML Property Mapping
1. Navigate to: **Customization → Property Mappings**
2. Click: **Create**
3. Select: **SAML Provider Property Mapping**
4. Configure:
   - **Name**: `Omni Mapping`
   - **SAML Attribute Name**: `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name`
   - **Expression**: `return request.user.email`
5. Click: **Submit**

### b. Create Application and SAML Provider
1. Navigate to: **Applications → Applications**
2. Click: **Create with Provider**
3. Configure Application:
   - **Name**: `Omni`
   - **Slug**: `omni` (remember this!)
4. Select Provider Type: **SAML Provider**
5. Configure Provider:
   - **Name**: `Omni Provider`
   - **ACS URL**: `https://omni.local.example.com/saml/acs`
   - **Service Provider Binding**: `Post`
   - **Audience**: `https://omni.local.example.com/saml/metadata`
   - **Signing Certificate**: `authentik Self-signed Certificate`
   - **Sign assertions**: ✅ Enable
   - **Sign responses**: ✅ Enable
   - **Property mappings**: Select `Omni Mapping`
   - **NameID Property Mapping**: Select `Omni Mapping`
6. Click: **Submit**

---

## 4. Configure Traefik

On your **Traefik host**, add a route for the Omni web UI:

```yaml
# File: traefik/dynamic/omni.yaml
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

**Note:** Only the web UI goes through Traefik. Machine-facing ports (8090, 8100, 50180) connect directly to the Omni host IP.

---

## 5. Deploy via Portainer

1. Open Portainer on your Omni host
2. Go to **Stacks → Add stack**
3. Paste the contents of `docker/omni/compose.yaml` from this repo
4. Set environment variables (refer to `docker/omni/.env.example`):

| Variable | Example Value |
|----------|---------------|
| `OMNI_VERSION` | `v1.5.10` |
| `OMNI_DOMAIN` | `omni.local.example.com` |
| `OMNI_WIREGUARD_IP` | `10.10.1.100` |
| `OMNI_HTTP_PORT` | `8080` |
| `OMNI_DATA_DIR` | `/opt/omni` |
| `OMNI_ACCOUNT_UUID` | *(from playbook output or `/opt/omni/.account_uuid`)* |
| `OMNI_ADMIN_EMAIL` | `admin@example.com` |
| `SAML_METADATA_URL` | `https://authentik.local.example.com/application/saml/omni/metadata/` |
| `OMNI_SERVICE_ACCOUNT_KEY` | *(set after first start — see step 7)* |

5. Click **Deploy the stack**

---

## 6. Validate

1. Navigate to `https://omni.local.example.com`
2. You should see the login page with an **"Authentik SSO"** button
3. Log in with your Authentik credentials

```bash
# On Omni host — check containers are running
docker ps | grep omni

# Check Omni logs
docker logs omni -f
```

---

## 7. Enable Proxmox Provider (Optional)

The Proxmox provider needs a service account key that can only be created after Omni is running.

1. Log in to Omni → **Settings → Service Accounts**
2. Click **Create Service Account**
3. Name: `proxmox_sa`
4. Role: **InfraProvider** (NOT Operator or Admin)
5. Copy the generated key immediately
6. In Portainer, update the stack environment variable:
   - `OMNI_SERVICE_ACCOUNT_KEY` = *(paste the key)*
7. Redeploy the stack

---

## Quick Reference

| Component | Location | Ports |
|-----------|----------|-------|
| Omni UI | Traefik → Omni host:8080 | 443 (via Traefik) |
| SideroLink API | Omni host direct | 8090/tcp (TLS) |
| Event Sink | Omni host direct | 8091/tcp |
| K8s Proxy | Omni host direct | 8100/tcp (TLS) |
| WireGuard | Omni host direct | 50180/udp |
| Authentik | `https://authentik.local.example.com` | 443 |

**SAML Metadata URL:**
```
https://authentik.local.example.com/application/saml/omni/metadata/
```

**Access Omni:**
```
https://omni.local.example.com
```

---

## Troubleshooting

- **503 Error**: Traefik can't reach Omni host on port 8080 — check firewall/connectivity
- **Certificate Error**: Verify TLS certs at `/opt/omni/certs/` are valid for `omni.local.example.com`
- **SAML Error**: Ensure ACS URL and Audience in Authentik match exactly
- **Talos nodes can't connect**: Verify ports 8090, 8100, 50180 are reachable on Omni host IP
- **Proxmox provider fails**: Ensure service account key has **InfraProvider** role (not Admin)
- **Container won't start**: Check `docker logs omni` — verify GPG key and UUID exist
