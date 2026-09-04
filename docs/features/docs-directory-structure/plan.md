# Docs Directory Structure Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate `docs/` in fluent-ai, fluent-api, fluent-mobile, and fluent-web to the feature-grouped structure defined in the spec, with history preserved and no broken links.

**Architecture:** Per-repo, mechanical `git mv` of already-categorized docs (old `proposals/`, `superpowers/{plans,specs,reference}/`, `design/` folders) into `docs/features/<slug>/`, plus a small number of judgment calls for loose root-level docs and one drifted-slug cluster in fluent-api. Each repo gets a `docs/README.md` describing the convention. `runbooks/` and `guides/` are untouched except two mobile/ai reclassifications called out explicitly below.

**Tech Stack:** git (mv, log for history/dates), markdown link grep.

**Spec:** `docs/features/docs-directory-structure/design.md` (this repo, fluent-platform)

## Global Constraints

- Every move uses `git mv` (or `git mv` + manual edit for renames), never delete+recreate — history must follow the file.
- No `superpowers/` directory survives migration in any repo.
- Feature folders use fixed stage filenames (`proposal.md`, `design.md`, `plan.md`) only when a file maps 1:1 onto that stage; otherwise keep the original descriptive filename inside the feature folder rather than force a bad fit.
- After each repo's moves, grep the whole `docs/` tree for markdown relative links (`](./` and `](../` and bare `](docs/`) that reference moved paths, and fix them.
- Each repo's migration is one task, ending in one commit on that repo's current branch (do not create new branches — each repo is already on its own working branch).
- fluent-platform is explicitly out of scope for this plan (deferred per spec).

---

### Task 1: fluent-ai

**Files:**
- Move: `docs/superpowers/plans/2026-04-22-standardize-fastapi-structure.md` → `docs/features/fastapi-structure-standardization/plan.md`
- Move: `docs/superpowers/plans/2026-07-06-ai-suggestions-review-fixes.md` → `docs/features/ai-suggestions/2026-07-06-plan-review-fixes.md`
- Move: `docs/superpowers/plans/2026-07-07-suggestions-followup-review-fixes.md` → `docs/features/ai-suggestions/2026-07-07-plan-followup-review-fixes.md`
- Move: `docs/superpowers/plans/2026-08-06-cicd-pipeline-from-zero.md` → `docs/features/cicd-pipeline/plan.md`
- Move: `docs/superpowers/specs/2026-04-17-gitops-roadmap.md` → `docs/features/gitops-roadmap/design.md`
- Move: `docs/superpowers/specs/2026-07-14-app-service-deployment-design.md` → `docs/features/app-service-deployment/design.md`
- Move: `docs/http-decoupling-transition.md` → `docs/features/http-decoupling-transition/plan.md`
- Move: `docs/guides/api-key-runbook.md` → `docs/guides/api-keys.md`
- Leave in place: `docs/api-data-dependencies.md`, `docs/architecture.md`, `docs/calver-versioning.md` (repo-wide reference), `docs/guides/dependabot-workflow.md`, all of `docs/runbooks/deployment/`
- Create: `docs/README.md`

**Interfaces:** N/A (docs-only)

- [ ] **Step 1: Perform the moves**

```bash
cd /Users/kasey/code/github.com/eten-tech-foundation/fluent-ai
mkdir -p docs/features/fastapi-structure-standardization \
         docs/features/ai-suggestions \
         docs/features/cicd-pipeline \
         docs/features/gitops-roadmap \
         docs/features/app-service-deployment \
         docs/features/http-decoupling-transition

git mv docs/superpowers/plans/2026-04-22-standardize-fastapi-structure.md \
       docs/features/fastapi-structure-standardization/plan.md
git mv docs/superpowers/plans/2026-07-06-ai-suggestions-review-fixes.md \
       docs/features/ai-suggestions/2026-07-06-plan-review-fixes.md
git mv docs/superpowers/plans/2026-07-07-suggestions-followup-review-fixes.md \
       docs/features/ai-suggestions/2026-07-07-plan-followup-review-fixes.md
git mv docs/superpowers/plans/2026-08-06-cicd-pipeline-from-zero.md \
       docs/features/cicd-pipeline/plan.md
git mv docs/superpowers/specs/2026-04-17-gitops-roadmap.md \
       docs/features/gitops-roadmap/design.md
git mv docs/superpowers/specs/2026-07-14-app-service-deployment-design.md \
       docs/features/app-service-deployment/design.md
git mv docs/http-decoupling-transition.md \
       docs/features/http-decoupling-transition/plan.md
git mv docs/guides/api-key-runbook.md docs/guides/api-keys.md

# superpowers/ should now be empty of files; remove leftover empty dirs
find docs/superpowers -type d -empty -delete
```

