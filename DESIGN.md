# DESIGN.md — Odoo on our own infrastructure

## Scope and assumptions

This solution targets the stated growth path — 50 to 500+ customers, thousands
of servers — which is why I chose **Kubernetes via Helm** as the primary
deliverable rather than a single-host Docker Compose file. Compose is included
under `local/` as a fast, honest way to review the same core decisions in two
minutes without a cluster; it is not the production answer.

I made the following explicit assumptions, open to challenge in the
interview:

- **Multi-tenancy model**: one Odoo database per customer (Odoo's native
  multi-database support), with a shared pool of stateless application pods
  in front. This chart is written per-tenant-namespace-able: the same chart
  can be installed once per customer namespace, or fronted by a router that
  picks the right `db_name` per request. I did not build the tenant-routing
  layer itself — that's a genuine open design question I'd want to align on
  with the team (shared cluster with namespace-per-tenant vs. shared
  cluster with DB-per-tenant behind one Odoo pool vs. cluster-per-tenant),
  and the right answer depends on isolation and compliance requirements I
  don't have visibility into yet.
- **Cloud-agnostic where it matters, opinionated where it doesn't**: the chart
  doesn't hardcode a cloud provider, but `values.yaml` assumes an ingress
  controller (nginx) and cert-manager are already present in the cluster,
  since re-implementing those isn't the point of this exercise.
- **Odoo version 17.0**, since it's the version where Odoo added a real
  `/web/health` endpoint to the official image (versions before ~16.3 have no
  equivalent, which matters for the liveness/readiness design below).

## Why Helm over Docker Compose

Compose is the right tool for a single host. It has no answer for what
happens when that host dies, no rolling updates, no autoscaling, and no
native way to spread tenants across machines. Given the stated destination —
thousands of servers — building the production artifact as a Kubernetes-native
Helm chart from day one avoids a second migration later. The trade-off is
genuine, though: Compose is simpler to operate for the first few customers,
and if the team isn't running Kubernetes yet, the migration cost to get there
is real and worth discussing openly rather than assuming.

## Security hardening

- **Non-root by default, not by accident**: `securityContext.runAsUser: 101`
  is set explicitly rather than trusted from the image, so if a future base
  image update silently reverts to root, the pod fails to start instead of
  quietly running privileged. `allowPrivilegeEscalation: false` and
  `capabilities.drop: [ALL]` remove the ability to regain privilege even if a
  process inside the container is compromised.
- **Read-only root filesystem**: the container filesystem is mounted
  read-only; the only writable paths are the filestore PVC and a `tmpfs` for
  `/tmp`. This means a remote code execution bug in an installed Odoo module
  can't persist a webshell to disk — there's nowhere writable to put it,
  outside actual data volumes.
- **No secrets in ConfigMaps or images**: `odoo.conf` is a *template* in the
  ConfigMap with no real values in it. Actual credentials arrive as
  Kubernetes Secrets, mounted as files (not env vars) into `/run/secrets/...`,
  matching the official image's `*_FILE` convention. `entrypoint.sh` reads
  those files, renders the real config into a `tmpfs` path with `envsubst`,
  and unsets the shell variables immediately after — so credentials never sit
  in `env | grep PASSWORD` output on a running container, and never touch
  disk outside `tmpfs`. In production, the Secrets themselves are populated
  by External Secrets Operator or Sealed Secrets from AWS Secrets Manager /
  GCP Secret Manager — `secrets.example.yaml` documents the expected shape
  but is never applied as-is.
- **NetworkPolicy, default-deny shaped**: Odoo pods only accept ingress from
  the ingress-controller namespace and the monitoring namespace; egress is
  limited to DNS, the Postgres pod selector, and HTTPS/443 (needed for
  outbound email relays, payment gateway callbacks, and license/update
  checks). This matters most in a shared multi-tenant cluster: without it,
  a compromised pod for tenant A can reach tenant B's database on the same
  network.
