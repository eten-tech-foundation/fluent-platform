# Introduce a QA environment between tag-cut and prod deploy

**Date:** 2026-08-05
**Repos affected:** fluent-api, fluent-web
**Parent:** [2026-07-10-calendar-versioning.md](2026-07-10-calendar-versioning.md), tracking issue fluent-api#221
**Priority:** Blocking further release-tooling work (the commit-browser script for `cut-release.yml` is deferred until this lands, so the script targets the final pipeline shape)

## Goal

Currently, pushing a `vYY.MM.SERIAL` tag deploys straight to prod. Insert a QA stage in between: tag push → deploy to QA → **manual sign-off** → deploy the same release to prod. No new tag gets cut for the prod promotion — QA and prod both trace back to the one release tag.

## Approval mechanism: GitHub Environment protection, not custom tooling

GitHub Environments support a "required reviewers" protection rule — a job referencing a protected environment pauses and waits for an approval click in the Actions UI before running. This is the exact primitive for "QA checks it off, then prod deploys," and it's already the mechanism these workflows use for `Development`/`Production` environments today, just without a reviewers requirement configured yet.

Recommend a **dedicated `Production-Approval` environment used only as the gate**, rather than adding reviewers directly to the `Production` environment:

```yaml
approve-prod:
  runs-on: ubuntu-latest
  needs: deploy-qa
  if: github.ref_type == 'tag'
  environment:
    name: Production-Approval   # reviewers configured on THIS environment only
  steps:
    - run: echo "QA sign-off received — proceeding to production deploy."
```

Downstream prod jobs depend on `approve-prod` instead of running as soon as `build`/`deploy-qa` finish. This keeps the approval gate as a single, explicit, zero-secrets job — it doesn't need any Production credentials, so reviewers are only being granted "permission to unblock," not incidental access to prod secrets. Configure required reviewers on `Production-Approval` via **Settings → Environments → Production-Approval → Required reviewers**.

## Infra prerequisites (blocking — none of this exists yet)

- QA Azure Web App for fluent-api (e.g. `fluent-server-qa`) + its publish profile as a new repo secret (`AZUREAPPSERVICE_PUBLISHPROFILE_QA`).
- QA Azure Static Web App for fluent-web + its deployment token as a new repo secret (`AZURE_STATIC_WEB_APPS_API_TOKEN_QA`).
- **Dedicated QA database** (`DATABASE_URL_QA`) — isolated from dev, so QA state stays clean and prod-like for meaningful sign-off, and in-progress dev migrations can't contaminate what QA is verifying.
- **QA gets its own fluent-api instance**, not a shared backend with prod — this was a deliberate choice for real full-stack QA isolation (see "fluent-web build strategy" below for why this matters). That means QA-scoped versions of every backend-pointing secret fluent-web currently has for prod: `VITE_API_URL_QA`, and QA equivalents of `VITE_AQUIFER_API_URL/KEY`, `VITE_YOUVERSION_API_URL/KEY`, `VITE_BETTER_AUTH_URL`, `VITE_APP_INSIGHTS_*` if QA should report to a separate Insights resource.
- A `Production-Approval` GitHub Environment (see above) with required reviewers configured.

## fluent-api: build once, promote the same artifact

fluent-api's build artifact is environment-agnostic — config is read from `process.env` at runtime via Azure App Service settings, not baked in at build time. So the existing `build` job's single artifact can be deployed to QA and then prod unchanged; only `migrate-qa`/`deploy-qa` are new jobs, inserted between `build` and the (now gated) prod path.

