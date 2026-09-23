# Odoo SRE & Infrastructure Challenge — much. Consulting

Production-ready Odoo deployment, built for the stated growth target
(50 → 500+ customers, thousands of servers).

**Start here:** [`DESIGN.md`](./DESIGN.md) — explains every decision,
assumption, and known trade-off.

## Contents

```
charts/odoo/          Helm chart — the actual production deliverable
  Chart.yaml
  values.yaml
  secrets.example.yaml  documents expected Secret shape (never applied as-is)
  templates/
    deployment.yaml           Odoo Deployment (non-root, read-only rootfs, probes)
    configmap.yaml             odoo.conf template + entrypoint.sh (secrets rendering)
    service.yaml, service.yaml (HPA + PDB), ingress.yaml
    networkpolicy.yaml         default-deny-shaped NetworkPolicy
    postgresql-statefulset.yaml   self-hosted Postgres option
    backup-cronjob.yaml        nightly DB + filestore backup, with verification
    servicemonitor.yaml        Prometheus scraping + postgres_exporter

local/                 Docker Compose — fast local review only, NOT production
  docker-compose.yml
  config/odoo.conf
  secrets/             (gitignored; see secrets/README.md)
```

## Quick review (no cluster needed)

```bash
cd local
cp secrets/db_password.txt.example secrets/db_password.txt
cp secrets/admin_password.txt.example secrets/admin_password.txt
docker compose up -d
docker compose logs -f odoo
# http://localhost:8069
```

## Production install (Kubernetes)

```bash
# 1. Create the two secrets this chart expects (see secrets.example.yaml for shape).
#    In real environments, these come from External Secrets Operator / Sealed
#    Secrets, not `kubectl create secret` directly.

# 2. Install
helm install odoo ./charts/odoo -f my-values.yaml -n odoo-<tenant> --create-namespace

# 3. Watch NOTES.txt output for first-run DB init instructions.
```
