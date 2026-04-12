# GitHub Copilot Instructions for The Basement Homelab

## Project Context
This is a hybrid homelab infrastructure project using:
- **Docker + Portainer** for stateful services and authentication
- **Kubernetes on Talos Linux** (managed by Omni) for cloud-native workloads

## Technology Stack

### Core Infrastructure
- **Docker**: Container runtime for stateful services
- **Portainer**: Docker management UI and orchestration
- **Talos Linux**: Immutable Kubernetes OS (managed via Omni only)
- **Omni**: Kubernetes cluster lifecycle management (omni.siderolabs.com)
- **Kubernetes**: Container orchestration for cloud-native apps (deployed by Talos)

### Key Services
- **Authentik**: SSO and authentication (Docker Compose via Portainer)
- **PostgreSQL**: Database (Docker for Authentik and other stateful services)
- **Redis**: Caching (Docker for Authentik)

### Supporting Tools
- **Ansible**: Infrastructure automation and configuration management
- **Docker Compose**: Service definitions for Docker workloads
- **Helm**: Package manager for Kubernetes applications
- **kubectl**: Kubernetes CLI
- **omnictl**: Omni management CLI

### NOT Used in This Project
- ❌ Manual Talos installation (Omni handles this)
- ❌ Authentik on Kubernetes (Docker only)
- ❌ Other auth solutions (Keycloak, Authelia, etc.)

## Architecture Rules

### Deployment Patterns
1. **Authentik & Stateful Services**: ONLY deployed via Docker Compose through Portainer
2. **Cloud-native/Stateless Apps**: Deployed on Kubernetes via Helm charts or kubectl manifests
3. **Talos nodes**: ONLY provisioned through Omni dashboard/API
4. **Ansible**: For infrastructure automation, node prep, backups, Docker host management

### When to Use Docker vs Kubernetes
**Use Docker + Portainer for:**
- ✅ Authentik (authentication service)
- ✅ Databases (PostgreSQL, MySQL)
- ✅ Stateful services requiring persistent data
- ✅ Services needing direct host network access
- ✅ Single-instance applications

**Use Kubernetes for:**
- ✅ Scalable web applications
- ✅ Microservices architectures
- ✅ Stateless workloads
- ✅ Cloud-native applications
- ✅ Services requiring auto-scaling and self-healing

### File Structure Conventions
```
/
├── docker/                    # Docker Compose configurations
│   ├── portainer/
│   ├── authentik/            # Authentik Docker Compose only
│   │   ├── docker-compose.yml
│   │   └── .env.example
│   └── databases/
├── ansible/                   # Ansible playbooks
│   ├── inventory/
│   ├── playbooks/
│   │   ├── docker-setup.yml  # Docker host provisioning
│   │   └── backup.yml
│   └── roles/
├── kubernetes/                # K8s manifests and Helm values
│   ├── apps/
│   └── infrastructure/
├── talos/                     # Talos configs (Omni-generated)
└── docs/                      # Documentation
```

## Code Generation Guidelines

### When suggesting Authentik setup:
```yaml
# ALWAYS use Docker Compose via Portainer
# docker/authentik/docker-compose.yml
version: '3.8'

services:
  postgresql:
    image: postgres:16-alpine
    restart: unless-stopped
    volumes:
      - database:/var/lib/postgresql/data
    environment:
      POSTGRES_PASSWORD: ${PG_PASS:?database password required}
      POSTGRES_USER: ${PG_USER:-authentik}
      POSTGRES_DB: ${PG_DB:-authentik}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d $${POSTGRES_DB} -U $${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:alpine
    restart: unless-stopped
    command: --save 60 1 --loglevel warning
    volumes:
      - redis:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping | grep PONG"]
      interval: 10s
      timeout: 3s
      retries: 5

  server:
    image: ghcr.io/goauthentik/server:latest
    restart: unless-stopped
    command: server
    environment:
      AUTHENTIK_REDIS__HOST: redis
      AUTHENTIK_POSTGRESQL__HOST: postgresql
      AUTHENTIK_POSTGRESQL__USER: ${PG_USER:-authentik}
      AUTHENTIK_POSTGRESQL__NAME: ${PG_DB:-authentik}
      AUTHENTIK_POSTGRESQL__PASSWORD: ${PG_PASS}
      AUTHENTIK_SECRET_KEY: ${AUTHENTIK_SECRET_KEY}
    volumes:
      - ./media:/media
      - ./custom-templates:/templates
    ports:
      - "9000:9000"
      - "9443:9443"
    depends_on:
      - postgresql
      - redis

  worker:
    image: ghcr.io/goauthentik/server:latest
    restart: unless-stopped
    command: worker
    environment:
      AUTHENTIK_REDIS__HOST: redis
      AUTHENTIK_POSTGRESQL__HOST: postgresql
      AUTHENTIK_POSTGRESQL__USER: ${PG_USER:-authentik}
      AUTHENTIK_POSTGRESQL__NAME: ${PG_DB:-authentik}
      AUTHENTIK_POSTGRESQL__PASSWORD: ${PG_PASS}
      AUTHENTIK_SECRET_KEY: ${AUTHENTIK_SECRET_KEY}
    volumes:
      - ./media:/media
      - ./certs:/certs
      - ./custom-templates:/templates
    depends_on:
      - postgresql
      - redis

volumes:
  database:
  redis:
```

