Architecture Overview

This document outlines the deployment plan for `fluent-ai` as an Azure Container App (ACA). The plan includes infrastructure setup, CI/CD pipeline, and operational procedures. It represents the first step moving toward a Git-Ops style deployment for Fluent. This will make deployment environments more consistent, reproducible, and easier to manage.

```
┌─────────────────────────────────────────────────────────────────────┐
│                           GitHub (Source of Truth)                  │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐  │
│  │   fluent-api    │    │   fluent-ai     │    │ fluent-platform │  │
│  │   (app code)    │    │   (app code)    │    │  (infra config) │  │
│  │  Azure Web Apps │    │  GHCR + ACA     │    │   Bicep + env   │  │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │  GitHub Actions │
                    │  (fluent-ai)    │
                    │  build → test   │
                    │  → migrate →    │
                    │  deploy to ACA  │
                    └─────────────────┘
                              │
                    ┌─────────┴─────────┐
                    ▼                   ▼
            ┌──────────────┐    ┌──────────────┐
            │  ACA Dev     │    │  ACA Prod    │
            │  fluent-ai   │    │  fluent-ai   │
            │  (0-1 repl)  │    │  (1-3 repl)  │
            └──────────────┘    └──────────────┘
                    │                   │
                    └─────────┬─────────┘
                              ▼
                    ┌─────────────────┐
                    │ Azure Key Vault │  ← secrets (DB URLs, API keys)
                    │  (dev + prod)   │
                    └─────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │  Azure Postgres │  ← shared managed DB (fluent)
                    │  (dev + prod)   │
                    └─────────────────┘
```


## 1. Image Build & Registry

Registry: GitHub Container Registry (`ghcr.io/eten-tech-foundation/fluent-ai`)

- Free for public repos
- No extra auth needed in GitHub Actions
- Already works with GITHUB_TOKEN
- Tagging strategy:

`ghcr.io/eten-tech-foundation/fluent-ai:sha-<git-sha>` — immutable, what ACA runs
`ghcr.io/eten-tech-foundation/fluent-ai:dev` — mutable, points to latest dev deployment
`ghcr.io/eten-tech-foundation/fluent-ai:prod` — mutable, points to latest prod deployment


## 2. ACA Infrastructure (in fluent-platform)

```
fluent-platform/
└── deploy/
    └── azure/
        ├── bicep/
        │   ├── main.bicep              # ACA Environment + App
        │   ├── modules/
        │   │   ├── aca-environment.bicep
        │   │   └── aca-app.bicep
        │   └── parameters/
        │       ├── dev.bicepparam      # dev-specific values (no secrets)
        │       └── prod.bicepparam     # prod-specific values (no secrets)
        └── workflows/
            └── deploy-fluent-ai.yml    # Reusable ACA deployment workflow
```

Bicep files define:

- ACA Environment (networking, logs)
- ACA App (`fluent-ai-dev` / `fluent-ai-prod`)
- Container configuration (image, CPU, memory, scale rules)
- Key Vault secret references (no secret values in Bicep)
- Health check probes (`/health` endpoint)

No secrets in Git. dev.bicepparam and prod.bicepparam contain only non-sensitive values:

- `imageTag`
- `minReplicas, maxReplicas`
- `logLevel`
- `environmentName` (development / production)
- `Key Vault name and secret names` (not values)


## 3. Secrets Management
Runtime secrets (what the app needs): Stored in Azure Key Vault

- `database-url` → `DATABASE_URL`
- `secret-key` → `SECRET_KEY`
- `openai-api-key` → `OPENAI_API_KEY`
- `anthropic-api-key` → `ANTHROPIC_API_KEY`
- `google-ai-api-key` → `GOOGLE_AI_API_KEY`
- `admin-api-key-hash` → `ADMIN_API_KEY_HASH` (prod only)
- `api-service-key` → `API_SERVICE_KEY` (key fluent-ai presents when calling fluent-api)

ACA pulls these at runtime using Key Vault references. This requires ACA's managed identity (user-assigned, one per environment) to hold `get`/`list` access on the Key Vault's secrets — granted via RBAC (`Key Vault Secrets User` role) or an access policy, provisioned as part of the Bicep `acaEnvironment`/`aca-app` modules, not a manual step:

```json
{
  "name": "DATABASE_URL",
  "secretRef": "database-url"
}
```

Deployment secrets (what CI needs): Stored in GitHub Environment Secrets

- `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID` (or OIDC)
- `AZURE_SUBSCRIPTION_ID`
- `MIGRATIONS_DATABASE_URL` (for running Alembic in CI)
- `BOOTSTRAP_DATABASE_URL` (for first-time DB provisioning)

