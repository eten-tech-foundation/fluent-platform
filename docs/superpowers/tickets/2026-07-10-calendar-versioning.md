# Adopt Calendar Versioning (CalVer) for Fluent

**Date:** 2026-07-10
**Repos affected:** fluent-api, fluent-web (full scope); fluent-ai (convention now, automation deferred)
**Out of scope:** fluent-mobile (already has its own tag-triggered app-store versioning), fluent-platform (no app version of its own)

## Problem

None of the Fluent repos currently update their project version as changes are released. `package.json`/`pyproject.toml` versions are static placeholders (`fluent-api` is stuck at `1.0.0`, `fluent-web` and `fluent-ai` at `0.1.0`), and there's no way to look at a running PROD deployment and know which release it corresponds to.

## Scheme

Adopt [CalVer](https://calver.org) with the format:

```
YY.MM.SERIAL
```

- `YY` — two-digit year (e.g. `26`)
- `MM` — two-digit month (e.g. `07`)
- `SERIAL` — auto-incrementing counter, **per-repo**, **resets to 1 at the start of each new YY.MM**

Git tags carry a `v` prefix: `v26.07.1`, `v26.07.2`, etc. The `version` field inside each repo's manifest (`package.json` / `pyproject.toml`) matches the tag without the `v` (e.g. `"version": "26.7.1"` — see note in Open Questions about semver field validity).

The serial only increments on an actual **PROD** release — not on every merge to `main`, not on dev deploys. A tag existing is proof that commit reached production; this directly satisfies "PROD deployments should be clearly tagged."

fluent-api and fluent-web version independently. There is no shared/global counter across repos — both can legitimately be at `v26.07.1` at the same time.

## Why automation can't be "open a PR at deploy time"

Bumping the version has to happen right when someone decides to ship to PROD — that's the only moment the next serial is knowable. Requiring a PR at that moment would mean either:
- pre-creating a version-bump PR speculatively before you know if today's the day you deploy, or
- blocking the actual deploy on a second human (PR review) after the real approval already happened.

Both are friction for no safety benefit. The fix is to make the bump a **side effect of the action that already means "ship to prod"**, not a separate change that needs its own review.

## Existing precedent in this org

`fluent-mobile/.github/workflows/eas-build.yml` already does exactly this, in production, today: triggered by a `v*` tag push, it bumps `app.config.ts` on the tagged commit, commits as a bot with `[skip ci]`, force-moves the tag to the new commit, and pushes straight to `main` — with a safety check that refuses to push if the original tagged commit wasn't already the tip of `main`. No PR involved. This ticket reuses that pattern rather than inventing a new one.

## Automation design: fluent-api / fluent-web

Both repos already gate PROD deploys behind a **manual `workflow_dispatch`** on `.github/workflows/post-merge-deploy.yml` (`environment: prod`), separate from the automatic dev deploy on push to `main`. That manual trigger *is* the "I'm ready to release" gesture — so the version bump belongs inside that same job, not behind a separate tag-push step.

**New job `bump-version`** (runs only when `github.event.inputs.environment == 'prod'`, before `build` / `migrate-prod` / `deploy-prod`):

1. Checkout `main` with a bot token that can push directly (same mechanism `fluent-mobile` uses).
2. Compute the next tag:
   - List tags matching `v{YY}.{MM}.*`
   - Next serial = max existing serial + 1, or `1` if none exist for this month
3. Bump the `version` field in `package.json` to match.
4. Commit as the bot: `chore(release): vYY.MM.N [skip ci]`.
5. Push the commit to `main`.
6. Create and push the tag `vYY.MM.N` pointing at that commit.
7. (Nice-to-have) Cut a GitHub Release from the tag.

`build`, `migrate-prod`, and `deploy-prod` now depend on `bump-version` and build from the bumped commit, so the version actually deployed matches the tag.

### Idempotency / retry guard

If a prod `workflow_dispatch` run is retried (e.g. `deploy-prod` failed and someone re-runs the workflow) without any new commits since the last bump, it must **not** allocate a second serial for the same release. Guard: before bumping, check whether `HEAD` on `main` is already tagged with a `v{YY}.{MM}.*` tag pointing at it — if so, skip the bump and reuse the existing tag/version rather than computing a new serial.

### Visibility

Surface the running version somewhere observable post-deploy — e.g. fluent-api's health-check endpoint returns `version` read from `package.json`, and fluent-web exposes it in a footer or a debug route. Makes "what's actually in prod right now" a one-request answer instead of a git-archaeology exercise.

## fluent-ai: convention now, automation later

fluent-ai currently has **no GitHub Actions workflows at all** — no PR checks, no build, no deploy pipeline. There's nothing to hook a PROD-deploy version bump into yet. Per `fluent-ai/docs/superpowers/specs/2026-04-17-gitops-roadmap.md`, Phase 2 of that repo's own CI/CD rollout explicitly lists "tagging strategy" as an open decision.

For this ticket:
- Adopt the same `YY.MM.SERIAL` convention for `pyproject.toml`'s `version` field.
- Do **not** build bump automation for fluent-ai now — there's no deploy trigger to attach it to.
- Cross-reference this scheme as the answer to the gitops roadmap's open "tagging strategy" question, so whoever implements fluent-ai's Phase 1/2 CI wires the same `bump-version` pattern into its future prod deploy job instead of inventing a different one.

## Tasks

1. **fluent-api**: add `bump-version` job to `post-merge-deploy.yml`, gated on prod dispatch; wire `build`/`migrate-prod`/`deploy-prod` to depend on it and check out the bumped commit.
2. **fluent-api**: add retry/idempotency guard (skip bump if `HEAD` already tagged this release).
3. **fluent-api**: expose current version on a health/debug endpoint.
4. **fluent-web**: same as 1–3, adapted to `post-merge-deploy.yml`'s static-web-app deploy job.
5. **fluent-ai**: bump `pyproject.toml` to `26.7.0` (or similar) as a one-time convention-adoption commit; no CI automation yet.
6. **fluent-platform** (or wherever cross-repo docs live): document the scheme and the `bump-version` pattern once, referenced by all repos, so future services (fluent-ai included) implement it the same way instead of reinventing it.
7. Update `fluent-ai/docs/superpowers/specs/2026-04-17-gitops-roadmap.md` to point at this ticket for the Phase 2 tagging-strategy decision.

## Testing / verification strategy

The risky part isn't whether the app deploys correctly — it's the git mechanics (a bot pushing straight to `main`, bypassing branch protection, creating tags). That has to be validated without ever hitting the real Azure prod resource.

1. **Add a `dry_run` input and run the real workflow for real.** Add a `workflow_dispatch` boolean input alongside `environment`. When true, `bump-version` still runs against the real repo — real bot token, real branch protection, real tag push — but `deploy-prod` (the actual `azure/webapps-deploy` step) is skipped. This is the only way to prove the bot can actually push to `main` and move a tag under the real branch-protection rules, without touching the Azure resource. Delete the test tag/commit afterward, or let it land as a genuine throwaway version once, since the mechanism only needs proving one time.
2. **Unit-test the version logic in isolation.** Pull the "compute next serial from existing tags + current YY/MM" logic out of inline workflow YAML `run:` steps into a small script (`scripts/next-version.sh` or `.mjs`) that takes a tag list and a date as input and prints the next version. Test it with normal test tooling (month rollover, no tags yet this month, retry/idempotency check) with zero GitHub Actions involved. Covers the part most likely to have an off-by-one bug.
3. **Don't re-derive the bot-permission setup from scratch — copy it.** `fluent-mobile`'s `eas-build.yml` already does the exact bypass-branch-protection push in production today. Rather than experimenting against fluent-api/fluent-web's real `main` from a blank slate, mirror its token/permissions setup directly. If it works there, the identical setup works here — de-risks the scariest unknown before running step 1 above.


## Open questions

- **Manifest version field validity**: `package.json`'s `version` field is conventionally semver (`MAJOR.MINOR.PATCH`), and `26.7.1` parses as valid semver even though it means something different here (year.month.serial, not major.minor.patch). Confirm no tooling in the build/deploy pipeline (npm, dependency resolution, etc.) makes semver-range assumptions about this field that CalVer would violate. If it does, the manifest version may need to stay a literal string decoupled from anything semver-sensitive. - **Answer**: Just make sure that CalVer works as expected.
- **Bot push permissions**: confirm the same bot-push-to-`main`-bypassing-branch-protection mechanism `fluent-mobile` uses is (a) already available as an org-level credential/pattern fluent-api and fluent-web can reuse, or (b) needs its own token/permission setup. - **Answer**: Just make sure that the bot works as expected.
- **Does a dev-environment deploy ever need a version bump too**, or is "only PROD gets a CalVer tag" sufficient forever? Current design assumes yes (dev deploys stay unversioned/untagged). - **Answer**: No, DEV does not need a version bump.

## Implementation review notes (2026-07-30)

The shipped design diverged from this ticket's original `bump-version`-inside-`workflow_dispatch` proposal: fluent-api#245/fluent-web#379/fluent-ai#55 (proposal PRs) and fluent-api#247/fluent-web#386/fluent-ai#56 (implementation PRs) instead landed on **tag-triggered prod deploys** — a `cut-release.yml` workflow computes and pushes `vYY.MM.N`, and `post-merge-deploy.yml`'s prod path triggers on `push: tags: 'v*.*.*'` instead of manual dispatch. This also solves a QA-blocking problem the original ticket didn't address: PRs merging to `main` mid-QA-cycle no longer leak into a release, since the tag is an immutable snapshot that doesn't move. Tracking issue: fluent-api#221 (sub-issues fluent-api#222, fluent-web#350, fluent-ai#38).

Review findings against the three implementation PRs, worked through before posting as feedback:

1. **Tag-glob validation gap — expanded below.**
2. **fluent-api#247's unrelated `src/index.ts` worker-registration change — acceptable**, not a CalVer concern, no action needed.
3. **fluent-api `/health` version dry-run — expanded below.**
4. **Dropped hotfix/rollback runbooks — addressed via a `docs/runbooks/` proposal below.**
5. **Tag immutability / repo tag protection — captured as a note below.**

### #1 — Tag format validation

**The concrete gap:** `tags: ['v*.*.*']` is a ref-glob, not a regex — `*` matches any characters including `.`, so it isn't scoped to digits or to exactly three segments. All of these would match and trigger a real prod deploy (real Azure deploy, real `migrate-prod` against the production DB) exactly as if they were a legitimate release:

- `v1.0.0-rc.1` — a conventional pre-release tag someone pushes out of habit from another project's conventions
- `v26.7.1` — missing the enforced leading zero on month, still 3 dot-segments
- `v26.07.1.hotfix` — 4 segments, still matches because `*` doesn't anchor segment count
- any hand-pushed typo, e.g. `v26.07.l` (lowercase L instead of `1`)

Today the only thing standing between "someone pushes an unrelated tag" and "prod gets deployed and migrated" is that `cut-release.yml` happens to always produce well-formed tags — there's no enforcement on the receiving end (`post-merge-deploy.yml`), and #5's tag-creation ruleset (even once implemented) is a permission boundary, not a format check, so it doesn't fully substitute for this.

**Proposed fix — fail-fast validation as the first step of the job, not a separate job.** Putting it inline avoids the "downstream job depends on a job that gets skipped on the dev/branch path" gotcha entirely, and running it before `actions/checkout` means an invalid tag costs a few seconds of runner time instead of a full checkout + install.

For **fluent-api**, first step of the existing `build` job in `post-merge-deploy.yml`:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Validate CalVer tag format
        if: github.ref_type == 'tag'
        run: |
          TAG="${GITHUB_REF_NAME}"
          if [[ ! "$TAG" =~ ^v[0-9]{2}\.[0-9]{2}\.[1-9][0-9]*$ ]]; then
            echo "::error::Tag '$TAG' does not match required CalVer format vYY.MM.SERIAL (e.g. v26.07.1)"
            exit 1
          fi
          echo "Tag '$TAG' is valid."

      - name: Checkout repository
        uses: actions/checkout@v6
      # ...unchanged from here
```

Because `migrate-prod`/`deploy-prod` already `needs: [build]` (and `migrate-dev`/`deploy-dev` do too, but the validation step is a no-op there since `ref_type != 'tag'`), this single step gates the entire prod path without touching the job dependency graph at all.

For **fluent-web**, `deploy-prod` is already its own job gated `if: github.ref_type == 'tag'`, so the step doesn't even need its own `if` — add it as the first step:

```yaml
deploy-prod:
  runs-on: ubuntu-latest
  if: github.ref_type == 'tag'
  environment: production
  steps:
    - name: Validate CalVer tag format
      run: |
        TAG="${GITHUB_REF_NAME}"
        if [[ ! "$TAG" =~ ^v[0-9]{2}\.[0-9]{2}\.[1-9][0-9]*$ ]]; then
          echo "::error::Tag '$TAG' does not match required CalVer format vYY.MM.SERIAL (e.g. v26.07.1)"
          exit 1
        fi

    - uses: actions/checkout@v7.0.0
    # ...unchanged from here
```

**Belt-and-suspenders: validate at creation time too.** Add the identical regex check in `cut-release.yml` right after the "Compute CalVer tag" step and before "Tag and push" — cheap, and it catches a bug in the computation logic itself before a bad tag is ever pushed, rather than relying solely on the deploy-side check to catch it after the fact.

**Optional tightening:** the regex above accepts any `MM` in `00`–`99`; swap in `(0[1-9]|1[0-2])` for the month group if stricter validation (reject `v26.13.1`, `v26.00.1`) is wanted. Not required to close the actual vulnerability — the 3-dot-segment glob is the real hole — but cheap to add at the same time.

Same pattern applies to fluent-ai once it gets a tag-triggered prod deploy path (there is none yet — see the fluent-ai section above).

### #3 — Dry-run design for verifying `/health` reflects the deployed tag

The claim in `docs/calver-versioning.md` ("fluent-api: version exposed via `/health`") is *true today* only because `health.route.ts` reads `process.env.npm_package_version`, and npm happens to populate that when the process is launched via `npm start` — which is Azure App Service's default Node startup command here, since no `web.config`/custom startup command overrides it. Nothing in #247 actually proves this chain end-to-end (`vYY.MM.N` tag → `jq` patch of `package.json` → `npm start` → `npm_package_version` → `/health` JSON). Given the design is now tag-triggered rather than `workflow_dispatch`-gated, the dry run needs to be decoupled from the real deploy trigger entirely, not conditioned on a `dry_run` input to it:

- **Add a standalone smoke-test job** (either a step in `pre-merge.yml`, or a small dedicated workflow) that runs entirely inside the CI runner with no Azure/cloud dependency:
  1. Run the existing "Set version from tag" `jq` step against a fixture tag, e.g. `v00.00.99`.
  2. `npm run build`.
  3. `npm start &` in the background, wait for the port to come up.
  4. `curl localhost:<port>/health` and assert the JSON `version` field equals `00.00.99`.
  5. Kill the server.
- Run this on every PR that touches `package.json`'s version-stamping step, `health.route.ts`, or the workflow files — not just at release time. This is what actually proves the wiring works, independent of whether a real release is being cut.
- **fluent-web is simpler to verify** — its version is a build-time `VITE_APP_VERSION` string baked directly into the JS bundle (`vite.config.ts`'s `define`), so the equivalent check is just `pnpm build` with a fixture `VITE_APP_VERSION`, then `grep` the built `dist/assets/*.js` for the fixture string. No runtime/server component needed at all.
- Treat an actual Azure deployment slot dry run (deploy the tag to a staging slot, curl its own URL, then swap) as a stretch goal — it would catch Azure-runtime-specific surprises the local smoke test can't (e.g., if Azure's actual startup command ever changes), but there's no staging slot infrastructure today, so it's a bigger lift than this ticket needs to unblock on.

### #4 — Proposal: `<repo>/docs/runbooks/`

The original proposal PRs (`versioning-calver-workflows.md`) had detailed hotfix/rollback scenario walkthroughs that didn't make it into the shipped `docs/calver-versioning.md` in any of the three repos — only the happy path (cut-release → tag → deploy) is documented now. Recommend adding a `docs/runbooks/` directory (per repo, so it can reference repo-specific commands) holding one markdown file per operational scenario. Suggested contents, adapted from the original proposal to the *actual* tag-triggered mechanism that shipped:

- **`docs/runbooks/deloyment/prod-release-cut.md`** — happy path: trigger `cut-release.yml` from `main`, confirm the tag/GitHub Release were created, watch the triggered prod deploy, confirm `/health` (or the web footer) reflects the new version.
- **`docs/runbooks/deployment/prod-hotfix-during-qa.md`** — bug found in a tag that's mid-QA: fix lands on `main` via a normal PR, gets cherry-picked onto a short-lived branch cut from the QA'd tag (not from `main` HEAD, which may have unrelated merges since), a new tag is cut from that branch. Example:
  ```bash
  git fetch --tags
  git checkout -b hotfix/26.07.4 v26.07.3
  git cherry-pick <fix-commit-sha>
  git push -u origin hotfix/26.07.4
  # cut-release.yml only runs against main today — for a hotfix branch,
  # either extend it to accept a source ref input, or tag manually here
  # using the same vYY.MM.N contract it enforces.
  ```
- **`docs/runbooks/deployment/prod-emergency-hotfix.md`** — prod is broken, no pending QA cycle: branch from the tag currently live in prod (not `main`), fix, PR to `main` for the record, tag from the hotfix branch tip directly.
- **`docs/runbooks/deployment/prod-rollback.md`** — CodeRabbit's original point still applies: don't just re-run `post-merge-deploy.yml` against a prior tag, since that re-runs `migrate-prod` unconditionally. Rollback needs a deploy-only path (or a documented manual skip of the migration job) plus an explicit call-out to check migration/artifact compatibility before rolling back a schema-touching release.

Each file should be short and command-driven (like the original proposal's scenario walkthroughs), not prose — these get read under pressure during an incident or a QA cycle, not studied in advance.

### #5 — Tag protection note

Neither implementation configures repo-level protection for `v*` tags — tags are created as lightweight (not annotated/signed), and nothing stops a force-push or deletion of an existing release tag. This is a **GitHub repo Settings change, not a code change**, so it won't appear in any PR diff and is easy to lose track of. Note for follow-up, per repo (fluent-api, fluent-web, and fluent-ai once it gets CI):

- Repo → **Settings → Rules → Rulesets → New ruleset → New tag ruleset** (prefer Rulesets over the older classic "Tag protection rules" — Rulesets expose "block force pushes" and "restrict deletions" as separate toggles, classic tag protection only clearly covers create/delete).
- **Target**: include by pattern `v*` (or `v*.*.*` to match the CalVer format exactly).
- **Enforcement status**: Active.
- **Rules to enable**:
  - Restrict deletions (a shipped release tag can never be deleted).
  - Block force pushes (a tag can never be silently moved to point at a different commit).
  - Restrict creations, scoped so only the release bot/service account used by `cut-release.yml` can create matching tags — prevents anyone else from hand-creating a tag that bypasses the `SERIAL` computation and collides with a future automated one.
- Leave the bypass list empty, or scoped to repo admins only, for genuine immutability.
