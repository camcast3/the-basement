# Add External Grafana Dashboard

Link an upstream Grafana dashboard to this cluster so it is fetched at pod
startup, appears in a dedicated Grafana folder, and is automatically tracked
for version updates by Renovate.

## When to use

Use this skill whenever the user asks to:
- Add / link / import an external or upstream Grafana dashboard
- Track a third-party dashboard with version pinning
- Add a new entry to the external dashboard registry

## Inputs to collect

Ask the user for any values not already provided:

1. **GitHub repo** — `owner/repo` (e.g. `thecfu/scraparr`)
2. **Version tag** — the Git tag to pin (e.g. `v3.0.3`)
3. **Dashboard path** — path to the JSON file inside the repo (e.g. `dashboards/dashboard1.json`)
4. **Short name** — a kebab-case key used as the filename in Grafana (e.g. `scraparr`). Derive from the repo name if not provided.

## Steps

### 1. Inspect the upstream dashboard for datasource references

Download the dashboard JSON and check:
- `__inputs` section — lists datasource variables (e.g. `DS_MIMIR`, `DS_PROMETHEUS`)
- `templating.list` — look for `type: datasource` variables
- Panel `datasource.uid` values — find hardcoded UIDs

If the dashboard uses a Grafana template variable (e.g. `${datasource}`) for
its datasource picker, no override is needed — Grafana handles this natively.

If it hardcodes UIDs or uses `__inputs` variable names like `${DS_MIMIR}`,
you must add datasource overrides (step 3).

### 2. Add entry to the external dashboard registry ConfigMap

File: `kubernetes/observability/grafana/grafana.yaml`

Find the `grafana-external-dashboards` ConfigMap and add a new entry under
`data:`. The key is the short name; the value is the raw GitHub download URL
with the pinned tag.

```yaml
data:
  # owner/repo vX.Y.Z
  <short-name>: "https://raw.githubusercontent.com/<owner>/<repo>/<tag>/<dashboard-path>"
```

**Conventions:**
- Add a comment above the entry: `# owner/repo vX.Y.Z`
- Use the raw.githubusercontent.com URL format with the exact tag
- Key must be lowercase kebab-case (this becomes the `.json` filename)

### 3. Add datasource overrides (if needed)

File: `kubernetes/observability/grafana/grafana.yaml`

Find the `grafana-external-dashboard-overrides` ConfigMap. If the upstream
dashboard hardcodes datasource UIDs, add an entry whose key matches the
dashboard short name and whose value is `find=replace` pairs (one per line).

```yaml
data:
  <short-name>: |
    ${DS_MIMIR}=prometheus
    some-hardcoded-uid=prometheus
```

The init container applies these as string replacements on the downloaded JSON
before Grafana reads it. Skip this step if the dashboard already uses a
template variable for datasource selection.

**Local datasource UIDs available:**
| UID                    | Name                   | Type       |
|------------------------|------------------------|------------|
| `prometheus`           | Prometheus - K8s       | prometheus |
| `prometheus-watchtower`| Prometheus - Watchtower| prometheus |
| `loki`                 | Loki - K8s             | loki       |
| `alertmanager`         | Alertmanager - K8s     | alertmanager |

### 4. Add jq patches for customizations (if needed)

File: `kubernetes/observability/grafana/grafana.yaml`

Find the `grafana-external-dashboard-patches` ConfigMap. If you want to
customize the upstream dashboard (change titles, add tags, tweak thresholds,
add/remove panels), add an entry whose key matches the dashboard short name
and whose value is a `jq` filter expression.

```yaml
data:
  <short-name>: |
    .title = "My Custom Title" |
    .tags += ["homelab"] |
    .panels |= map(if .title == "Some Panel" then .fieldConfig.defaults.thresholds.steps[1].value = 90 else . end)
```

Patches are applied AFTER datasource overrides. The full `jq` language is
available — you can do anything from simple property changes to adding panels
or removing entire rows.

**Common jq recipes:**
| Goal | jq expression |
|------|---------------|
| Change title | `.title = "New Title"` |
| Add tags | `.tags += ["homelab", "custom"]` |
| Set default datasource variable | `.templating.list[] \|= if .name == "datasource" then .current.value = "prometheus" else . end` |
| Remove a row by title | `.panels \|= map(select(.title != "Unwanted Row"))` |
| Change a threshold | `.panels[] \|= if .title == "CPU" then .fieldConfig.defaults.thresholds.steps[1].value = 90 else . end` |
| Add a panel | `.panels += [{"type":"stat","title":"Custom","gridPos":{"h":4,"w":6,"x":0,"y":100}}]` |