## 4. Database Migrations

**Critical**: The production `Dockerfile` runs fastapi run directly — it does NOT run migrations. The `docker-entrypoint.sh` with bootstrap/migrate/seed is only used in local dev (via `Dockerfile.dev`).

For production, we follow the fluent-api pattern:

**Migration runs in CI, before app deployment**:



```yaml
- name: Run Alembic migrations
  env:
    MIGRATIONS_DATABASE_URL: ${{ secrets.MIGRATIONS_DATABASE_URL }}
  run: |
    uv sync --frozen --no-dev
    uv run alembic upgrade head
```
Why this works:

- Migrations run once, from a single CI runner
- If migration fails, the deployment stops — no bad code reaches production
- App containers start clean and fast, no bootstrap overhead

**First-time setup**: For a fresh managed DB, run the bootstrap script once manually (or as a one-off CI job):


```bash
BOOTSTRAP_DATABASE_URL="..." uv run python scripts/bootstrap.py
```


## 5. GitHub Actions Workflow (fluent-ai/.github/workflows/deploy.yml)
**Note**: `fluent-ai` currently has no `.github/workflows` directory at all — this is net-new CI/CD, not an edit to an existing pipeline. It also needs GitHub Environments (`Development`/`Production`) created and OIDC/service-principal credentials configured from scratch, following the pattern already established in `fluent-api/.github/workflows/post-merge-deploy.yml`.

On push to `main`:

- Lint, format check, type check, test
- Build production Docker image
- Tag with Git SHA + `dev`
- Push to GHCR
- Run Alembic migrations against dev DB
- Deploy to ACA dev app (using Bicep from `fluent-platform`)

On `workflow_dispatch` with `environment: prod`:

- Build production Docker image (or reuse existing SHA-tagged image)
- Tag with prod
- Push to GHCR
- Run Alembic migrations against prod DB
- Deploy to ACA prod app


## 6. Auto-scaling
| | Dev | Prod |
| -- | -- | -- |
| Min replicas | 0 (scales to zero when idle) | 1 (avoids cold start) |
| Max replicas | 1 | 3 |
| CPU | 0.5 | 0.5 |
| Memory | 1 GB | 1 GB |

ACA's consumption-plan free grant is usage-based (a monthly allotment of vCPU-seconds, GiB-seconds, and requests — not a flat "2 vCPU / 4GB" allocation); verify current thresholds against Microsoft's ACA pricing page before relying on this for cost planning. With low traffic, dev should cost essentially nothing. Prod will be ~$5-15/mo depending on traffic.

## 7. Networking & Service Discovery
- `fluent-ai` ACA app gets a public URL: `https://fluent-ai-dev.<region>.azurecontainerapps.io`
- `fluent-api` (Azure Web Apps) calls it via this URL
- `fluent-ai` calls `fluent-api` via the Web App URL (`API_BASE_URL` env var): `https://fluent-server-prod.azurewebsites.net` (or dev equivalent), authenticated with the `API_SERVICE_KEY` secret
These URLs are stored as non-secret env vars in the Bicep parameters

## 8. Final Design: Azure Container Apps + fluent-platform Orchestrator
### Philosophy
- **Dev**: Fast, cheap, lightweight. Azure CLI deploy from GitHub Actions. Scales to zero.
- **Prod**: Reproducible, auditable, robust. Bicep IaC in fluent-platform. Explicit workflow_dispatch for deployments.
- **Shared**: Both use the same image (GHCR), same Key Vault secret model, and same migration strategy.
### File Structure

```
fluent-ai/
└── .github/
    └── workflows/
        └── deploy.yml              # Build, test, migrate, deploy to ACA
 
fluent-platform/
└── deploy/
    └── azure/
        ├── bicep/
        │   ├── main.bicep              # ACA Environment + Prod App
        │   ├── modules/
        │   │   ├── aca-environment.bicep
        │   │   └── aca-app.bicep
        │   └── parameters/
        │       └── prod.bicepparam     # Prod-specific non-secret values
        ├── scripts/
        │   └── deploy-dev.sh           # Dev ACA deploy via Azure CLI
        └── workflows/
            └── deploy-fluent-ai.yml    # Reusable Bicep deploy for prod
```

### 1. `fluent-ai/.github/workflows/deploy.yml`
**Triggers**:

- push to `main` → deploy to `dev`
- workflow_dispatch with environment choice → deploy to `dev` or `prod`

**Jobs**:

