# Tailscale Remote Access Plan — The Basement Homelab

> **Status:** Planning  
> **Last Updated:** 2025-07  
> **Scope:** Secure remote access to Proxmox cluster, Kubernetes workloads, and internal services via Tailscale mesh VPN.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Tailscale on Proxmox Hosts](#2-tailscale-on-proxmox-hosts)
3. [Tailscale for Kubernetes](#3-tailscale-for-kubernetes)
4. [ACL Policies](#4-acl-policies)
5. [Exit Node Configuration](#5-exit-node-configuration)
6. [DNS and MagicDNS](#6-dns-and-magicdns)
7. [Integration with Authentik](#7-integration-with-authentik)
8. [Security Best Practices](#8-security-best-practices)

---

## 1. Architecture Overview

### How Tailscale Fits In

Tailscale creates a WireGuard-based mesh VPN (a "tailnet") that connects devices regardless of NAT or firewall boundaries. Each device gets a stable 100.x.y.z address on the tailnet and can reach other devices directly (peer-to-peer) or via Tailscale's DERP relay servers when direct connections aren't possible.

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Tailscale Tailnet                            │
│                    (WireGuard mesh overlay)                           │
│                                                                      │
│   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐               │
│   │  Admin       │   │  Laptop     │   │  Phone      │               │
│   │  Desktop     │   │  (remote)   │   │  (mobile)   │               │
│   │  100.x.x.1   │   │  100.x.x.2  │   │  100.x.x.3  │               │
│   └──────┬───────┘   └──────┬───────┘   └──────┬───────┘               │
│          │                  │                  │                      │
│          │    Direct WireGuard tunnels         │                      │
│          │         (peer-to-peer)              │                      │
└──────────┼──────────────────┼──────────────────┼──────────────────────┘
           │                  │                  │
           ▼                  ▼                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│                    LAN: 192.168.86.0/24                              │
│                                                                      │
│   ┌──────────────────────────────────────────────────────────┐       │
│   │              Proxmox Cluster                              │       │
│   │                                                          │       │
│   │   pve01 (.2)         pve02 (.3)         pve03 (.4)       │       │
│   │   ┌──────────┐      ┌──────────┐      ┌──────────┐      │       │
│   │   │ Tailscale │      │ Tailscale │      │ Tailscale │      │       │
│   │   │ Subnet   │      │ (backup   │      │ (node     │      │       │
│   │   │ Router   │      │  router)  │      │  only)    │      │       │
│   │   │ Exit Node│      │           │      │           │      │       │
│   │   └──────────┘      └──────────┘      └──────────┘      │       │
│   │        │                  │                  │            │       │
│   │   ┌────┴────┐       ┌────┴────┐       ┌────┴────┐       │       │
│   │   │  VMs    │       │  VMs    │       │  VMs    │       │       │
│   │   │ Talos   │       │ Talos   │       │ Talos   │       │       │
│   │   │ nodes   │       │ nodes   │       │ nodes   │       │       │
│   │   └─────────┘       └─────────┘       └─────────┘       │       │
│   └──────────────────────────────────────────────────────────┘       │
│                                                                      │
│   ┌─────────────────┐    ┌────────────────────────────────┐         │
│   │ Omni             │    │ Kubernetes Cluster (Talos)     │         │
│   │ omni.local.      │    │                                │         │
│   │ example.com  │    │  ┌────────────────────────┐   │         │
│   │ (192.168.86.x)   │    │  │ Tailscale K8s Operator │   │         │
│   └─────────────────┘    │  │ (in-cluster)           │   │         │
│                           │  └────────────────────────┘   │         │
│   ┌─────────────────┐    │                                │         │
│   │ Authentik        │    │  Services exposed via          │         │
│   │ authentik.local. │    │  Tailscale LoadBalancer        │         │
│   │ example.com  │    └────────────────────────────────┘         │
│   └─────────────────┘                                                │
└──────────────────────────────────────────────────────────────────────┘
```

### Devices That Get Tailscale Installed

| Device / System | Tailscale Role | Notes |
|---|---|---|
| **pve01** (192.168.86.2) | Subnet router (primary) + Exit node | Advertises 192.168.86.0/24 to tailnet |
| **pve02** (192.168.86.3) | Subnet router (failover) | High-availability backup for subnet routing |
| **pve03** (192.168.86.4) | Node only | Direct access to this host; no routing role |
| **Kubernetes cluster** | Tailscale K8s Operator | Exposes selected services onto the tailnet |
| **Admin devices** | Client | Laptops, desktops, phones used for remote access |

### WireGuard Mesh VPN — How It Works

- Every Tailscale node generates a WireGuard keypair on first run.
- The Tailscale coordination server distributes public keys and endpoint hints.
- Nodes establish **direct peer-to-peer WireGuard tunnels** when possible (NAT traversal via STUN/ICE).
- When direct connections fail, traffic flows through **DERP relay servers** (encrypted end-to-end; Tailscale relays cannot decrypt).
- All traffic is encrypted with WireGuard (Noise protocol, ChaCha20-Poly1305).
- No open inbound ports are required on the homelab — Tailscale punches through NAT.

---

## 2. Tailscale on Proxmox Hosts

### 2.1 Prerequisites

- A Tailscale account (free tier supports up to 100 devices, 3 users)
- SSH access to each Proxmox node
- `curl` installed (default on Proxmox/Debian)

### 2.2 Install Tailscale on Each PVE Node

Run on **each** Proxmox host (`pve01`, `pve02`, `pve03`):

```bash
# Add Tailscale package repository
curl -fsSL https://tailscale.com/install.sh | sh

# Verify installation
tailscale version
```

### 2.3 Enable IP Forwarding

Subnet routing requires IP forwarding to be enabled on the host. This is **critical** — without it, the Proxmox node cannot forward traffic between the tailnet and the LAN.

```bash
# Enable IP forwarding (persistent across reboots)
echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
sysctl -p /etc/sysctl.d/99-tailscale.conf

# Verify
sysctl net.ipv4.ip_forward
# Expected output: net.ipv4.ip_forward = 1
```

### 2.4 Configure Subnet Routing

Only **one** node should be the active subnet router at a time (with a second as failover). This avoids asymmetric routing.

**On pve01 (primary subnet router):**

```bash
tailscale up \
  --advertise-routes=192.168.86.0/24 \
  --accept-dns=true \
  --hostname=pve01
```

**On pve02 (failover subnet router):**

```bash
tailscale up \
  --advertise-routes=192.168.86.0/24 \
  --accept-dns=true \
  --hostname=pve02
```

**On pve03 (node only — no routing):**

```bash
tailscale up \
  --accept-dns=true \
  --hostname=pve03
```

### 2.5 Approve Subnet Routes in the Admin Console

After `tailscale up` advertises routes, they must be **approved** in the Tailscale admin console:

1. Go to [https://login.tailscale.com/admin/machines](https://login.tailscale.com/admin/machines)
2. Find `pve01` → click **Edit route settings** → enable `192.168.86.0/24`
3. Find `pve02` → click **Edit route settings** → enable `192.168.86.0/24`
4. Tailscale automatically handles failover: if `pve01` goes down, `pve02` takes over routing

> **Note:** As of Tailscale v1.40+, you can use `--advertise-routes` with the `failover` flag or configure HA subnet routers via ACL `autoApprovers`. See [Tailscale HA subnet routers docs](https://tailscale.com/kb/1115/high-availability/).

### 2.6 Verify Connectivity

From a remote device on the tailnet:

```bash
# Ping a LAN device through the subnet router
ping 192.168.86.2

# Access Proxmox Web UI
# https://192.168.86.2:8006

# Access Omni
# https://omni.local.example.com
```

### 2.7 Firewall Considerations

Proxmox's built-in firewall (`pve-firewall`) may block forwarded traffic. If subnet routing doesn't work after setup:

```bash
# Option A: Allow Tailscale interface in PVE firewall
# Add to /etc/pve/firewall/cluster.fw or node-level firewall:
# [RULES]
# IN ACCEPT -i tailscale0

# Option B: Ensure tailscale0 is in the trusted zone
# Check with:
ip link show tailscale0
```

---

## 3. Tailscale for Kubernetes

### 3.1 Tailscale Kubernetes Operator (Recommended)

The Tailscale Kubernetes Operator is the official way to integrate Tailscale with Kubernetes. It can:

- Expose Kubernetes `Services` directly on the tailnet
- Act as a Tailscale-native ingress controller
- Automatically manage Tailscale node identities for pods

#### Install via Helm

```bash
# Add the Tailscale Helm repository
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update

# Create namespace
kubectl create namespace tailscale

# Create a Tailscale auth key secret
# Generate an auth key at: https://login.tailscale.com/admin/settings/keys
# Use a reusable, ephemeral key tagged with "tag:k8s"
kubectl create secret generic tailscale-auth \
  --namespace tailscale \
  --from-literal=TS_AUTHKEY=tskey-auth-XXXXX

# Install the operator
helm install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale \
  --set oauth.clientId="YOUR_OAUTH_CLIENT_ID" \
  --set oauth.clientSecret="YOUR_OAUTH_CLIENT_SECRET" \
  --set operatorConfig.hostname="k8s-operator" \
  --wait
```

> **Note on Talos Linux:** Since Talos is immutable, you cannot install Tailscale directly on Talos nodes. The Kubernetes Operator approach is the correct pattern — it runs Tailscale in-cluster as pods.

#### Expose a Service via Tailscale

Add the `tailscale.com/expose` annotation to any Service to make it accessible on the tailnet:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  annotations:
    tailscale.com/expose: "true"
    tailscale.com/hostname: "my-app"  # Optional: custom tailnet hostname
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale  # Required for Tailscale LB
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080
```

The service will be reachable at `my-app.<tailnet-name>.ts.net` from any device on the tailnet.

#### Tailscale Ingress Controller

For HTTPS services, use the Tailscale Ingress class:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  annotations:
    tailscale.com/funnel: "false"  # Set to "true" to expose to the internet
spec:
  ingressClassName: tailscale
  rules:
    - host: my-app  # becomes my-app.<tailnet>.ts.net
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
  tls:
    - hosts:
        - my-app  # Tailscale provisions HTTPS certs automatically
```

### 3.2 Alternative: Tailscale Sidecar / Gateway Pod

If the operator is too heavy, you can run a Tailscale container as a sidecar or standalone gateway pod:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tailscale-gateway
  namespace: tailscale
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tailscale-gateway
  template:
    metadata:
      labels:
        app: tailscale-gateway
    spec:
      containers:
        - name: tailscale
          image: ghcr.io/tailscale/tailscale:latest
          env:
            - name: TS_AUTHKEY
              valueFrom:
                secretKeyRef:
                  name: tailscale-auth
                  key: TS_AUTHKEY
            - name: TS_KUBE_SECRET
              value: "tailscale-state"
            - name: TS_ROUTES
              value: "10.96.0.0/12,10.244.0.0/16"  # ClusterIP + Pod CIDR
            - name: TS_EXTRA_ARGS
              value: "--hostname=k8s-gateway"
          securityContext:
            capabilities:
              add: ["NET_ADMIN"]
```

> **Recommendation:** Use the Kubernetes Operator. It is actively maintained, handles auth key rotation, and integrates with Tailscale ACLs natively.

### 3.3 MagicDNS for Service Discovery

With the Tailscale K8s Operator, exposed services are automatically registered in MagicDNS:

- Service `my-app` → `my-app.<tailnet>.ts.net`
- No manual DNS configuration needed
- HTTPS certificates are auto-provisioned via Let's Encrypt (managed by Tailscale)

---

## 4. ACL Policies

Tailscale ACLs (Access Control Lists) define who can access what on the tailnet. ACLs are written in HuJSON and managed in the Tailscale admin console or via GitOps.

### 4.1 Proposed ACL Policy

```jsonc
{
  // Define tags for device categories
  "tagOwners": {
    "tag:admin":    ["autogroup:admin"],
    "tag:proxmox":  ["autogroup:admin"],
    "tag:k8s":      ["autogroup:admin"],
    "tag:user":     ["autogroup:admin"],
    "tag:server":   ["autogroup:admin"]
  },

  // Auto-approve subnet routes from tagged devices
  "autoApprovers": {
    "routes": {
      "192.168.86.0/24": ["tag:proxmox"],
      "10.96.0.0/12":    ["tag:k8s"],      // K8s ClusterIP range
      "10.244.0.0/16":   ["tag:k8s"]       // K8s Pod CIDR
    },
    "exitNode": {
      "tag:proxmox": ["autogroup:admin"]
    }
  },

  "acls": [
    // --- Admin Access ---
    // Admin devices get full access to everything
    {
      "action": "accept",
      "src":    ["tag:admin"],
      "dst":    ["*:*"]
    },

    // --- Proxmox Management ---
    // Proxmox nodes can talk to each other (cluster communication)
    {
      "action": "accept",
      "src":    ["tag:proxmox"],
      "dst":    ["tag:proxmox:*"]
    },

    // --- Kubernetes Services ---
    // Regular users can access specific K8s services only
    {
      "action": "accept",
      "src":    ["tag:user"],
      "dst":    [
        "tag:k8s:80",
        "tag:k8s:443",
        "tag:k8s:8080"
      ]
    },

    // --- Omni Management ---
    // Admin devices can reach Omni on its management ports
    {
      "action": "accept",
      "src":    ["tag:admin"],
      "dst":    ["192.168.86.0/24:443", "192.168.86.0/24:8080"]
    },

    // --- K8s Operator Internal ---
    // K8s tagged devices can reach other K8s and Proxmox nodes
    {
      "action": "accept",
      "src":    ["tag:k8s"],
      "dst":    [
        "tag:k8s:*",
        "tag:proxmox:*"
      ]
    },

    // --- Default Deny ---
    // Everything not explicitly allowed is denied (implicit in Tailscale)
  ],

  // SSH access rules (optional — for Tailscale SSH)
  "ssh": [
    {
      "action": "accept",
      "src":    ["tag:admin"],
      "dst":    ["tag:proxmox", "tag:server"],
      "users":  ["root", "autogroup:nonroot"]
    }
  ],

  // Node attribute overrides
  "nodeAttrs": [
    {
      "target": ["tag:proxmox"],
      "attr":   ["funnel:off"]   // Proxmox nodes should never be on Funnel
    }
  ]
}
```

### 4.2 Applying Tags to Devices

When bringing up Tailscale on each device, use auth keys pre-tagged in the admin console:

```bash
# Generate tagged auth keys at:
# https://login.tailscale.com/admin/settings/keys
# Select tags: tag:proxmox (for PVE nodes), tag:k8s (for K8s operator)

# Example: bring up pve01 with a pre-tagged key
tailscale up \
  --authkey=tskey-auth-XXXXX \
  --advertise-routes=192.168.86.0/24 \
  --hostname=pve01
```

### 4.3 ACL Policy Breakdown

| Source | Destination | Ports | Purpose |
|---|---|---|---|
| `tag:admin` | `*` | `*` | Full admin access to all resources |
| `tag:proxmox` | `tag:proxmox` | `*` | Proxmox cluster intercommunication |
| `tag:user` | `tag:k8s` | `80, 443, 8080` | User access to web services only |
| `tag:admin` | `192.168.86.0/24` | `443, 8080` | Omni management console access |
| `tag:k8s` | `tag:k8s`, `tag:proxmox` | `*` | K8s internal and storage access |

---

## 5. Exit Node Configuration

An exit node routes **all** internet traffic from a client through the homelab. This is useful when on untrusted networks (coffee shop, hotel WiFi) — your traffic exits from your home IP.

### 5.1 Configure pve01 as an Exit Node

```bash
# On pve01: advertise as both a subnet router and exit node
tailscale up \
  --advertise-routes=192.168.86.0/24 \
  --advertise-exit-node \
  --hostname=pve01
```

### 5.2 Approve Exit Node in Admin Console

1. Go to [https://login.tailscale.com/admin/machines](https://login.tailscale.com/admin/machines)
2. Find `pve01` → **Edit route settings** → enable **Use as exit node**

### 5.3 Use the Exit Node from a Client

```bash
# On your laptop/phone, route all traffic through pve01
tailscale set --exit-node=pve01

# Verify — your public IP should now be your home IP
curl https://ifconfig.me

# Disable exit node when done
tailscale set --exit-node=
```

### 5.4 Use Cases

| Scenario | Exit Node? | Subnet Router? |
|---|---|---|
| Accessing Proxmox UI remotely | No (subnet router is enough) | ✅ Yes |
| Accessing K8s services remotely | No (Tailscale K8s Operator handles this) | Optional |
| On untrusted WiFi, want encrypted internet | ✅ Yes | Also active |
| Want home IP for geo-restricted content | ✅ Yes | Also active |

---

## 6. DNS and MagicDNS

### 6.1 How MagicDNS Works

MagicDNS is Tailscale's built-in DNS system that automatically assigns DNS names to devices on the tailnet:

- Each device gets `<hostname>.<tailnet-name>.ts.net`
- Example: `pve01.tail12345.ts.net` resolves to `100.x.y.z`

### 6.2 Split DNS for local.example.com

The homelab uses `*.local.example.com` for internal services. To access these by name when remote, configure **split DNS** in Tailscale:

1. Go to [Tailscale Admin → DNS](https://login.tailscale.com/admin/dns)
2. Under **Nameservers → Add nameserver → Custom**:
   - Nameserver: `192.168.86.1` (your LAN DNS server/router)
   - Restrict to domain: `local.example.com`
3. This tells Tailscale: "For any `*.local.example.com` query, ask the homelab DNS server"

**Result:** When connected to the tailnet remotely, `authentik.local.example.com` resolves correctly via the subnet router.

```
Remote laptop → Tailscale → Subnet Router (pve01)
    → LAN DNS (192.168.86.1)
    → resolves authentik.local.example.com → 192.168.86.x
    → traffic flows back through subnet router
```

### 6.3 DNS Configuration Summary

| Domain | Resolver | How It Works |
|---|---|---|
| `*.ts.net` | Tailscale MagicDNS | Automatic; resolves tailnet hostnames |
| `*.local.example.com` | Split DNS → LAN DNS (192.168.86.1) | Configured in Tailscale admin |
| Everything else | System default or exit node DNS | Normal internet resolution |

### 6.4 Accessing Services by Name When Remote

Once split DNS is configured:

| Service | URL (works remotely via Tailscale) |
|---|---|
| Proxmox (pve01) | `https://192.168.86.2:8006` or via MagicDNS: `https://pve01.<tailnet>.ts.net:8006` |
| Omni | `https://omni.local.example.com` |
| Authentik | `https://authentik.local.example.com` |
| K8s services | `https://<service>.<tailnet>.ts.net` (via K8s Operator) |

---

## 7. Integration with Authentik

### 7.1 Tailscale + Authentik SSO via OIDC

Tailscale supports using a third-party OIDC identity provider for user authentication. Authentik can serve as this provider, giving you SSO across Tailscale and all homelab services.

> **Important:** This feature requires a Tailscale plan that supports custom OIDC (check current plan availability). On the free plan, you authenticate with Google, Microsoft, or GitHub accounts.

#### Step 1: Create an OIDC Provider in Authentik

In Authentik (`authentik.local.example.com`):

1. Navigate to **Applications → Providers → Create**
2. Select **OAuth2/OpenID Connect Provider**
3. Configure:
   - **Name:** `Tailscale`
   - **Authorization flow:** Use your default authorization flow
   - **Client type:** Confidential
   - **Client ID:** (auto-generated — copy this)
   - **Client Secret:** (auto-generated — copy this)
   - **Redirect URIs:** `https://login.tailscale.com/a/<tailnet-org>/oidc/callback`
   - **Scopes:** `openid`, `profile`, `email`
   - **Signing Key:** Select your Authentik signing key

4. Create an **Application** linked to this provider:
   - **Name:** `Tailscale VPN`
   - **Slug:** `tailscale`
   - **Provider:** Select the Tailscale provider created above

#### Step 2: Configure Tailscale to Use Authentik OIDC

In the Tailscale admin console:

1. Go to **Settings → Authentication**
2. Under **Identity provider**, select **Custom OIDC**
3. Enter:
   - **Issuer URL:** `https://authentik.local.example.com/application/o/tailscale/`
   - **Client ID:** (from Authentik provider)
   - **Client Secret:** (from Authentik provider)

#### Step 3: Test Authentication

1. Log out of Tailscale on a client device
2. Re-authenticate — you should be redirected to Authentik's login page
3. After successful login, the device joins the tailnet

### 7.2 Considerations

- **Chicken-and-egg problem:** Authentik runs on the homelab, but you need Tailscale to reach the homelab remotely. If Authentik is down, you can't re-authenticate with Tailscale. **Mitigation:** Keep at least one device with a long-lived key that doesn't require re-auth, or use Tailscale's default identity provider as a fallback.
- **Key expiry:** When using OIDC, Tailscale may require periodic re-authentication. Ensure Authentik is highly available.
- **Alternative approach:** Instead of OIDC integration, use Tailscale's built-in identity providers (Google/GitHub) for tailnet auth, and use Authentik separately for application-level SSO. This avoids the circular dependency.

---

## 8. Security Best Practices

### 8.1 Key Expiry Policies

- **Enable key expiry** for all user devices (default: 180 days)
- **Disable key expiry** only for infrastructure nodes that must maintain persistent connections:
  ```bash
  # In Tailscale admin → Machines → pve01 → Disable key expiry
  # Do this for: pve01, pve02, pve03, k8s-operator
  ```
- **Use ephemeral keys** for the Kubernetes operator so nodes auto-deregister when pods terminate
- **Use reusable auth keys** with tags for automated provisioning (e.g., Ansible deploying Tailscale)

### 8.2 Device Authorization

- **Enable device approval** in Tailscale admin:
  - Settings → Device Management → Require approval for new devices
  - This prevents unauthorized devices from joining the tailnet even with valid credentials
- **Review connected devices** regularly at [admin/machines](https://login.tailscale.com/admin/machines)
- **Remove stale devices** that haven't connected in 90+ days

### 8.3 ACL Testing

Tailscale provides an ACL test framework. Define tests alongside your ACLs:

```jsonc
{
  // ... (ACL policy from Section 4) ...

  "tests": [
    // Admin can access Proxmox
    {
      "src":    "tag:admin",
      "dst":    "tag:proxmox:8006",
      "accept": true
    },
    // Admin can SSH to Proxmox
    {
      "src":    "tag:admin",
      "dst":    "tag:proxmox:22",
      "accept": true
    },
    // Regular user CANNOT access Proxmox management
    {
      "src":    "tag:user",
      "dst":    "tag:proxmox:8006",
      "accept": false
    },
    // Regular user CAN access K8s web services
    {
      "src":    "tag:user",
      "dst":    "tag:k8s:443",
      "accept": true
    },
    // Regular user CANNOT SSH to anything
    {
      "src":    "tag:user",
      "dst":    "tag:proxmox:22",
      "accept": false
    },
    // K8s nodes can reach Proxmox (for storage, etc.)
    {
      "src":    "tag:k8s",
      "dst":    "tag:proxmox:3260",
      "accept": true
    }
  ]
}
```

Run tests in the Tailscale admin console under **Access Controls → Tests** before saving any ACL changes.

### 8.4 Audit Logging

- **Tailscale logs** are available at [admin/logs](https://login.tailscale.com/admin/logs)
- Key events to monitor:
  - New device registrations
  - ACL policy changes
  - Auth key creation/usage
  - Subnet route approvals
  - Exit node usage
- **Consider exporting logs** to your monitoring stack if available
- **Tailscale configuration-as-code:** Store your ACL policy in this repo under `docs/tailscale-acl-policy.jsonc` and use the Tailscale API or GitOps integration to sync changes

### 8.5 Additional Hardening

| Practice | Recommendation |
|---|---|
| **Tailscale SSH** | Use Tailscale SSH instead of exposing port 22 — provides identity-aware access and session recording |
| **MFA** | Enforce MFA on your identity provider (Authentik or Google/GitHub) |
| **Least privilege** | Start with deny-all ACLs, add rules only as needed |
| **Network segmentation** | Use tags to group devices; avoid `*:*` rules except for `tag:admin` |
| **Auth key hygiene** | Rotate auth keys regularly; delete unused keys; set short expiry on one-time keys |
| **Funnel** | Keep Funnel disabled (`funnel:off`) on infrastructure nodes; only enable for intentionally public services |
| **Tailscale updates** | Keep Tailscale updated on all nodes — security patches are frequent |

---

## Appendix: Quick Reference Commands

```bash
# --- Installation ---
curl -fsSL https://tailscale.com/install.sh | sh

# --- Bring up with subnet routing ---
tailscale up --advertise-routes=192.168.86.0/24 --hostname=pve01

# --- Bring up as exit node + subnet router ---
tailscale up --advertise-routes=192.168.86.0/24 --advertise-exit-node --hostname=pve01

# --- Check status ---
tailscale status

# --- See IP addresses ---
tailscale ip

# --- Use exit node ---
tailscale set --exit-node=pve01

# --- Disable exit node ---
tailscale set --exit-node=

# --- Debug connectivity ---
tailscale ping pve01
tailscale netcheck

# --- View current routes ---
tailscale status --json | jq '.Peer[] | select(.ExitNode or .PrimaryRoutes)'
```

---

## Next Steps

1. [ ] Create Tailscale account and tailnet
2. [ ] Install Tailscale on pve01, pve02, pve03
3. [ ] Configure subnet routing on pve01 (primary) and pve02 (failover)
4. [ ] Configure pve01 as exit node
5. [ ] Set up split DNS for `local.example.com`
6. [ ] Write and test ACL policy
7. [ ] Deploy Tailscale Kubernetes Operator via Helm
8. [ ] Expose initial K8s services on tailnet
9. [ ] Evaluate Authentik OIDC integration vs. separate auth
10. [ ] Disable key expiry on infrastructure nodes
11. [ ] Store ACL policy in repo as `docs/tailscale-acl-policy.jsonc`
