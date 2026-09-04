# Docs Directory Structure Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate `docs/` in fluent-ai, fluent-api, fluent-mobile, and fluent-web to the feature-grouped structure defined in the spec, with history preserved and no broken links, then make the structure self-sustaining via an AGENTS.md convention pointer and a CI check in each repo.

**Architecture:** Per-repo, mechanical `git mv` of already-categorized docs (old `proposals/`, `superpowers/{plans,specs,reference}/`, `design/` folders) into `docs/features/<slug>/`, plus a small number of judgment calls for loose root-level docs and one drifted-slug cluster in fluent-api. Each repo gets a `docs/README.md` describing the convention. `runbooks/` is untouched everywhere; `guides/` is untouched except a rename within fluent-ai (`api-key-runbook.md` → `api-keys.md`). A final task adds the two-layer enforcement from the spec: an AGENTS.md pointer (reaches convention-following agents, including the skill's documented override mechanism) and a CI structure check in each repo's existing PR-gating workflow — `pre-merge.yml` for fluent-ai/fluent-api/fluent-web, `quality-gates.yml` for fluent-mobile, which has no `pre-merge.yml` — reaching everything else, since it doesn't depend on anyone having read anything first.

**Tech Stack:** git (mv, log for history/dates), markdown link grep.

**Spec:** `docs/features/docs-directory-structure/design.md` (this repo, fluent-platform)

## Global Constraints

- Every move uses `git mv` (or `git mv` + manual edit for renames), never delete+recreate — history must follow the file.
- No `superpowers/` directory survives migration in any repo.
- Feature folder file naming follows the spec's three cases: (1) one document per stage → fixed name (`proposal.md`/`design.md`/`plan.md`); (2) multiple documents for the same stage → dated files, either flat in the feature folder prefixed with the stage name or under a `plans/`/`tickets/` subfolder; (3) a document that doesn't map onto proposal/design/plan at all → keep its original descriptive filename. See the spec's Rules section for full detail.
- Before every migration commit (all of Tasks 1–5, no exceptions), audit the **whole repository**, not just `docs/`, for references to every path moved in that task, and fix any hit. Use `git grep -n -E` with the literal old-path substrings from that task's Files list — a substring match catches Markdown inline links (`](path)`), Markdown reference-style link definitions (`[label]: path`), HTML `href=`/`src=` links, and absolute `/docs/...` references all in one pass, regardless of wrapper syntax, anywhere in the repo (README, AGENTS.md/CLAUDE.md, source comments, etc.), since `git grep` only searches tracked files and already respects `.gitignore`.
- Each task ends in one commit on the target repo's current branch (do not create new branches — each repo is already on its own working branch). A repo's migration may span multiple tasks — fluent-api is split across Task 4 (mechanical moves) and Task 5 (RBAC cluster reconciliation) — each producing its own commit.
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
cd <path-to-fluent-ai-checkout>  # repository root
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

- [ ] **Step 3: Audit the whole repository for references to moved paths**

```bash
git grep -n -E 'docs/superpowers/|docs/http-decoupling-transition\.md|docs/guides/api-key-runbook\.md'
```
This is a repo-wide, tracked-files-only search (`git grep` respects
`.gitignore`), so it catches Markdown inline links, Markdown
reference-style link definitions, HTML `href=`/`src=` links, and absolute
`/docs/...` references anywhere in the repo — not just `docs/` and not
just Markdown files. For each hit whose target path was moved above,
update the link to the new path.

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
git add -A
git commit -m "docs: migrate to feature-grouped docs structure"
```

---

### Task 2: fluent-mobile

**Files:**
- Move: `docs/design/record-tab/` (whole directory, including `README.md` and all `.png` files) → `docs/features/record-tab/design/`
- Leave in place: `docs/AGENT_ONBOARDING.md`, `docs/ci.md`, `docs/issue-tracking.md` (repo-wide reference docs, heavily linked from `AGENTS.md`/`CLAUDE.md`/cursor rules — kept at `docs/` root rather than moved into `guides/`, per review feedback)
- Leave in place: everything already under `docs/guides/`
- Create: `docs/README.md`

**Interfaces:** N/A (docs-only)

- [ ] **Step 1: Perform the moves**

```bash
cd <path-to-fluent-mobile-checkout>  # repository root
mkdir -p docs/features/record-tab
git mv docs/design/record-tab docs/features/record-tab/design
find docs/design -type d -empty -delete
```

- [ ] **Step 2: Verify `docs/design/` no longer exists**

Run: `test ! -d docs/design && echo OK`
Expected: `OK`

- [ ] **Step 3: Audit the whole repository for references to moved paths**

```bash
git grep -n -E 'docs/design'
```
This is a repo-wide, tracked-files-only search covering Markdown inline
links, Markdown reference-style link definitions, HTML `href=`/`src=`
links, and absolute `/docs/...` references — not just `docs/` and not just
Markdown. `docs/features/record-tab/design/README.md`'s own image
references (`./01-idle-ready.png`, etc.) are unaffected since the whole
directory moved together and won't match this pattern. Check `AGENTS.md`,
`CLAUDE.md`, and any other hit that links to `docs/design/...` by path,
and update it.

- [ ] **Step 4: Write `docs/README.md`**

```markdown
# Docs directory structure

This repo follows the Fluent-wide docs convention. See
[the spec](https://github.com/eten-tech-foundation/fluent-platform/blob/main/docs/features/docs-directory-structure/design.md)
in fluent-platform for the full rationale.

- `features/<slug>/` — everything about one feature or initiative:
  `proposal.md`, `design.md`, `plan.md`, `tickets/`, `design/` (mockups).
  Only the stages that exist are present.
- `guides/` — process/how-to docs not tied to one feature.
- `tasks/` — standalone dated work items with no parent feature.
- Loose files at the root of `docs/` — repo-wide reference docs
  (includes `AGENT_ONBOARDING.md`, `ci.md`, `issue-tracking.md`, which
  stay here rather than moving into `guides/` since they're heavily
  linked from agent entrypoints and read as repo-wide reference material).
```

- [ ] **Step 5: Review the diff and commit**

```bash
git status
git add -A
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
cd <path-to-fluent-web-checkout>  # repository root
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

- [ ] **Step 3: Audit the whole repository for references to moved paths**

```bash
git grep -n -E 'docs/proposals/|docs/superpowers/'
```
This is a repo-wide, tracked-files-only search covering Markdown inline
links, Markdown reference-style link definitions, HTML `href=`/`src=`
links, and absolute `/docs/...` references — not just `docs/` and not just
Markdown. Fix any hit pointing at an old `proposals/` or `superpowers/`
path.

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
git add -A
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
cd <path-to-fluent-api-checkout>  # repository root
git log --diff-filter=A --format=%ad --date=short -- docs/temp-pm-project-create-bypass.md | tail -1
```
Use the printed date (format `YYYY-MM-DD`) as `<first-commit-date>` below.

- [ ] **Step 2: Perform the moves**

```bash
mkdir -p docs/features/ethnologue-language-import \
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

- [ ] **Step 4: Audit the whole repository for references to moved paths**

```bash
git grep -n -E 'docs/proposals/|docs/superpowers/|docs/ai-suggestions-internal-consolidation\.md|docs/authentication-migration\.md|docs/http-decoupling-transition\.md|docs/source-audio\.md|docs/temp-pm-project-create-bypass\.md'
```
This is a repo-wide, tracked-files-only search covering Markdown inline
links, Markdown reference-style link definitions, HTML `href=`/`src=`
links, and absolute `/docs/...` references — not just `docs/` and not just
Markdown. `docs/permissions.md`, `docs/ai-suggestions-workflow.md`, and
`AGENTS.md` are the most likely files to cross-reference the moved docs.
Fix any hit whose target path was moved above.

- [ ] **Step 5: Commit**

```bash
git add -A
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
- Move: `docs/proposals/user-centric-rbac/2026-07-02-org-membership-and-solo-workflow-design.md` → `docs/features/user-centric-rbac/2026-07-02-design-org-membership-extension.md`
- Move: `docs/superpowers/reference/2026-06-02-user-central-tenent.md` → `docs/features/user-centric-rbac/reference/2026-06-02-tenant-diagram.md`
- Compare and dedupe: `docs/superpowers/reference/rbac_technical_reference_anu.md` vs `docs/superpowers/plans/rbac_technical_reference.md`

**Interfaces:** N/A (docs-only)

- [ ] **Step 1: Read both candidate technical-reference files and diff them**

```bash
cd <path-to-fluent-api-checkout>  # repository root
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
       docs/features/user-centric-rbac/2026-07-02-design-org-membership-extension.md
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

- [ ] **Step 5: Audit the whole repository for references to moved paths**

```bash
git grep -n -E 'docs/superpowers/|docs/proposals/user-centric-rbac'
```
This is a repo-wide, tracked-files-only search covering Markdown inline
links, Markdown reference-style link definitions, HTML `href=`/`src=`
links, and absolute `/docs/...` references — not just `docs/` and not just
Markdown. Fix any hit pointing at a moved RBAC path, and check
`docs/permissions.md` specifically since it's the most likely doc to
cross-reference the RBAC
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
git add -A
git commit -m "docs: reconcile scattered RBAC docs into a single feature folder"
```

---

### Task 6: enforcement — AGENTS.md pointer + CI structure check (fluent-ai, fluent-api, fluent-mobile, fluent-web)

Per the spec's Enforcement section: the convention layer (AGENTS.md) only
reaches agents that read it before writing docs; the enforcement layer (CI)
is what makes compliance hold regardless of who or what touched `docs/`.
Both are added here, per repo. fluent-platform is out of scope (no CI
workflows exist there yet — separate follow-up).

**Files (each repo):**
- Create: `scripts/check-docs-structure.sh`
- Modify: repo's `AGENTS.md` (create fresh for fluent-api and fluent-web,
  which have none; extend the existing one for fluent-ai and fluent-mobile)
- Modify: `.github/workflows/pre-merge.yml` (fluent-ai, fluent-api,
  fluent-web) or `.github/workflows/quality-gates.yml` (fluent-mobile) — add
  a `docs-structure` job

**Interfaces:**
- Produces: `scripts/check-docs-structure.sh`, exit 0 if `docs/` matches the
  allowed shape, exit 1 with one `::error::` line per violation otherwise.

- [ ] **Step 1: Write the shared check script (identical content in all four repos)**

```bash
#!/usr/bin/env bash
set -euo pipefail

allowed=(features runbooks guides tasks)
status=0
shopt -s nullglob

for entry in docs/*; do
  name="$(basename "$entry")"
  if [[ -d "$entry" ]]; then
    ok=0
    for a in "${allowed[@]}"; do
      [[ "$name" == "$a" ]] && ok=1
    done
    if [[ "$ok" -eq 0 ]]; then
      echo "::error::Unexpected top-level docs/ directory: docs/$name — allowed: ${allowed[*]} (plus loose *.md files at docs/ root). See docs/README.md."
      status=1
    fi
  elif [[ -f "$entry" ]]; then
    if [[ "$name" != *.md ]]; then
      echo "::error::Unexpected top-level docs/ file: docs/$name — only *.md files are allowed loose at docs/ root. See docs/README.md."
      status=1
    fi
  fi
done

exit "$status"
```

Save this as `scripts/check-docs-structure.sh` in each of fluent-ai,
fluent-api, fluent-mobile, fluent-web, then:

```bash
chmod +x scripts/check-docs-structure.sh
```

- [ ] **Step 2: Verify the script locally in each repo**

```bash
./scripts/check-docs-structure.sh && echo PASS
```
Expected: `PASS` in all four repos (Tasks 1–5 already brought `docs/` into
the allowed shape). Then confirm it actually catches a violation:

```bash
mkdir -p docs/scratch-test
./scripts/check-docs-structure.sh; status=$?
rmdir docs/scratch-test
echo "exit status: $status"
[[ "$status" -eq 1 ]] && echo "PASS (correctly failed)" || echo "FAIL (expected exit 1, got $status)"
```
Expected: an `::error::` line naming `docs/scratch-test`, then `PASS (correctly failed)`.

- [ ] **Step 3: Add the Docs pointer to fluent-ai's `AGENTS.md`**

Append a new section:

```markdown
## Docs

See `docs/README.md` for the docs directory convention. Brainstorming and
writing-plans skill output goes to `docs/features/<slug>/`
(`proposal.md`/`design.md`/`plan.md`/`tickets/`), not the skill's built-in
`docs/superpowers/...` default.
```

- [ ] **Step 4: Add the Docs pointer to fluent-mobile's `AGENTS.md`**

Add a row to the existing "For agents / tools" table:

```markdown
| [docs/README.md](docs/README.md) | Docs directory convention — features/, runbooks/, guides/, tasks/ |
```

- [ ] **Step 5: Create a minimal `AGENTS.md` for fluent-api**

```markdown
# AGENTS.md — Fluent API

## Docs

See `docs/README.md` for the docs directory convention. Brainstorming and
writing-plans skill output goes to `docs/features/<slug>/`
(`proposal.md`/`design.md`/`plan.md`/`tickets/`), not the skill's built-in
`docs/superpowers/...` default.
```

- [ ] **Step 6: Create a minimal `AGENTS.md` for fluent-web**

```markdown
# AGENTS.md — Fluent Web

## Docs

See `docs/README.md` for the docs directory convention. Brainstorming and
writing-plans skill output goes to `docs/features/<slug>/`
(`proposal.md`/`design.md`/`plan.md`/`tickets/`), not the skill's built-in
`docs/superpowers/...` default.
```

- [ ] **Step 7: Add the CI job to fluent-ai's `.github/workflows/pre-merge.yml`**

Add a sibling job to the existing `validate` job (same file, `jobs:` at top level):

```yaml
    docs-structure:
        name: Docs Structure Check
        runs-on: ubuntu-latest
        timeout-minutes: 5
        if: ${{ !github.event.pull_request.draft }}
        steps:
            - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
              with:
                  persist-credentials: false
            - run: ./scripts/check-docs-structure.sh
```
Match the existing file's indentation style exactly (4-space, as seen in the
`validate` job) rather than the 2-space shown here. Use whatever pinned
`checkout` SHA/version comment the repo's other jobs already use if it
differs from the one above — match the existing convention, don't
introduce a second one.

- [ ] **Step 8: Add the CI job to fluent-api's `.github/workflows/pre-merge.yml`**

Add a sibling job to the existing `validate` job:

```yaml
  docs-structure:
    name: Docs Structure Check
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - run: ./scripts/check-docs-structure.sh
```
Use whatever pinned `checkout` SHA/version comment fluent-api's other jobs
already use if it differs from the one above — match the existing
convention, don't introduce a second one.

- [ ] **Step 9: Add the CI job to fluent-web's `.github/workflows/pre-merge.yml`**

Same job definition as Step 8 (fluent-web's `validate` job uses the same
2-space style; same note about matching fluent-web's existing pinned
`checkout` version if it differs).

- [ ] **Step 10: Add the CI job to fluent-mobile's `.github/workflows/quality-gates.yml`**

Add a sibling job alongside `typecheck`/`expo-doctor`/`expo-install-check`.
fluent-mobile's `action-pins` check requires every action pinned to a
commit SHA — match the `checkout` pin the other jobs in this file already
use:

```yaml
  docs-structure:
    name: Docs Structure Check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - run: ./scripts/check-docs-structure.sh
```

- [ ] **Step 11: Commit, per repo**

```bash
git add scripts/check-docs-structure.sh AGENTS.md .github/workflows/
git commit -m "ci: enforce docs/ directory structure convention"
```
