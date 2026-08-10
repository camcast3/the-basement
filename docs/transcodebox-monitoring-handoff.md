# Handoff: pick up `transcodebox` (transcodeflow) monitoring in the-basement

> **For a the-basement session.** The transcodeflow stack on `transcodebox` has been
> deployed and its local monitoring **validated end-to-end** (see "Verified state").
> This doc gives you the context + the exact repo changes to make so the cluster's
> Prometheus/Grafana pick up transcodeflow metrics. It follows the existing
> `egress-mediabox` / `ceph` precedents in this repo.

## What `transcodebox` is

- **Host:** `pvebeast` Proxmox VM **9003** (`transcodebox`), Debian 13, **`192.168.3.67`**, VLAN 3.
- **GPU:** AMD Radeon Pro **W7600** passthrough → **AV1 VAAPI** hardware encode (validated).
- **App:** `transcodeflow` — one binary, three roles (api / scanner / worker×4) sharing
  Postgres + a Redis stream. Scans the TrueNAS media library and re-encodes to AV1 in place.
- **Repo (compose + monitoring source):** `camcast3/homelab` → `transcodebox/`.
- **Reachability:** on the DMZ VLAN. It has its **own self-contained** Prometheus/Grafana/Loki.
  Metrics are VM-local today; the goal is for the cluster to also scrape them.

## Verified state (live, VM 9003 — do not re-derive)

Host-published ports on `192.168.3.67`:

| Port | Service | Notes |
|------|---------|-------|
| `52080` | transcodeflow **API** | `/health` → `{"checks":{"postgres":"ok","redis":"ok"},"status":"healthy"}`, `/ready`, `/status`, `/jobs` |
| `9090` | API `/metrics` | app metrics (Prometheus format) |
| `9091` | **Prometheus** | self-contained; **8/8 targets UP** (see below) |
| `3000` | **Grafana** | anonymous Viewer; dashboard **"TranscodeFlow Overview"** (7 panels) provisioned |
| `3100` | **Loki** | labels: `container`, `service`, `service_name` |
| `52022` | SSH | shifted off 22 |

`transcodebox`'s own Prometheus (`:9091`) scrapes — **all UP**:

- `job=transcodeflow` (`service="transcodeflow"`): `api:9090`, `scanner:9090`, `worker-1..4:9090`
- `job=postgres` (`service="transcodeflow"`): `postgres-exporter:9187` — `pg_up=1`
- `job=redis` (`service="transcodeflow"`): `redis-exporter:9121` — `redis_up=1`

Metric names present (verified):

- **App:** `transcodeflow_queue_depth` (gauge), `transcodeflow_probe_duration_seconds_{bucket,count,sum}`,
  `transcodeflow_transcode_duration_seconds_{bucket,count,sum}`
- **Postgres:** `pg_up` + standard `pg_*` (postgres_exporter v0.16.0)
- **Redis:** `redis_up` + standard `redis_*` (redis_exporter v1.67.0)

> **Note:** every transcodebox target (app + pg + redis) carries the label
> `service="transcodeflow"`, so a single federation matcher `{service="transcodeflow"}`
> captures the whole stack.

## Recommended integration — **federate** transcodebox's Prometheus

