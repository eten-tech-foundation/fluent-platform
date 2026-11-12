# Proposal: host Fluent compute on Fly.io, keep Postgres on Azure

What it would take to run `fluent-api`, `fluent-ai`, and `fluent-web` on
Fly.io while each environment keeps connecting to its existing Azure Database
for PostgreSQL server. Assessed against `origin/main` of all three repos on
2026-10-16.

Related:

- [`../../INFRA.md`](../../INFRA.md) — how the services are hosted on Azure
  today and why that environment is painful. This proposal is one answer to
  its "improvement paths".
- [`../fluent-ai-deployment/plan.md`](../fluent-ai-deployment/plan.md) — the
  Azure Container Apps alternative for `fluent-ai`. ACA solves many of the
  same problems without moving compute off Azure, so it needs no
  cross-cloud database link. Weigh the two against each other.

## Summary

All three services can run on Fly. They are not equally ready:

| Service      | Readiness | Main work                                                                                                                                               |
| ------------ | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fluent-ai`  | High      | Already ships a digest-pinned production image. Needs a `fly.toml`, a registry Fly can pull from, and graceful-shutdown settings.                       |
| `fluent-web` | Medium    | A static SPA. Needs a small Caddy/nginx image that reproduces the SWA headers, CSP, and SPA fallback.                                                   |
| `fluent-api` | Low       | No production Dockerfile. The worker is an Azure WebJob. Config lives only in App Service settings. `/health` version reporting depends on `npm start`. |

The deciding question is **where the database lives relative to the
compute**. Fly has no region in India, and QA and prod run in Azure Central
India, so placing those two environments is a product and data-residency
decision before it is an infrastructure one. Reachability turned out not to
be a blocker: the Azure servers accept connections from any IP (see
`INFRA.md` § Databases). Database hosting options, including Fly Managed
Postgres and Neon, are compared in
[`database-hosting-options.md`](database-hosting-options.md). Everything
else is ordinary porting work.

## Current state (as relevant to a move)

|                | fluent-api                                                                                   | fluent-ai                                                                                            | fluent-web                                    |
| -------------- | -------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| Host           | App Service, zip deploy (`RUN_FROM_PACKAGE`)                                                 | App Service, container from GHCR                                                                     | Static Web Apps                               |
| Build artifact | `dist/` + `node_modules` zip; only `Dockerfile.dev` exists                                   | Multi-stage prod `Dockerfile`, pushed to GHCR as `sha-<commit>`, deployed by digest                  | `vite build`; `VITE_*` baked in at build time |
| Processes      | HTTP API, plus a pg-boss worker packaged as a continuous WebJob by `scripts/setup-webjob.js` | uvicorn `--workers 1`; the AI-suggestion loop runs in-process (`app/worker/suggestion_processor.py`) | Static files                                  |
| Migrations     | `drizzle-kit migrate` run from the GitHub runner in `deploy.yml`                             | `alembic upgrade head` run from the GitHub runner in `deploy.yml`                                    | n/a                                           |
| Runtime config | Only in App Service settings; `deploy.yml` sets none                                         | `deploy.yml` sets a subset; R2/TTS settings are not in it                                            | `VITE_*` from GitHub Environment secrets      |
| Health         | `GET /health` reports `npm_package_version`                                                  | `GET /health` reports `commit` (`APP_COMMIT_SHA`)                                                    | n/a                                           |

Regions (from `INFRA.md`): dev runs in **westeurope**. QA and prod run in
**centralindia**.

## Target topology

Each environment gets three Fly apps (dev, qa, prod), for nine in total. Each
environment's apps go in the Fly region closest to its database:

| Environment | Database region (Azure)  | Nearest Fly region                     |
| ----------- | ------------------------ | -------------------------------------- |
| dev         | westeurope (Netherlands) | `ams` (same metro)                     |
| qa, prod    | centralindia (Pune)      | `sin` (Singapore): **no India region** |

**Fly has no India region.** This was checked against Fly's platform-regions
API on 2026-10-16; an earlier draft of this doc wrongly assumed `bom`. With
the databases left in Central India, QA and prod compute in `sin` would
cross a border on every query, likely 50–70 ms per round trip (not
measured). The options for QA and prod:

- keep their compute on Azure;
- move their data to a Singapore- or Europe-hosted database;
- accept the latency.

See [`database-hosting-options.md`](database-hosting-options.md). If the
database moves to Neon, dev compute belongs in `fra` (next to Neon's
Frankfurt region) rather than `ams`.

```
              public (TLS, custom domains under fluent.bible)
  <env>.fluent.bible ─────► fluent-web-<env>   (Caddy/nginx serving dist/)
  <env>.api.fluent.bible ─► fluent-api-<env>   [process: app]  ───┐
                            fluent-api-<env>   [process: worker] ─┤
                                                                  │  Flycast (private, 6PN)
                                    fluent-ai-<env> ◄─────────────┘  (no public IP)
                                          │
        fluent-api + fluent-ai ───────────┴── TLS ──► Azure Postgres (<env> server)
                                                       Cloudflare R2 (EU jurisdiction)
