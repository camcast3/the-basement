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

### 1. Add entry to the external dashboard registry ConfigMap

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

### 2. Add a Renovate custom regex manager

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

### 3. Commit

Commit both files together with a message following this pattern:

```
feat: add <short-name> external dashboard (pinned <tag>)
```

Include the standard Co-authored-by trailer.

## Architecture context

The Grafana deployment uses an **init container** (`fetch-external-dashboards`)
that reads every key from the `grafana-external-dashboards` ConfigMap, downloads
the URL, and saves it as `<key>.json` into an emptyDir volume. A separate
dashboard provider mounts that volume under the **"Scraparr"** folder in
Grafana (this folder name may be updated to something generic like "External"
if more dashboards are added).

No changes to the Deployment spec or init container script are needed — just
add entries to the ConfigMap and Renovate config.

## Validation checklist

Before committing, verify:
- [ ] The raw GitHub URL returns valid JSON (test with `curl` or `web_fetch`)
- [ ] The ConfigMap key is unique and kebab-case
- [ ] The Renovate regex matches the URL in the ConfigMap
- [ ] The `renovate.json` file is valid JSON
- [ ] The tag exists as a GitHub release on the source repo

## Example

Adding the Scraparr dashboard:

**ConfigMap entry:**
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