- [ ] **Step 2: Verify no `superpowers/` directory remains**

Run: `test ! -d docs/superpowers && echo OK`
Expected: `OK`

- [ ] **Step 3: Grep for and fix broken relative links**

```bash
grep -rn '](\./\|](\.\./\|](docs/' docs/ | grep -v '\.png)'
```
For each hit whose target path was moved above, update the link to the new path.

- [ ] **Step 4: Write `docs/README.md`**

```markdown
# Docs directory structure

This repo follows the Fluent-wide docs convention. See
[the spec](https://github.com/eten-tech-foundation/fluent-platform/blob/main/docs/features/docs-directory-structure/design.md)
in fluent-platform for the full rationale.

- `features/<slug>/` — everything about one feature or initiative:
  `proposal.md`, `design.md`, `plan.md`, `tickets/`. Only the stages that
  exist are present.
- `runbooks/` — operational procedures (deploys, rollbacks, hotfixes).
- `guides/` — process/how-to docs not tied to one feature.
- `tasks/` — standalone dated work items with no parent feature.
- Loose files at the root of `docs/` — repo-wide reference docs
  (architecture, versioning scheme, etc.).
```

- [ ] **Step 5: Review the diff and commit**

```bash
git status
git add -A docs
git commit -m "docs: migrate to feature-grouped docs structure"
```

---

### Task 2: fluent-mobile

**Files:**
- Move: `docs/design/record-tab/` (whole directory, including `README.md` and all `.png` files) → `docs/features/record-tab/design/`
- Move: `docs/AGENT_ONBOARDING.md` → `docs/guides/AGENT_ONBOARDING.md`
- Move: `docs/ci.md` → `docs/guides/ci.md`
- Move: `docs/issue-tracking.md` → `docs/guides/issue-tracking.md`
- Leave in place: everything already under `docs/guides/`
- Create: `docs/README.md`

**Interfaces:** N/A (docs-only)

- [ ] **Step 1: Perform the moves**

```bash
cd /Users/kasey/code/github.com/eten-tech-foundation/fluent-mobile
mkdir -p docs/features/record-tab
git mv docs/design/record-tab docs/features/record-tab/design
find docs/design -type d -empty -delete

git mv docs/AGENT_ONBOARDING.md docs/guides/AGENT_ONBOARDING.md
git mv docs/ci.md docs/guides/ci.md
git mv docs/issue-tracking.md docs/guides/issue-tracking.md
```

- [ ] **Step 2: Verify `docs/design/` no longer exists**

Run: `test ! -d docs/design && echo OK`
Expected: `OK`

- [ ] **Step 3: Grep for and fix broken relative links**

```bash
grep -rln '](\./\|](\.\./\|](docs/' docs/ CLAUDE.md 2>/dev/null
```
`docs/features/record-tab/design/README.md` is the most likely file to reference
the images by relative path — those paths (`./01-idle-ready.png`, etc.) are
unaffected since the whole directory moved together. Check `CLAUDE.md` and any
other repo doc that links to `docs/AGENT_ONBOARDING.md`, `docs/ci.md`,
`docs/issue-tracking.md`, or `docs/design/...` by path, and update them.

- [ ] **Step 4: Write `docs/README.md`**

```markdown
# Docs directory structure

This repo follows the Fluent-wide docs convention. See
[the spec](https://github.com/eten-tech-foundation/fluent-platform/blob/main/docs/features/docs-directory-structure/design.md)
in fluent-platform for the full rationale.

- `features/<slug>/` — everything about one feature or initiative:
  `proposal.md`, `design.md`, `plan.md`, `tickets/`, `design/` (mockups).
  Only the stages that exist are present.
- `guides/` — process/how-to docs not tied to one feature (includes
  onboarding, CI, and issue-tracking docs).
- `tasks/` — standalone dated work items with no parent feature.
- Loose files at the root of `docs/` — repo-wide reference docs.
```

- [ ] **Step 5: Review the diff and commit**