```yaml
migrate-qa:
  runs-on: ubuntu-latest
  needs: build
  if: github.ref_type == 'tag'
  environment: QA
  steps:
    - name: Checkout repository
      uses: actions/checkout@v6
    - name: Set up Node.js version
      uses: actions/setup-node@v6.4.0
      with: { node-version: 24.14.0, cache: npm }
    - name: Install dependencies
      run: npm install --legacy-peer-deps
      env: { CXXFLAGS: '-std=c++20' }
    - name: Run database migrations
      env: { DATABASE_URL: ${{ secrets.DATABASE_URL_QA }} }
      run: npm run db:migrate

deploy-qa:
  runs-on: ubuntu-latest
  needs: [build, migrate-qa]
  if: github.ref_type == 'tag'
  environment:
    name: QA
    url: ${{ steps.deploy-to-webapp.outputs.webapp-url }}
  steps:
    - name: Download artifact from build job
      uses: actions/download-artifact@v8
      with: { name: node-app, path: deployment/ }
    - name: Deploy to Azure Web App
      id: deploy-to-webapp
      uses: azure/webapps-deploy@v3.0.8
      with:
        app-name: fluent-server-qa
        publish-profile: ${{ secrets.AZUREAPPSERVICE_PUBLISHPROFILE_QA }}
        package: deployment/
        clean: true
    - name: Verify deployment
      run: |
        sleep 30
        for i in $(seq 1 10); do
          response=$(curl -s -o /dev/null -w "%{http_code}" ${{ steps.deploy-to-webapp.outputs.webapp-url }})
          if [ "$response" -ge 200 ] && [ "$response" -lt 400 ]; then
            echo "QA deployment successful (HTTP $response)"; exit 0
          fi
          echo "App not ready yet (HTTP $response). Retrying in 10 seconds..."; sleep 10
        done
        echo "QA deployment verification failed"; exit 1

approve-prod:
  runs-on: ubuntu-latest
  needs: deploy-qa
  if: github.ref_type == 'tag'
  environment:
    name: Production-Approval
  steps:
    - run: echo "QA sign-off received — proceeding to production deploy."

migrate-prod:
  # needs changes from `needs: build` to:
  needs: [build, approve-prod]
  # rest unchanged

deploy-prod:
  # unchanged — already needs: [build, migrate-prod], which now transitively waits on approval
```

## fluent-web: independent rebuild per environment, not literal artifact reuse

Vite bakes every `VITE_*` variable directly into the static JS bundle at build time (that's how `VITE_APP_VERSION` already works today). Since QA gets its **own** fluent-api instance rather than sharing prod's, `VITE_API_URL` (and the Aquifer/YouVersion/App Insights vars) must differ between the QA build and the prod build — so they cannot be the literal same artifact, even though both are built from the identical tagged commit. This is a deliberate trade-off from choosing real QA isolation over simpler artifact promotion.

Add a `deploy-qa` job structurally identical to `deploy-prod`, pointed at QA's Static Web App and QA's backend config, with the same approval gate in between:

```yaml
deploy-qa:
  runs-on: ubuntu-latest
  if: github.ref_type == 'tag'
  environment: qa
  steps:
    - uses: actions/checkout@v7.0.0
      with: { submodules: true }
    - uses: pnpm/action-setup@v6.0.9
      with: { version: 10.33.0 }
    - uses: actions/setup-node@v6
      with: { node-version: '24.13.0' }
    - name: Validate CalVer tag format
      run: |
        TAG="${GITHUB_REF_NAME}"
        if [[ ! "$TAG" =~ ^v[0-9]{2}\.(0[1-9]|1[0-2])\.[1-9][0-9]*$ ]]; then
          echo "::error::Tag '$TAG' does not match required CalVer format vYY.MM.SERIAL"
          exit 1
        fi
    - name: Deploy to Azure
      uses: Azure/static-web-apps-deploy@v1
      with:
        azure_static_web_apps_api_token: ${{ secrets.AZURE_STATIC_WEB_APPS_API_TOKEN_QA }}
        repo_token: ${{ secrets.GITHUB_TOKEN }}
        action: upload
        app_location: /
        output_location: dist
        app_build_command: npm install -g pnpm@10.33.0 && pnpm install --frozen-lockfile && pnpm build
      env:
        VITE_API_URL: ${{ secrets.VITE_API_URL_QA }}
        VITE_ENVIRONMENT: qa
        VITE_APP_VERSION: ${{ github.ref_name }}
        # ...QA-scoped equivalents of the other VITE_* secrets used in deploy-prod

approve-prod:
  runs-on: ubuntu-latest
  needs: deploy-qa
  if: github.ref_type == 'tag'
  environment:
    name: Production-Approval
  steps:
    - run: echo "QA sign-off received — proceeding to production deploy."

deploy-prod:
  needs: approve-prod   # new — previously gated only by ref_type == 'tag'
  # rest unchanged
```

## Follow-on updates once this lands

- `docs/runbooks/deployment/prod-release-cut.md` needs a new step describing the QA-approval wait between tag push and prod deploy.
- `docs/runbooks/deployment/prod-rollback.md` — confirm re-running the workflow against a prior tag doesn't unexpectedly re-trigger a fresh QA deploy/approval wait if that's not desired for a rollback (may be fine — worth confirming intent, not assuming).
- The `cut-release.yml` commit-browser script (deferred until this ticket lands) doesn't change — it only affects which commit gets tagged, not what the tag triggers downstream.
