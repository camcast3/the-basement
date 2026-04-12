# Infrastructure Documentation

This directory contains documentation for deploying and managing infrastructure components.

## Available Guides

### [Omni + Authentik Setup Guide](omni-authentik-setup-guide.md)

Deploy Omni on-prem as a Portainer stack on a dedicated Docker host (Proxmox VM) with Authentik SAML authentication.

**Topics covered**:
- Portainer stack deployment on a dedicated Docker host
- Hybrid TLS (Traefik for UI, Omni certs for machine ports)
- SAML integration between Authentik and Omni
- Proxmox infrastructure provider setup
- Troubleshooting

**Quick start**: See the [Ansible playbooks README](../ansible/playbooks/README.md) for the preparation playbook.

### [Ceph Cluster Setup — Thunderbolt 4 Mesh](ceph-tb4-setup-guide.md)

Deploy a 3-node hyper-converged Ceph cluster on Proxmox 9, using a Thunderbolt 4 ring topology (40 Gbps, MTU 65520) for OSD replication traffic.

**Topics covered**:
- Ceph installation and initialization with separate public/cluster networks
- Monitor, Manager, and OSD creation across 3 nodes
- RBD and CephFS pool configuration (size=3, min_size=2)
- NVMe + TB4 performance tuning (BlueStore, osd_memory_target)
- Adding Ceph storage to Proxmox for VM/container use
- Network diagram and troubleshooting

## Components

### Omni
Omni is a cluster management platform by Sidero Labs that provides a unified interface for managing Talos Linux clusters.

- **Purpose**: Kubernetes cluster lifecycle management
- **Authentication**: SAML via Authentik
- **Deployment**: Docker Compose via Portainer (on dedicated Proxmox VM)
- **Documentation**: https://docs.siderolabs.com/omni/

### Authentik
Authentik is an open-source identity provider focused on flexibility and versatility.

- **Purpose**: Identity provider (IdP) for SSO/SAML authentication
- **Features**: SAML, OAuth2, LDAP, SCIM
- **Deployment**: Docker Compose
- **Documentation**: https://goauthentik.io/docs/

## Directory Structure

```
the-basement/
├── ansible/
│   ├── playbooks/
│   │   ├── setup-new-host.yaml          # Initial host setup (Ubuntu)
│   │   ├── setup-omni-cluster.yaml      # Omni host preparation
│   │   └── templates/                   # Jinja2 templates
│   └── inventory/
│       ├── inventory-ini                # Your inventory
│       └── inventory.example            # Example inventory
├── docker/
│   └── omni/
│       ├── compose.yaml                 # Portainer stack compose file
│       └── .env.example                 # Environment variable reference
├── docs/
│   ├── README.md                        # This file
│   ├── omni-authentik-setup-guide.md    # Complete setup guide
│   └── ceph-tb4-setup-guide.md          # Ceph + Thunderbolt 4 runbook
└── kubernetes/
    └── clusters/                        # Kubernetes workload manifests
```

## Getting Started

### Prerequisites

1. **Dedicated Docker host** (Proxmox VM) with Docker and Portainer running
2. **Traefik host** with HTTPS configured (Cloudflare DNS challenge)
3. **Authentik** running and accessible
4. **DNS** records for `omni.local.example.com`
5. **TLS certificates** for Omni's machine-facing ports

### Deployment Steps

1. **Prepare the host** with Ansible:
   ```bash
   ansible-playbook -i ansible/inventory/inventory-ini ansible/playbooks/setup-omni-cluster.yaml
   ```

2. **Configure Authentik SAML** — see the [setup guide](omni-authentik-setup-guide.md#3-configure-authentik-saml)

3. **Configure Traefik** — see the [setup guide](omni-authentik-setup-guide.md#4-configure-traefik)

4. **Deploy via Portainer** using `docker/omni/compose.yaml`

See the [full setup guide](omni-authentik-setup-guide.md) for detailed instructions.

## Additional Resources

- [Sidero Labs Omni Documentation](https://docs.siderolabs.com/omni/)
- [Authentik Documentation](https://goauthentik.io/docs/)
- [SAML with Omni Guide](https://docs.siderolabs.com/omni/security-and-authentication/using-saml-with-omni/)
- [Docker Compose Documentation](https://docs.docker.com/compose/)