Job | Dev | Prod | What it does
--- | --- | --- | ---
build | Yes | Yes | Lint, format, typecheck, test, build Docker image, tag with SHA + env tag, push to GHCR
migrate | Yes | Yes | Check out repo, install uv, set MIGRATIONS_DATABASE_URL from GitHub Secrets, run alembic upgrade head. Fails fast — stops deployment if migration fails.
deploy-dev | Yes | No | Calls fluent-platform/deploy/scripts/deploy-dev.sh to deploy the SHA-tagged image to the dev ACA app via Azure CLI
deploy-prod | No | Yes | Calls the Bicep deployment in bicep to deploy the SHA-tagged image to the prod ACA app

**Why separate dev and prod deployment jobs**: Dev uses a lightweight Azure CLI script; prod uses full Bicep IaC. This matches your preference.

### 2. Dev Deployment (fluent-platform/deploy/scripts/deploy-dev.sh)
A ~30-line bash script that uses the Azure CLI:

```
bash
#!/bin/bash
set -e
 
# Inputs: IMAGE_TAG, AZURE_RESOURCE_GROUP, ACA_APP_NAME, AZURE_SUBSCRIPTION
az containerapp update \
  --name "$ACA_APP_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --subscription "$AZURE_SUBSCRIPTION" \
  --image "ghcr.io/eten-tech-foundation/fluent-ai:${IMAGE_TAG}" \
  --set-env-vars "ENVIRONMENT=development"
```
Dev ACA app is pre-created once (manually or via a one-time Bicep run). After that, every push to main just updates the image tag and env vars.

### 3. Prod Deployment (bicep)
`main.bicep` defines:

- `acaEnvironment`: ACA environment (networking, log analytics)
- `acaApp`: The fluent-ai-prod app
  - `Container`: image from GHCR, CPU/memory, health probes
  - `Scale rules`: min 1, max 3 replicas
  - `Environment variables`: non-secret values (ENVIRONMENT=production, LOG_LEVEL=INFO, etc.)
  - `Secret references`: points to Azure Key Vault for DATABASE_URL, SECRET_KEY, OPENAI_API_KEY, etc.

`prod.bicepparam` contains:

```bicep
param imageTag = 'sha-abc123...'
param environmentName = 'production'
param minReplicas = 1
param maxReplicas = 3
param logLevel = 'INFO'
param keyVaultName = 'fluent-ai-kv-prod'
```

Deployment method: The workflow runs:

```bash
az deployment group create \
  --resource-group $AZURE_RESOURCE_GROUP_PROD \
  --template-file deploy/azure/bicep/main.bicep \
  --parameters deploy/azure/bicep/parameters/prod.bicepparam
```

### 4. Secrets Flow

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  GitHub Secrets │────▶│  GitHub Actions │────▶│  Azure Key Vault│
│  (CI-only)      │     │  (CI pipeline)  │     │  (Runtime)      │
│                 │     │                 │     │                 │
│ AZURE_* creds   │     │ Read secrets    │     │ database-url    │
│ MIGRATIONS_DB_* │     │ for CI jobs     │     │ secret-key      │
│ BOOTSTRAP_DB_*  │     │ (migrations)    │     │ openai-api-key  │
└─────────────────┘     └─────────────────┘     └─────────────────┘
                              │
                              ▼
                        ┌─────────────────┐
                        │  ACA App Config │
                        │  (Bicep/CLI)    │
                        │                 │
                        │  secretRef:     │
                        │    "database-url"│
                        └─────────────────┘
```

No secret values ever touch Git. Key Vault holds runtime secrets. GitHub Secrets holds CI-only credentials.

### 5. Database Migrations
In the CI workflow (both dev and prod):



```yaml
- name: Run Alembic migrations
  env:
    MIGRATIONS_DATABASE_URL: ${{ secrets.MIGRATIONS_DATABASE_URL }}
  run: |
    uv sync --frozen --no-dev
    uv run alembic upgrade head
