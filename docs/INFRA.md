# Azure hosting: current state, shared resources, and known pain points

Reference doc for how the Fluent services are hosted on the `Fluent`
subscription today, why the environment behaves the way it does, and what
would improve it. Observed 2026-10-16.

## Current topology

| App | Resource group | Plan | Model | Purpose |
| --- | --- | --- | --- | --- |
| `scribe-server-dev` | Scribe-Dev | `ASP-ScribeDev-a41b` (B1, westeurope) | zip deploy (`RUN_FROM_PACKAGE`) | fluent-api dev (`dev.api.fluent.bible`) |
| `fluent-ai-dev` | Scribe-Dev | same plan | container (GHCR) | fluent-ai dev |
| `fluent-server-qa` | Fluent-QA | `ASP-FluentPROD-b536` (B1, centralindia) | zip deploy | fluent-api QA (`qa.api.fluent.bible`) |
| `fluent-ai-qa` | Fluent-QA | same plan | container (GHCR) | fluent-ai QA |
| `fluent-server-prod` | Fluent-PROD | same plan | zip deploy | fluent-api prod (`api.fluent.bible`) |
| `fluent-ai-prod` | Fluent-PROD | same plan | container (GHCR) | fluent-ai prod |
| `scribe-web-dev`, `fluent-web-qa`, `fluent-web-prod` | respective RGs | — | `Microsoft.Web/staticSites` | fluent-web frontends (managed static hosting, no plan) |

Key Vault: `scribe-dev-key-vault`.

## Databases

Three Azure Database for PostgreSQL Flexible Servers, one per environment.
Queried with `az postgres flexible-server` and `az monitor metrics` on
2026-10-16.

| | `scribe-dev-db` | `fluent-db-qa` | `fluent-db-prod` |
| --- | --- | --- | --- |
| Resource group | Scribe-Dev | Fluent-QA | Fluent-PROD |
| Region / zone | West Europe / 1 | Central India / 3 | Central India / 1 |
| Postgres version | 16 | **18** | 16 |
| SKU | Standard_B1ms, Burstable (1 vCore, 2 GiB) | same | same |
| Storage | 32 GB P4, 120 IOPS, auto-grow off | same | same |
| High availability | Disabled | Disabled | Disabled |
| Backups | 7 days, geo-redundant off | same | same |
| Network | Public access, no VNet, no private endpoint | same | same |
| Firewall rules | `0.0.0.0–255.255.255.255` (AllowAll), plus `0.0.0.0` (Allow Azure services) | `0.0.0.0–255.255.255.255` (AllowAll) | `0.0.0.0–255.255.255.255` (AllowAll) |
| Auth | Password only (Entra ID off), `scram-sha-256` | same | same |
| TLS | `require_secure_transport=on`, TLS 1.2 minimum | same | same |
| `max_connections` | 50 (adjustable 25–5000) | 50 | 50 |
| Built-in PgBouncer | Not available on Burstable | same | same |
| Maintenance window | System-managed | same | same |
| Databases | `fluentdb`, `scribedb` | `fluentdb` | `fluentdb` |
| Created | 2025-06-27 | 2026-08-27 | 2025-09-30 |

### Usage (30 days to 2026-10-16, hourly samples)

| | CPU avg / peak | Memory avg / peak | Storage used | Connections avg / peak | IOPS consumed | Egress / ingress |
| --- | --- | --- | --- | --- | --- | --- |
| dev | 11.6% / 79% | 59% / 90% | 4.56 GB (14%) | 15 / 41 | ~0.1% (peak 4%) | 51 / 37 GB |
| QA | 10.4% / 100% | 62% / 89% | 4.45 GB (13%) | 12 / 39 | ~0.1% (peak 9%) | 43 / 29 GB |
| prod | 13.5% / 100% | 61% / 89% | 4.46 GB (13%) | 12.5 / 34 | ~0.1% (peak 4%) | 46 / 29 GB |

CPU credits never deplete (288 remaining throughout), so the CPU load is
light, with brief spikes. **Memory and connections are the constraints.**
Memory peaks near 90% of 2 GiB. Connection peaks of 34–41 are close to the
50 limit, and the apps' pool settings allow about 55 per environment:
fluent-api app 10 + pg-boss 10, the worker the same again, and fluent-ai
5 + 10 overflow.

### Cost (list price, 730 h/month)

| | Compute | Storage (32 GB) | Total |
| --- | --- | --- | --- |
| dev (West Europe) | $0.0199/h = $14.53 | $0.1369/GB = $4.38 | **$18.91** |
| QA (Central India) | $0.0245/h = $17.89 | $0.1310/GB = $4.19 | **$22.08** |
| prod (Central India) | $0.0245/h = $17.89 | $0.1310/GB = $4.19 | **$22.08** |
| **All three** | | | **≈ $63/month** |

Backup storage up to the provisioned size is free. These are Azure Retail
Prices API list prices, so credits or sponsorship on the subscription would
reduce the actual bill.

### Findings

- **The firewalls allow every IPv4 address** on all three servers. With
  password-only auth, all three accept login attempts from the whole
  internet, prod included.