```bash
git status
git add -A docs
git commit -m "docs: migrate to feature-grouped docs structure"
```

---

### Task 3: fluent-web

**Files:**
- Move: `docs/proposals/lynx-client-usfm-poc/` → `docs/features/lynx-client-usfm-poc/` (keep internal filenames: `design.md`, `lynx-fluent-assessment.md`)
- Move: `docs/proposals/repeated-word-check/` → `docs/features/repeated-word-check/` (keep internal filenames)
- Move: `docs/proposals/rte-poc/` → `docs/features/rte-poc/` (keep internal filenames: `design.md`)
- Move: `docs/proposals/source-tts/` → `docs/features/source-tts/` (keep internal filenames)
- Move: `docs/superpowers/plans/2026-08-06-qa-environment-and-release-tooling.md` → `docs/features/qa-environment-and-release-tooling/plan.md`
- Leave in place: `docs/containerization.md`, `docs/environment-config.md`, all of `docs/runbooks/deployment/`
- Create: `docs/README.md`

**Interfaces:** N/A (docs-only)

- [ ] **Step 1: Perform the moves**

```bash
cd /Users/kasey/code/github.com/eten-tech-foundation/fluent-web
mkdir -p docs/features docs/features/qa-environment-and-release-tooling

git mv docs/proposals/lynx-client-usfm-poc docs/features/lynx-client-usfm-poc
git mv docs/proposals/repeated-word-check docs/features/repeated-word-check
git mv docs/proposals/rte-poc docs/features/rte-poc
git mv docs/proposals/source-tts docs/features/source-tts
git mv docs/superpowers/plans/2026-08-06-qa-environment-and-release-tooling.md \
       docs/features/qa-environment-and-release-tooling/plan.md

find docs/proposals -type d -empty -delete
find docs/superpowers -type d -empty -delete
```

- [ ] **Step 2: Verify `docs/proposals/` and `docs/superpowers/` no longer exist**

Run: `test ! -d docs/proposals -a ! -d docs/superpowers && echo OK`
Expected: `OK`

- [ ] **Step 3: Grep for and fix broken relative links**

```bash
grep -rn '](\./\|](\.\./\|](docs/proposals\|](docs/superpowers' docs/ | grep -v '\.png)'
```
Fix any hit pointing at an old `proposals/` or `superpowers/` path.

- [ ] **Step 4: Write `docs/README.md`**

```markdown
# Docs directory structure

This repo follows the Fluent-wide docs convention. See
[the spec](https://github.com/eten-tech-foundation/fluent-platform/blob/main/docs/features/docs-directory-structure/design.md)
in fluent-platform for the full rationale.

- `features/<slug>/` — everything about one feature or initiative:
  `proposal.md`, `design.md`, `plan.md`, `tickets/`. Only the stages that
  exist are present; some feature folders here predate the fixed-name
  convention and keep their original descriptive filenames.
- `runbooks/` — operational procedures (deploys, rollbacks, hotfixes).
- `tasks/` — standalone dated work items with no parent feature.
- Loose files at the root of `docs/` — repo-wide reference docs.
```

- [ ] **Step 5: Review the diff and commit**

```bash
git status
git add -A docs
git commit -m "docs: migrate to feature-grouped docs structure"
```

---

### Task 4: fluent-api — mechanical moves