```bash
# .env file
PG_PASS=CHANGE_ME_SECURE_PASSWORD
PG_USER=authentik
PG_DB=authentik
AUTHENTIK_SECRET_KEY=CHANGE_ME_TO_RANDOM_STRING_50_CHARS
```

### When suggesting Portainer setup:
```yaml
# docker/portainer/docker-compose.yml
version: '3.8'

services:
  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    ports:
      - "9443:9443"
      - "8000:8000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data

volumes:
  portainer_data:
```

### When suggesting Talos configuration:
```bash
# ALWAYS reference Omni management
omnictl cluster create <cluster-name>
# NOT: talosctl gen config (manual method)
```

### When suggesting Ansible for Docker:
```yaml
# ansible/playbooks/docker-setup.yml
---
- name: Setup Docker host
  hosts: docker_hosts
  become: yes
  tasks:
    - name: Install Docker
      apt:
        name:
          - docker.io
          - docker-compose
        state: present
        update_cache: yes

    - name: Start Docker service
      systemd:
        name: docker
        state: started
        enabled: yes

    - name: Deploy Portainer stack
      docker_compose:
        project_src: /opt/portainer
        state: present
```

### When suggesting K8s deployments:
```yaml
# For cloud-native apps only
# Prefer Helm for complex apps
# Use kubectl manifests for simple resources
# Always specify namespace
# Include resource limits
```

## Common Commands Reference

### Docker & Portainer
```bash
# Deploy via Portainer UI or CLI
docker compose -f docker/authentik/docker-compose.yml up -d
docker compose ps
docker compose logs -f authentik-server
docker compose down

# Access Portainer
# https://<host>:9443
```

### Omni
```bash
omnictl cluster list
omnictl kubeconfig <cluster-name> > ~/.kube/config
omnictl machine logs <machine-id>
```

### Talos (via omnictl)
```bash
omnictl talos dashboard
omnictl talos health
```

### Kubernetes
```bash
kubectl get pods -A
kubectl apply -f <manifest>
helm install <release> <chart> -n <namespace>
```

### Ansible
```bash
ansible-playbook -i inventory/hosts.yml playbooks/docker-setup.yml
ansible-playbook -i inventory/hosts.yml playbooks/backup.yml
```

## Security Guidelines
- Docker secrets in `.env` files (never committed, use `.env.example`)
- Kubernetes secrets in Sealed Secrets or External Secrets Operator
- Authentik credentials in `.env` on Docker host (backed up securely)
- No hardcoded passwords in any manifests or compose files
- Use RBAC for all Kubernetes service accounts
- Docker socket access restricted to Portainer only

## Networking
- **Docker services**: Use host network or bridge with explicit port mappings
- **Authentik**: Exposed on ports 9000 (HTTP) and 9443 (HTTPS)
- **Portainer**: Exposed on port 9443 (HTTPS)
- **K8s services**: Use LoadBalancer or Ingress for external access

## Backup Strategy
```yaml
# Ansible backup playbook for Docker volumes
- name: Backup Docker volumes
  hosts: docker_hosts
  tasks:
    - name: Backup Authentik data
      docker_container:
        name: backup-authentik
        image: alpine
        volumes:
          - authentik_database:/source:ro
          - /backup:/target
        command: tar czf /target/authentik-$(date +%Y%m%d).tar.gz -C /source .
```

## Response Format
When providing setup instructions:
1. State the tool/service being configured
2. Identify if it's a Docker or Kubernetes workload
3. Provide ONLY the canonical deployment method (Docker Compose for Authentik, Helm/kubectl for K8s apps)
4. Include verification commands
5. For Docker: mention volumes, networks, and port mappings
6. For K8s: mention namespace and resource requirements

## Critical Rules for Copilot
- ❌ Never suggest deploying Authentik on Kubernetes
- ❌ Never suggest manual Talos installation without Omni
- ❌ Never suggest stateful services on Kubernetes (use Docker)
- ❌ Never suggest using Ansible for K8s resource management
- ✅ Always use Docker Compose via Portainer for Authentik
- ✅ Always use Omni for Talos/K8s cluster management
- ✅ Always specify whether deployment is Docker or K8s
- ✅ Always use `.env` files for Docker secrets
- ✅ Always include healthchecks in Docker Compose services
- ✅ Use Kubernetes only for cloud-native, stateless workloads 