```

The web hostnames above are illustrative. Use the existing ones.

### fluent-api

One image with two process groups. The `worker` process group replaces the
WebJob, which retires `setup-webjob.js`, the WebJob step in `build.yml`, and
the `webjob-singleton-lock-recovery` runbook.

```toml
app = "fluent-api-dev"
primary_region = "ams"
kill_signal = "SIGTERM"
kill_timeout = 60          # worker waits up to 30s for jobs, then pg-boss stops for up to 30s

[env]
  NODE_ENV = "production"  # required for the .fluent.bible cookie domain, secure cookies, and the App Insights logger
  PORT = "9999"
  FLUENT_AI_URL = "http://fluent-ai-dev.flycast"

[processes]
  app    = "node dist/src/index.js"
  worker = "node dist/src/workers/standalone-worker.js"

[http_service]
  internal_port = 9999
  force_https = true
  processes = ["app"]
  auto_stop_machines = "off"   # the API process also runs the DLQ monitor and the audio reclaim sweep
  min_machines_running = 1
  [[http_service.checks]]
    path = "/health"
    interval = "15s"
    timeout = "5s"
    grace_period = "20s"
```

The worker process has no `services`, so Fly never auto-stops it.

### fluent-ai

- Deploy the existing image by digest (`fly deploy --image <ref>@sha256:…`).
  The build-once, promote-by-digest model stays as it is.
- **Private only.** Allocate a private Flycast address
  (`fly ips allocate-v6 --private`) and no public IPs. `fluent-web` never
  calls `fluent-ai` directly. Every request is proxied through `fluent-api`.
  `fluent-ai` calls back into the API via
  `API_BASE_URL=http://fluent-api-<env>.flycast`.
- `force_https = false`: Flycast is plain HTTP over Fly's WireGuard mesh.
- `auto_stop_machines = "off"` with `min_machines_running = 1`. A stopped
  machine stops polling `ai.jobs`, and suggestions stall.
- `kill_signal = "SIGTERM"` and `kill_timeout ≈ 45`, to cover
  `--timeout-graceful-shutdown 30` plus lifespan shutdown.
- **Exactly one machine.** The Dockerfile documents that `--workers 1` is
  load-bearing: the TTS generation heap (RAM budget and dedup) is
  per-process. A second machine breaks it the same way a second worker would:
  the same verse is synthesized and billed twice, and each machine spends its
  own `TTS_MAX_BUFFERED_BYTES`.
- Size: roughly 1–2 GB of RAM. That covers the 256 MiB TTS budget with about
  1.5x headroom, plus the interpreter baseline and the ffmpeg subprocess.
- `APP_COMMIT_SHA` is set per deploy (`fly deploy --env APP_COMMIT_SHA=…`)
  so `/health` keeps reporting the commit.

### fluent-web

- A multi-stage image: the Node stage runs `pnpm build` with `VITE_*` as build
  args, and the runtime stage is Caddy or nginx serving `dist/`. There is one
  image per environment, as the SWA builds already are.
- Reproduce what `staticwebapp.config.json` gives SWA: the global security
  headers (CSP with the inline-script hash, HSTS, frame, referrer and
  permissions policies), and the `index.html` navigation fallback with its
  asset exclusions.
- Auto-stop is acceptable here. `min_machines_running = 1` avoids a
  cold-start on first load.
- This is the least-coupled service. Leaving it on SWA, or moving it to
  Cloudflare Pages (we already use R2), are both reasonable. Then only
  `VITE_API_URL` changes.

### CI/CD

- Replace `azure/webapps-deploy` and `Azure/static-web-apps-deploy` with
  `superfly/flyctl-actions`. Store a per-app deploy token
  (`fly tokens create deploy -a <app>`) as `FLY_API_TOKEN` in each GitHub
  Environment. Keep the existing pattern of the same secret names in every
  environment, scoped by the environment rather than by suffix.