- **QA runs Postgres 18 while prod runs 16.** QA isn't validating the
  version that prod runs.
- **Dev carries a second database, `scribedb`.** It is probably a leftover
  from the Scribe era. Confirm before removing it.
- **Egress is high for idle 4.5 GB databases** (43–51 GB/month each). The
  likely source is polling: pg-boss supervise and monitor run every 60s,
  and the fluent-ai job loop polls as well. It costs nothing in-region, but it
  would be billed if the database and compute were in different clouds.
- **Merging dev and QA onto one server saves little on Azure.** Dropping one
  B1ms saves about $19/month, but the combined connection and memory peaks
  would exceed a B1ms. The next size up (B2s: 2 vCores, 4 GiB, ≈ $75.73/month
  in Central India) costs more than the two B1ms servers it would replace. A
  merge would also need several prerequisites:
  - dev and QA moved into the same region;
  - their Postgres versions aligned;
  - configurable role names, because roles are server-wide and `api_user`,
    `api_migrator`, `ai_user` and `ai_migrator` are hardcoded in
    fluent-api's `provision-db.ts` and in a fluent-ai migration.

## The shared-plan fact

`ASP-FluentPROD-b536` is a single **B1** (1 vCore, 1.75 GB RAM, 1 instance)
hosting **four apps: both QA apps and both prod apps**. Apps on a plan are
separate processes/containers but share the VM's CPU, RAM, disk, and network.

Consequences:

- **Restarting a QA app does not take prod down.** App lifecycle is per-app;
  `az webapp restart` recycles only that app's process.
- **Plan-level operations affect all four at once** — SKU resize, scale
  changes, plan restart, and Azure platform maintenance share one window.
- **Resource contention is the real risk.** One misbehaving or loaded app
  starves the rest. Concrete case: `fluent-ai-qa` holds a 256 MiB TTS
  synthesis buffer plus ffmpeg encode spikes on the same 1.75 GB VM as prod.
  There are no isolation boundaries between apps on a plan.
- **Plan metrics blend all four apps**, so CPU/memory regressions are hard
  to attribute.
- Plans bill per plan, not per app — sharing is "free" compute, which is
  presumably why QA landed on the prod plan. `ASP-ScribeDev-a41b` already
  carries dev alone, so the pattern isn't needed.

## Why the platform feels inconsistent

Observed symptoms — slow to come back after settings changes, opaque
monitoring, long deploys, Kudu quirks — are mostly explainable:

1. **B1 Basic, single instance, no slots.** Slots require Standard+. Every
   App Settings change recycles the app's only instance in place — a real
   outage window, not a rolling update. There is no second instance to hold
   traffic and no slot to warm and swap.
2. **Container apps re-pull on restart.** fluent-ai pulls a digest-pinned
   image from GHCR on container start. The image carries ~129 MB of ffmpeg
   and the full Python stack; on a 1-vCore box this is minutes, not seconds.
   Worse, `DOCKER_REGISTRY_SERVER_PASSWORD=None` (literal string) is set on
   all three fluent-ai apps while the GHCR package is **private** — a cold
   pull cannot authenticate, so a restart can leave the app dark while ARM
   still reports `Running`. (fluent-ai-qa exhibited exactly this on
   2026-10-16 after a settings change: 35+ min of timeouts on a proven-good
   image digest.)
3. **Kudu-era deploy model.** fluent-api zip-deploys with
   `WEBSITE_RUN_FROM_PACKAGE=1`: the package is mounted read-only as wwwroot
   by a sidecar SCM site. Known quirks — locked files, orphaned mount state,
   "deployed but serving old code" — are why deploy workflows carry
   `clean: true` plus a sleep-and-poll verify loop.
4. **Monitoring is thin by configuration, not just tier.** fluent-ai-qa has
   all logging Off (`applicationLogs`, httpLogs, failed-request tracing all
   disabled), so a crash-looping container leaves no retrievable trace from
   `az webapp log` — "Running" in ARM while the process never serves. On a
   shared plan, plan-level metrics don't isolate the culprit either.
5. **Comparison point.** Vercel is serverless (no warm VM whose restart is
   your problem) and Fly.io gives each app dedicated micro-VMs with fast
   scheduling. The Web App + Kudu stack predates both models. Azure's modern
   equivalent is **Container Apps** — revision-based deploys (new revision
   warms, traffic shifts, old drains), per-app isolation, scale-to-zero —
   and our services are already container-shaped for fluent-ai.

## Improvement paths (roughly in order of effort)

1. Split the QA apps onto their own B1 — removes prod/QA contention and
   plan-op coupling for a few dollars a month.
2. Fix `DOCKER_REGISTRY_SERVER_PASSWORD` on the fluent-ai apps (real GHCR
   PAT, or make the package public deliberately and drop the bogus value).
3. Enable docker/container logging + App Insights availability tests so a
   failed container is observable instead of silent.
4. Move prod to Standard S1+ with staging slots — slot swaps give
   zero-downtime deploys and instant rollback.
5. Longer term: evaluate Azure Container Apps for fluent-ai (and possibly
   fluent-api) — the revision model fixes the restart-and-pray cycle at its
   root.