- **Ingress terminates TLS via cert-manager** (Let's Encrypt), with
  `proxy_mode = True` set in Odoo so it correctly trusts `X-Forwarded-*`
  headers from the ingress rather than seeing the ingress controller's IP as
  the client.

**What I'd still want to add before calling this production-ready**: a
PodSecurityAdmission/OPA Gatekeeper policy enforcing these securityContext
settings cluster-wide (so a future chart change can't silently drop them),
and an image-scanning gate in CI (Trivy/Grype) on the Odoo base image before
deploy.

## Data persistence and backup strategy

Odoo has two stateful pieces that must be backed up **together**: the
PostgreSQL database and the filestore (attachments — invoices, uploaded
documents, images). This is the detail I most wanted to get right, because
it's also the easiest thing to get subtly wrong.

- **Filestore**: an `ReadWriteMany` PVC (e.g., EFS/Filestore/Azure Files
  depending on cloud) shared across all Odoo replicas, since any replica may
  serve any request and all need to see the same attachments.
- **Database**: for a real deployment I would default to a **managed service**
  (RDS/Cloud SQL) rather than the self-hosted `StatefulSet` included here —
  it gives automated failover, point-in-time recovery, and patching without
  us building it. The chart supports both (`postgresql.host` set = use
  managed; empty = use the bundled StatefulSet), and I included the
  StatefulSet mainly so this repository is runnable end-to-end without
  external dependencies, and so the tradeoffs are visible rather than hidden
  behind "just use RDS."
- **Backup CronJob** runs nightly, and deliberately does three things many
  backup scripts skip:
  1. Dumps the database with `pg_dump --format=custom` (enables parallel and
     selective restore later — a plain SQL dump doesn't).
  2. Archives the filestore **with a matching timestamp**, in the same job
     run. A DB backup from 02:00 restored against a filestore snapshot from
     04:00 produces a database with attachment references pointing at files
     that don't exist — a bug nobody notices until a customer opens an
     old invoice and it's blank.
  3. **Verifies the upload** — checksums the local dump, re-reads the
     checksum and size back from S3 after upload, and fails the job (which
     pages on-call via the CronJob failure alert) if they don't match. A
     backup job that reports "success" while silently uploading a truncated
     file is worse than a job that visibly fails, because the gap is only
     discovered during a real restore, under pressure, when it's too late to
     fix.
- **Retention**: 14 days by default, pruned automatically from S3, with
  versioning + a bucket lifecycle policy (not shown in the chart, since it's
  applied at the bucket/Terraform level rather than per-tenant) as a second
  safety net against accidental deletion.
- **What's missing and worth discussing**: this backs up daily, which means
  up to 24h of data loss in a worst case (RPO). If that's not acceptable for
  paying customers, the next step is WAL-shipping / continuous archiving
  (`pgBackRest` or the managed service's native PITR) rather than periodic
  dumps — I'd want to know the business's actual RPO/RTO target before
  over-building this.

## Observability and monitoring

- **Metrics**: `postgres_exporter` is included and wired to a
  `ServiceMonitor`, since Postgres health (connections, replication lag,
  slow queries, lock waits) is usually the leading indicator of an Odoo
  incident, not the application layer. I was honest in the chart comments
  about a real limitation here: **vanilla Odoo does not expose Prometheus
  metrics natively** — the `ServiceMonitor` for the Odoo pods themselves
  assumes either a metrics-exporting module is installed or that we wrap it
  (e.g., an nginx/envoy sidecar exporting request-level metrics from the
  ingress side instead). I'd rather flag this gap directly than quietly
  paper over it with a `ServiceMonitor` that scrapes an endpoint that
  doesn't exist.
- **Logs**: Odoo logs to stdout (`logfile = /dev/stdout`), so log shipping is
  the cluster's job (Fluent Bit / Vector → Elasticsearch or Loki), not
  something baked into this chart — keeps the chart portable across whatever
  logging stack the team already runs.
- **Health probes are split into three, deliberately**:
  - `startupProbe` — up to 5 minutes, since a cold Odoo start (especially
    with module installs) can genuinely take that long, and I don't want the
    liveness probe killing a pod that's just slow to boot.
  - `readinessProbe` — controls whether the pod receives traffic; fails fast
    (30s) so a struggling pod is pulled from the Service quickly.
  - `livenessProbe` — restarts the container; deliberately more lenient
    (30s period, 3 failures) than readiness, since restarting a pod is a
    much more expensive action than just pausing traffic to it.
  - All three hit `/web/health`, added to the official Odoo image in 15.0+.
    Important limitation, worth stating plainly: this endpoint reports that
    the Odoo *process* is alive, not that the database is reachable —
    community discussion around this endpoint confirms it doesn't perform a
    real DB round-trip. That's exactly why the `postgres_exporter` and
    alerting on Postgres connectivity separately matters — the app-level
    health check and the DB-level health check are answering two different
    questions, and conflating them is how "the pod says it's healthy" and
    "customers can't log in" end up being true at the same time.

## Handling silent failures

This is the section I think matters most, and where I tried to be concrete
rather than generic:

1. **The backup that "succeeds" but didn't really** — covered above: checksum
   verification with a hard failure, not just checking `pg_dump`'s exit code.
2. **The health check that says "fine" while the database is down** —
   covered above: don't rely solely on `/web/health`; alert on Postgres
   connectivity and replication lag independently.
3. **A single bad tenant taking down the shared pool**: with `workers = 4`
   (real multi-process, not threaded dev mode) and `limit_time_cpu` /
   `limit_time_real` set, one tenant's runaway report query gets killed and
   restarted rather than blocking every other tenant sharing that pod
   indefinitely. This is a direct consequence of the multi-tenant model
   above — worth re-checking if the tenancy model changes.
4. **Config drift between what's deployed and what's running**: the
   `checksum/config` annotation on the Deployment's pod template forces a
   rollout whenever the ConfigMap changes. Without it, `helm upgrade` can
   update a ConfigMap while old pods keep running with the old config in
   memory — a classic "it's deployed but nothing changed" bug report.
5. **A rollout that silently degrades capacity**: `maxUnavailable: 0` on the
   rolling update strategy plus a PodDisruptionBudget means a deploy or a
   node drain can't take the service below full serving capacity, and the
   `HorizontalPodAutoscaler`'s 5-minute scale-down stabilization window stops
   pods from being removed right before a transient traffic spike returns.

## What I'd do differently with more time / real access to the team

- Build the actual tenant-routing layer (or confirm it already exists
  elsewhere) — this chart handles one tenant well; the multi-tenant
  orchestration on top of it is a bigger, separate design question.
- Replace the honest gap in Odoo-level metrics with a real answer — either a
  vetted community exporter module or an ingress-side metrics sidecar —
  rather than the placeholder comment currently in `servicemonitor.yaml`.
- Move from nightly `pg_dump` to continuous WAL archiving once I know the
  business's actual RPO/RTO requirements.
- Add a disaster-recovery runbook and actually test a restore end-to-end
  (a backup strategy that's never been restored from is a hypothesis, not a
  strategy) — happy to walk through what that test would look like in the
  interview.