- **Keep migrations on the GitHub runner** for both services, as they run
  today. Do not move them to Fly's `release_command`. It runs on a temporary
  machine that will not have a static egress IP (see blocker 1). Also,
  `drizzle-kit` is a dev dependency and would not be in the production
  image.
- Keep the `/health` version and commit assertion. For `fluent-ai`, which
  has no public address, check via Fly instead of a public URL: Fly's deploy
  health checks, machine status, or
  `fly ssh console -C "curl -fsS localhost:8200/health"`.

## Gaps to close before deploying

### Blockers

1. **Database placement and network exposure.** As of 2026-10-16, all
   three Azure servers use public access with no VNet, and an AllowAll
   firewall rule (`0.0.0.0–255.255.255.255`). So Fly can connect today with
   no networking work. The remaining problems:
   - **Latency for QA and prod.** Fly has no India region; see the target
     topology above.
   - **Exposure.** AllowAll with password-only auth is a security gap
     regardless of Fly. Tightening the rule to Fly means static egress IPs,
     which Fly assigns per machine (`fly machine egress-ip allocate`). Every
     new machine, including scale-outs and replacements, needs its own IP
     and firewall rule, and `release_command` machines get none. GitHub
     runners, which run migrations, also need a path in.
   - **Moving the database** to Fly Managed Postgres or Neon changes all of
     this. See [`database-hosting-options.md`](database-hosting-options.md).

2. **No production Dockerfile for fluent-api.** `Dockerfile.dev` uses
   `node:22.15` while `engines` requires `>=24.14.0`. It also runs
   `tsx watch` and the superuser `bootstrap.ts` on start, which must never
   ship to a deployed environment. A production image needs:
   - a builder stage with `python3`, `make` and `g++` for the native
     tree-sitter build that `usfm-grammar` pulls in, using
     `CXXFLAGS=-std=c++20` as CI does;
   - a check that `npm ci` succeeds without the `--legacy-peer-deps` that CI
     uses with `npm install`;
   - dev dependencies removed (`npm prune --omit=dev`), a non-root user, and
     `dumb-init`, matching the `fluent-ai` image.

3. **`/health` would report the wrong version.** `src/routes/health.route.ts`
   reads `process.env.npm_package_version`, which npm sets only under
   `npm start`. Run as `node dist/...`, it reports `1.0.0`, and the deploy
   verification that compares versions fails. Inject `APP_VERSION` and
   `APP_COMMIT_SHA` env vars, the way `fluent-ai` does.

4. **Custom domains under `fluent.bible` are mandatory.** better-auth cookies
   are scoped to `BETTER_AUTH_COOKIE_DOMAIN=.fluent.bible` with
   `SameSite=Lax` (`src/lib/auth.ts`). CORS and `trustedOrigins` accept only
   `FRONTEND_URL` or `*.fluent.bible` (`src/server/server.ts`). `*.fly.dev`
   is on the public suffix list, so a web app and API on `fly.dev` hostnames
   cannot share a session. Plan `fly certs add` and DNS cutover for every
   environment's hostnames, and keep `FRONTEND_URL`, `BETTER_AUTH_URL`, and
   `VITE_API_URL` consistent with them.

5. **Collect the full config.** `fluent-api`'s runtime settings exist only in
   App Service: database URL, better-auth secret, Mailgun, R2 buckets,
   Aquifer, YouVersion, DBL, App Insights, and `EN_FEATURE_*`. `fluent-ai`'s
   R2/TTS settings (`R2_*`, `R2_TTS_BUCKET`, `TTS_HASH_SECRET`,
   `TTS_PUBLIC_AUDIO_BASE_URL`, …) are not in its workflow either.
   - Export them per app with `az webapp config appsettings list`.
   - Reconcile them against `src/env.ts` and `app/config.py`.
   - Load them with `fly secrets import`.
   - Record the inventory (names only) so it cannot drift again. Key Vault
     (`scribe-dev-key-vault`) could stay the source of truth, synced into
     Fly secrets by CI.

6. **fluent-web's headers and CSP depend on SWA.** `scripts/generate-csp.ts`
   writes the inline-script hash into `staticwebapp.config.json`, which only
   SWA reads. Generate the Caddy or nginx header config from that JSON at
   build time so the CSP keeps a single source of truth.