**Files:**
- Move: `docs/proposals/feature-flags/` → `docs/features/feature-flags/` (keep filenames)
- Move: `docs/proposals/language-imports/2026-08-05-ethnologue-language-import-design.md` → `docs/features/ethnologue-language-import/design.md`
- Move: `docs/proposals/language-imports/2026-08-05-ethnologue-language-import-plan.md` → `docs/features/ethnologue-language-import/plan.md`
- Move: `docs/proposals/milestones/workflow_project-hierarchy.md` → `docs/features/milestones/proposal.md`
- Move: `docs/proposals/milestones/workflow_project-hierarchy_review.md` → `docs/features/milestones/review.md`
- Move: `docs/proposals/repeated-word-check/` → `docs/features/repeated-word-check/` (keep filenames)
- Move: `docs/proposals/security-and-export-hardening/` → `docs/features/security-and-export-hardening/` (keep filenames)
- Move: `docs/superpowers/plans/2026-05-13-betterauth-scripts-and-seeds.md` → `docs/features/betterauth-scripts-and-seeds/plan.md`
- Move: `docs/superpowers/specs/2026-06-02-account-self-management-placeholder.md` → `docs/features/account-self-management/design.md`
- Move: `docs/ai-suggestions-internal-consolidation.md` → `docs/features/ai-suggestions-internal-consolidation/design.md`
- Move: `docs/authentication-migration.md` → `docs/features/authentication-migration/design.md`
- Move: `docs/http-decoupling-transition.md` → `docs/features/http-decoupling-transition/plan.md`
- Move: `docs/source-audio.md` → `docs/features/source-audio/design.md`
- Move: `docs/temp-pm-project-create-bypass.md` → `docs/tasks/<first-commit-date>-pm-project-create-bypass.md` (date determined in Step 1)
- Leave in place: `docs/ai-suggestions-workflow.md`, `docs/calver-versioning.md`, `docs/containerization.md`, `docs/cross-schema-types.md`, `docs/db-provisioning-and-setup.md`, `docs/permissions.md`, all of `docs/runbooks/deployment/`
- RBAC cluster: handled separately in Task 5 (do not touch `docs/proposals/user-centric-rbac/` or the RBAC-related files under `docs/superpowers/` in this task)

**Interfaces:** N/A (docs-only)

- [ ] **Step 1: Determine the date prefix for the temp file**

```bash
cd /Users/kasey/code/github.com/eten-tech-foundation/fluent-api
git log --diff-filter=A --format=%ad --date=short -- docs/temp-pm-project-create-bypass.md | tail -1
```
Use the printed date (format `YYYY-MM-DD`) as `<first-commit-date>` below.

- [ ] **Step 2: Perform the moves**

```bash
mkdir -p docs/features/feature-flags docs/features/ethnologue-language-import \
         docs/features/milestones \
         docs/features/betterauth-scripts-and-seeds \
         docs/features/account-self-management \
         docs/features/ai-suggestions-internal-consolidation \
         docs/features/authentication-migration \
         docs/features/http-decoupling-transition \
         docs/features/source-audio \
         docs/tasks

git mv docs/proposals/feature-flags docs/features/feature-flags

git mv docs/proposals/language-imports/2026-08-05-ethnologue-language-import-design.md \
       docs/features/ethnologue-language-import/design.md
git mv docs/proposals/language-imports/2026-08-05-ethnologue-language-import-plan.md \
       docs/features/ethnologue-language-import/plan.md

git mv docs/proposals/milestones/workflow_project-hierarchy.md \
       docs/features/milestones/proposal.md
git mv docs/proposals/milestones/workflow_project-hierarchy_review.md \
       docs/features/milestones/review.md

git mv docs/proposals/repeated-word-check docs/features/repeated-word-check
git mv docs/proposals/security-and-export-hardening docs/features/security-and-export-hardening

git mv docs/superpowers/plans/2026-05-13-betterauth-scripts-and-seeds.md \
       docs/features/betterauth-scripts-and-seeds/plan.md
git mv docs/superpowers/specs/2026-06-02-account-self-management-placeholder.md \
       docs/features/account-self-management/design.md

git mv docs/ai-suggestions-internal-consolidation.md \
       docs/features/ai-suggestions-internal-consolidation/design.md
git mv docs/authentication-migration.md \
       docs/features/authentication-migration/design.md
git mv docs/http-decoupling-transition.md \
       docs/features/http-decoupling-transition/plan.md
git mv docs/source-audio.md docs/features/source-audio/design.md

git mv docs/temp-pm-project-create-bypass.md \
       "docs/tasks/<first-commit-date>-pm-project-create-bypass.md"

find docs/proposals -type d -empty -delete
```

- [ ] **Step 3: Verify the moves**

Run: `git status --short | grep -E '^R '`
Expected: one rename line per file moved above.

- [ ] **Step 4: Commit**

```bash
git add -A docs
git commit -m "docs: migrate mechanical portion of docs to feature-grouped structure"
```

---

### Task 5: fluent-api — RBAC cluster reconciliation

This cluster is the motivating example from the spec: the same initiative's
docs are scattered across `proposals/`, `superpowers/specs/`,
`superpowers/plans/`, and `superpowers/reference/`, with two different slugs
(`user-centric-rbac` vs `user-central-tenant-rbac`) and two candidate
duplicate reference files. This task reconciles them into one
`docs/features/user-centric-rbac/` folder.