### 5. Add a Renovate custom regex manager

File: `renovate.json`

Add a new object to the `customManagers` array so Renovate tracks new releases
of the source repo and opens PRs to bump the pinned tag.

```json
{
  "customType": "regex",
  "description": "Track <short-name> dashboard version pinned in Grafana init container",
  "fileMatch": ["kubernetes/observability/grafana/grafana\\.yaml$"],
  "matchStrings": [
    "<owner>/<repo>/(?<currentValue>v[\\d\\.]+)/<escaped-dashboard-path>"
  ],
  "depNameTemplate": "<owner>/<repo>",
  "datasourceTemplate": "github-releases"
}
```

**Conventions:**
- Escape dots and slashes in the dashboard path for the regex
- `depNameTemplate` must match the GitHub `owner/repo`
- `datasourceTemplate` is always `github-releases`

### 6. Commit

Commit all changed files together with a message following this pattern:

```
feat: add <short-name> external dashboard (pinned <tag>)
```

Include the standard Co-authored-by trailer.

## Architecture context

The Grafana deployment uses an **init container** (`fetch-external-dashboards`)
running `alpine:3.21` with `jq` that processes each dashboard through a
three-stage pipeline:

1. **Download** — fetches the JSON from the URL in `grafana-external-dashboards`
2. **Datasource overrides** — applies `find=replace` string substitutions from
   `grafana-external-dashboard-overrides` (for remapping UIDs)
3. **jq patch** — applies a `jq` filter from `grafana-external-dashboard-patches`
   (for structural customizations)

A separate dashboard provider mounts the output volume under the **"Scraparr"**
folder in Grafana (this folder name may be updated to something generic like
"External" if more dashboards are added).

No changes to the Deployment spec or init container script are needed — just
add entries to the three ConfigMaps and Renovate config.

## Three ConfigMaps

| ConfigMap | Purpose | Required? |
|-----------|---------|-----------|
| `grafana-external-dashboards` | Registry of dashboard URLs | Yes |
| `grafana-external-dashboard-overrides` | Datasource UID remapping | Optional |
| `grafana-external-dashboard-patches` | jq customizations | Optional |

## Validation checklist

Before committing, verify:
- [ ] The raw GitHub URL returns valid JSON (test with `curl` or `web_fetch`)
- [ ] The ConfigMap key is unique and kebab-case
- [ ] Datasource UIDs in the dashboard match local UIDs (or overrides are set)
- [ ] The Renovate regex matches the URL in the ConfigMap
- [ ] The `renovate.json` file is valid JSON
- [ ] The tag exists as a GitHub release on the source repo

## Example

Adding the Scraparr dashboard (no overrides needed — uses template variable):

**Registry entry:**
```yaml
  # thecfu/scraparr v3.0.3
  scraparr: "https://raw.githubusercontent.com/thecfu/scraparr/v3.0.3/dashboards/dashboard1.json"
```

**Renovate manager:**
```json
{
  "customType": "regex",
  "description": "Track Scraparr dashboard version pinned in Grafana init container",
  "fileMatch": ["kubernetes/observability/grafana/grafana\\.yaml$"],
  "matchStrings": [
    "thecfu/scraparr/(?<currentValue>v[\\d\\.]+)/dashboards/"
  ],
  "depNameTemplate": "thecfu/scraparr",
  "datasourceTemplate": "github-releases"
}
```

Example with overrides (hypothetical Mimir-based dashboard):

**Registry entry:**
```yaml
  # someorg/cool-dashboard v2.1.0
  cool-dashboard: "https://raw.githubusercontent.com/someorg/cool-dashboard/v2.1.0/grafana/dash.json"
```

**Override entry:**
```yaml
  cool-dashboard: |
    ${DS_MIMIR}=prometheus
    ${DS_LOKI}=loki
```

**Patch entry (customize the upstream dashboard):**
```yaml
  cool-dashboard: |
    .title = "Cool Dashboard - Homelab" |
    .tags += ["homelab"] |
    .panels |= map(select(.title != "Sponsorship Banner"))
```