7. **Graceful shutdown.** Fly defaults to `kill_signal = SIGINT` and
   `kill_timeout = 5s`. The services expect 30–60s to drain:
   - the API worker's 30s active-job wait, then the pg-boss stop with a 30s
     timeout;
   - the WebJob's `stopping_wait_time: 60`;
   - uvicorn's `--timeout-graceful-shutdown 30`.

   Set both values explicitly, or deploys will kill in-flight jobs and TTS
   generations.

8. **Image registry access.** The GHCR package is private. `INFRA.md`
   records Azure failing cold pulls for exactly this reason. Either copy the
   image to `registry.fly.io/<app>` in CI (for example `crane copy`, which
   keeps the digest), or make an explicit decision to publish the GHCR
   package. Check whether Fly can pull from a private third-party registry
   before relying on it.

### Should fix (hardening)

- **Verify database TLS.** fluent-api's postgres.js URLs use
  `sslmode=require`, and fluent-ai's asyncpg defaults to `prefer`. Neither
  verifies the server certificate. Within Azure that risk was lower; across
  the public internet, use `verify-full` with the Azure root CA.
- **Connection budget.** Each `fluent-api` process (app or worker) can hold
  up to 10 Drizzle connections plus 10 pg-boss connections. `fluent-ai` can
  hold up to 5 plus 10 overflow. Two API app machines, one worker and one AI
  machine is about 75 connections. The Azure B1ms servers cap at 50 and
  already peak at 34–41, with no PgBouncer available on Burstable.
- **fluent-ai observability.** It logs to stdout only, and Fly does not
  retain logs long. Add a log shipper (`fly-log-shipper`) or OpenTelemetry.
  `fluent-api` keeps App Insights, which needs only the connection string and
  works from anywhere.
- **Worker liveness.** The worker has no HTTP endpoint. Add an App Insights
  alert for when the `Worker heartbeat` trace stops (it is emitted every 5
  minutes). That is the failure mode the WebJob runbook describes.
- **Client IP derivation.**
  - `RATE_LIMIT_TRUSTED_HOPS=1` should hold, since Fly's proxy appends the
    client IP to `X-Forwarded-For`. Confirm that, and raise it if Cloudflare
    proxying is placed in front.
  - better-auth's built-in rate limiter, and the sign-out audit log in
    `server.ts`, read raw `x-forwarded-for`, which a client can spoof. Point
    better-auth's IP header at `fly-client-ip`.
- **Scaling fluent-api past one app machine.**
  - The custom rate limiter and better-auth's rate limiter are both in
    memory, so effective limits multiply by the machine count.
  - The verse-audio reclaim sweep runs in every API process. Confirm it is
    safe to run concurrently first.
- **Cross-cloud egress cost.** Every query result now leaves Azure, so Azure
  bills internet egress on it, and Fly bills its own outbound traffic.
  Probably small at current load, but estimate it.
- **Data residency.** Keep each environment's apps pinned to its region. Do
  not add regions outside the database's jurisdiction. R2 stays
  EU-jurisdiction regardless.

## Cutover

1. Answer blocker 1 for the dev database, since it gates the rest.
2. Land the `fluent-api` production Dockerfile and the `/health` version fix
   in `fluent-api`. Both are useful on Azure too.
3. Collect the config and create the dev Fly apps, secrets, and certs.
4. Run Fly-dev alongside Azure-dev against the same dev database, then switch
   DNS. The overlap is safe for queues: pg-boss and `fluent-ai`'s
   `FOR UPDATE SKIP LOCKED` loop both claim each job atomically. The one
   cost is that TTS dedup splits across two `fluent-ai` processes for the
   overlap window.
5. Rewrite each repo's `deploy.yml` for Fly. Then repeat for QA and prod,
   once their database placement is decided (blocker 1).
6. After a stable period, remove the WebJob packaging, the
   `staticwebapp.config.json` dependency, the Azure deploy secrets, and the
   App Service resources.

## Open questions

- Why are QA and prod in Central India: user proximity or data residency?
  Is moving prod data out of India acceptable? The answer decides whether
  Fly fits QA and prod at all. Networking and co-location are answered in
  `INFRA.md` § Databases: public access, AllowAll firewall, same regions as
  the App Service plans.
- Should `fluent-web` move to Fly, stay on SWA, or go to Cloudflare Pages?
- Is a single `fluent-ai` machine per environment (no HA) acceptable? It is
  what the TTS design requires today. Supporting more needs shared dedup
  state.
- Fly versus Azure Container Apps (see `fluent-ai-deployment`): is leaving
  Azure compute worth a cross-cloud database link?