**Files:**
- Move: `docs/superpowers/specs/2026-06-02-user-central-tenant-rbac-design.md` → `docs/features/user-centric-rbac/design.md`
- Move: `docs/superpowers/plans/2026-06-02-user-central-tenant-rbac.md` → `docs/features/user-centric-rbac/plan.md`
- Move: `docs/proposals/user-centric-rbac/2026-07-02-org-membership-and-solo-workflow-design.md` → `docs/features/user-centric-rbac/design-org-membership-extension.md`
- Move: `docs/superpowers/reference/2026-06-02-user-central-tenent.md` → `docs/features/user-centric-rbac/reference/2026-06-02-tenant-diagram.md`
- Compare and dedupe: `docs/superpowers/reference/rbac_technical_reference_anu.md` vs `docs/superpowers/plans/rbac_technical_reference.md`

**Interfaces:** N/A (docs-only)

- [ ] **Step 1: Read both candidate technical-reference files and diff them**

```bash
cd /Users/kasey/code/github.com/eten-tech-foundation/fluent-api
diff docs/superpowers/reference/rbac_technical_reference_anu.md \
     docs/superpowers/plans/rbac_technical_reference.md
```
Read both files in full. If one is a strict subset or clearly stale draft of
the other, keep only the more complete/current one. If they diverge in
non-trivial ways (not just typos/formatting), keep both under distinct names
rather than discarding content.

- [ ] **Step 2: Perform the core moves**

```bash
mkdir -p docs/features/user-centric-rbac/reference

git mv docs/superpowers/specs/2026-06-02-user-central-tenant-rbac-design.md \
       docs/features/user-centric-rbac/design.md
git mv docs/superpowers/plans/2026-06-02-user-central-tenant-rbac.md \
       docs/features/user-centric-rbac/plan.md
git mv docs/proposals/user-centric-rbac/2026-07-02-org-membership-and-solo-workflow-design.md \
       docs/features/user-centric-rbac/design-org-membership-extension.md
git mv docs/superpowers/reference/2026-06-02-user-central-tenent.md \
       docs/features/user-centric-rbac/reference/2026-06-02-tenant-diagram.md
```

- [ ] **Step 3: Resolve the technical-reference duplicate per Step 1's finding**

If keeping only one:
```bash
git mv docs/superpowers/reference/rbac_technical_reference_anu.md \
       docs/features/user-centric-rbac/reference/technical-reference.md
git rm docs/superpowers/plans/rbac_technical_reference.md
```
(swap source file if the other one was the more complete version)

If keeping both (divergent content):
```bash
git mv docs/superpowers/reference/rbac_technical_reference_anu.md \
       docs/features/user-centric-rbac/reference/technical-reference-anu.md
git mv docs/superpowers/plans/rbac_technical_reference.md \
       docs/features/user-centric-rbac/reference/technical-reference.md
```

- [ ] **Step 4: Clean up empty directories and verify**

```bash
find docs/proposals docs/superpowers -type d -empty -delete
test ! -d docs/proposals -a ! -d docs/superpowers && echo OK
```
Expected: `OK`

- [ ] **Step 5: Grep for and fix broken relative links**

```bash
grep -rln '](\./\|](\.\./\|](docs/' docs/ | grep -v '\.png)'
```
Fix any hit pointing at a moved RBAC path, and check `docs/permissions.md`
specifically since it's the most likely doc to cross-reference the RBAC
design.

- [ ] **Step 6: Write `docs/README.md`**

```markdown
# Docs directory structure

This repo follows the Fluent-wide docs convention. See
[the spec](https://github.com/eten-tech-foundation/fluent-platform/blob/main/docs/features/docs-directory-structure/design.md)
in fluent-platform for the full rationale.

- `features/<slug>/` — everything about one feature or initiative:
  `proposal.md`, `design.md`, `plan.md`, `tickets/`, `reference/`. Only the
  stages that exist are present.
- `runbooks/` — operational procedures (deploys, rollbacks, hotfixes).
- `tasks/` — standalone dated work items with no parent feature.
- Loose files at the root of `docs/` — repo-wide reference docs.
```

- [ ] **Step 7: Review the diff and commit**

```bash
git status
git add -A docs
git commit -m "docs: reconcile scattered RBAC docs into a single feature folder"
```