```
Why this is safe:

- Runs once, from a single CI runner, before any new app code is deployed
- If migration fails, the deploy-* job never starts
- App containers start fast and clean — no bootstrap/migrate on startup


For a brand-new managed DB (first time only):

```bash
BOOTSTRAP_DATABASE_URL="..." uv run python scripts/bootstrap.py
```
This is run manually or via a one-time setup job.

### 6. Environment Variables in ACA
| Var | Value | Source |
|-----|-------|--------|
| ENVIRONMENT | production / development | Bicep param / CLI |
| LOG_LEVEL | INFO | Bicep param / CLI |
| LOG_OUTPUT | stdout | Bicep param / CLI |
| DATABASE_URL | postgresql+asyncpg://... | Key Vault secretRef |
| SECRET_KEY | *** | Key Vault secretRef |
| OPENAI_API_KEY | *** | Key Vault secretRef |
| ANTHROPIC_API_KEY | *** | Key Vault secretRef |
| GOOGLE_AI_API_KEY | *** | Key Vault secretRef |
| GOOGLE_AI_MODEL | gemini-2.5-flash-lite | Bicep param / CLI |
| API_BASE_URL | https://fluent-server-*.azurewebsites.net | Bicep param / CLI |
| API_SERVICE_KEY | *** | Key Vault secretRef |

### 7. Rollback Strategy
If a deployment breaks prod:

- Fast rollback: Re-run the workflow with the previous known-good Git SHA as the image tag
- Bicep rollback: Since the Bicep parameter file commits the image SHA, reverting the parameter file commit and re-deploying restores the previous state
- DB rollback: Alembic `downgrade` can be run manually from CI if needed

### 8. Pilot Rollout (Dev First, No-Risk Cutover to Prod)
fluent-ai has never been deployed anywhere, so this isn't a migration of an existing dependency — it's turning on a dependency that fluent-api has always run without. fluent-api already has the mechanism needed to pilot this safely:

- `FLUENT_AI_URL`/`FLUENT_AI_KEY` being unset (today's state, in every environment) makes `aiIsWired` in `fluent-api/src/lib/features.ts` false, which defaults `EN_FEATURE_REPEATED_WORD_CHECK` and `EN_FEATURE_AI_SUGGESTIONS` to **off** — fluent-web already hides AI-dependent UI wherever AI isn't wired, with zero fluent-api code changes needed.
- **Caveat**: this flag only gates the frontend UI, not the backend request path (`src/lib/features.ts` comment: "does not gate the AI request path"). `ai-tools.service.ts` and `ai-trigger.worker.ts` call `fluent-ai.client.ts` directly regardless of the flag. Before flipping `FLUENT_AI_URL` on anywhere, confirm how `ai-trigger.worker.ts` handles a slow/unreachable fluent-ai (timeout, retry, dead-letter) so a flaky pilot instance can't produce stuck or failed jobs.

Rollout sequence:
1. **Dev pilot**: deploy fluent-ai to the dev ACA app only (§5). Set `FLUENT_AI_URL`/`FLUENT_AI_KEY` (and, if forcing the UI on for QA ahead of the safe default, the `EN_FEATURE_*` flags) in fluent-api's `Development` GitHub Environment secrets. fluent-api's production deployment is untouched — no risk to prod from this step.
2. **Validate**: exercise the AI-dependent routes and `ai-trigger.worker.ts` against the dev ACA app — health probes, migrations, request/response contract, and failure handling under real traffic.
3. **Cutover to prod**: once proven, deploy fluent-ai's prod ACA app (§5), then add `FLUENT_AI_URL`/`FLUENT_AI_KEY`/`EN_FEATURE_*` secrets to fluent-api's `Production` environment. This is an env var/secret change on the fluent-api side only — no fluent-api code deploy required. Reversible by unsetting `FLUENT_AI_URL`, which returns fluent-api to today's AI-less behavior.

### 9. Out of Scope (Deliberate Deferrals)
- **Staging environment**: `deploy/azure/env/staging.env` already exists in this repo as a placeholder. A staging environment that mirrors prod for QA is needed but is **out of scope for this plan** — dev/prod is all that's being built now. Revisit staging as a follow-on once dev/prod is proven out.
- **fluent-api containerization**: also out of scope here, but relevant — this plan's `acaEnvironment` (networking, Log Analytics workspace) is the first ACA Environment in the platform. When fluent-api is later containerized, decide explicitly whether it joins this same ACA Environment or gets its own; that's a cheap decision now and an expensive one to change after fluent-ai has live dependents on the shared environment.

### 10. First-Time Manual Setup Runbook
The following are one-time manual steps (not automated via Bicep/CLI in CI), and should be re-run in this order if the dev ACA app or Key Vault is ever recreated:
1. Create the dev ACA app once (`az containerapp create ...` or a one-off Bicep apply) — subsequent deploys just update the image tag via `deploy-dev.sh`.
2. Create the Key Vault (dev + prod) and populate the runtime secrets listed in §3.
3. Grant the ACA managed identity(ies) `Key Vault Secrets User` access on the vault.
4. Run `BOOTSTRAP_DATABASE_URL="..." uv run python scripts/bootstrap.py` once per environment against the managed Postgres instance.

### 11. Cost Estimate (monthly, low traffic)
| Component | Dev | Prod |
|-----------|-----|------|
| ACA (consumption) | ~$0 (free tier) | ~$5-15 |
| Key Vault | ~$0 (10K ops free) | ~$0 |
| GHCR | Free (public repo) | Free |
| Total | ~$0 | ~$5-15 