transcodebox already aggregates app + datastore metrics locally. Rather than scrape each
role/exporter (the worker `:9090` ports aren't host-published anyway), **federate `:9091`**.
Two transport options — pick one:

### Option A (recommended): LAN-direct federation

Matches the existing **`ceph` job** (`192.168.86.2:9283`, direct LAN IP). Simplest — no
homelab change, no Tailscale node.

**Prereq (firewall):** allow the cluster's node/pod egress → **`192.168.3.67:9091`** in the
VLAN rules (transcodebox is on the DMZ VLAN).

Add to `kubernetes/observability/prometheus/prometheus.yaml` (the `prometheus-config`
ConfigMap → `scrape_configs`):

```yaml
      # transcodebox (transcodeflow AV1 stack on pvebeast VM 9003) — federated from
      # its self-contained Prometheus, which scrapes api/scanner/worker-1..4 + the
      # postgres/redis exporters. All transcodebox series carry service=transcodeflow.
      - job_name: transcodebox-federate
        honor_labels: true
        metrics_path: /federate
        params:
          'match[]':
            - '{service="transcodeflow"}'
        static_configs:
          - targets: ["192.168.3.67:9091"]
            labels:
              instance: transcodebox
```

### Option B (alternative): Tailscale egress (mediabox pattern)

Use if you'd rather not open a VLAN path. Mirrors `egress-mediabox.yaml`.

1. **Homelab prereq (separate change in `camcast3/homelab`):** add a Tailscale **sidecar**
   to `transcodebox/docker-compose.yaml` (like mediabox, `TS_HOSTNAME=transcodebox`) and put
   the `prometheus` container on its netns so `:9091` is reachable on the tailnet. Needs a
   Tailscale auth key. → tailnet node `transcodebox.tail042ec7.ts.net`.
2. **This repo:** add `kubernetes/infrastructure/tailscale-operator/egress-transcodebox.yaml`
   (copy `egress-mediabox.yaml`; annotation `tailscale.com/tailnet-fqdn: "transcodebox.tail042ec7.ts.net"`;
   expose port `9091`). ArgoCD app `tailscale-proxies` will sync it.
3. Prometheus job as in Option A but target `ts-transcodebox-proxy.tailscale.svc:9091`.

> ⚠️ Do **not** add a live `egress-*.yaml` until the tailnet node exists — ArgoCD auto-syncs
> that directory and a proxy to a missing node will error.

## Grafana dashboard

Reuse the validated dashboard: **`transcodebox/monitoring/grafana/dashboards/transcodeflow-overview.json`**
in `camcast3/homelab` (title "TranscodeFlow Overview", 7 panels: queue depth, jobs, transcode
duration, probe duration). Wire it the same way as `dashboards-homelab.yaml`:

1. Create `kubernetes/observability/grafana/dashboards-transcodeflow.yaml` — a ConfigMap
   `grafana-dashboards-transcodeflow` (namespace `monitoring`, label
   `app.kubernetes.io/name: grafana`) with the JSON inline under `data:`.
2. Give the dashboard a stable `uid` (the source JSON has none — set e.g. `"uid": "transcodeflow-overview"`).
3. **Datasource:** repoint panel datasources to the cluster Prometheus datasource
   (`{"type":"prometheus","uid":"prometheus"}`), as the other in-repo dashboards do.
4. Project the new ConfigMap into the `dashboards` volume in `grafana/grafana.yaml`
   (the projected-volume list alongside `grafana-dashboards-homelab`, `-apps`, etc.).

## Alerts (repo convention — every service gets ≥1 rule)

Add to `kubernetes/observability/prometheus/rules.yaml` (mirror existing rule style):

- `up{instance="transcodebox"} == 0` → transcodebox Prometheus unreachable.
- `pg_up{service="transcodeflow"} == 0` / `redis_up{service="transcodeflow"} == 0` → datastore down.
- Optional: `transcodeflow_queue_depth` high + no `transcode_duration` progress → stuck workers.

## Open decision for you

**Transport = Option A (LAN-direct, needs the VLAN allow to `192.168.3.67:9091`) vs
Option B (Tailscale sidecar, needs a homelab change + auth key).** The user's recent context
mentioned VLAN-firewall allowlisting and a locally-hosted cluster, which points at **A**; the
established cross-network pattern (mediabox) is **B**. Confirm with the user before wiring.

## Source-of-truth files (camcast3/homelab → transcodebox/)

- `docker-compose.yaml` — 14 services incl. `postgres-exporter`, `redis-exporter`.
- `monitoring/prometheus.yml` — jobs `transcodeflow` (api/scanner/worker-1..4), `postgres`, `redis`.
- `monitoring/grafana/dashboards/transcodeflow-overview.json` — the dashboard to import.
- `TRANSCODEBOX-SETUP.md` — full runbook.
