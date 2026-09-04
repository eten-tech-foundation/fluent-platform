# Consistent `docs/` directory structure across Fluent repos

## Problem

The `docs/` directory in each Fluent repo (fluent-ai, fluent-api, fluent-mobile,
fluent-platform, fluent-web) grew organically and independently. A survey of all
five found five different shapes:

- **fluent-ai**: loose files, `guides/`, `runbooks/deployment/`, `superpowers/{plans,specs}/`
- **fluent-api**: loose files, `proposals/<feature>/`, `runbooks/deployment/`,
  `superpowers/{plans,reference,specs}/`
- **fluent-mobile**: loose files, `design/`, `guides/` — no `superpowers/`, no
  `proposals/`/`runbooks/`
- **fluent-platform**: loose files, `assessments/`, `plans/`, `specs/`, `tickets/` —
  flat, no `superpowers/` wrapper
- **fluent-web**: loose files, `proposals/<feature>/`, `runbooks/deployment/`,
  `superpowers/{plans,specs,tickets}/`

The `superpowers/` wrapper exists only because it's the default output location
the brainstorming/writing-plans skills write to — it isn't a deliberate
convention, and two repos already bypass it.

The concrete failure mode this causes: a single feature's artifacts scatter
across unrelated top-level trees, and their names drift apart in the process.
In fluent-api, the RBAC work has `proposals/user-centric-rbac/`,
`superpowers/specs/2026-06-02-user-central-tenant-rbac-design.md`, and
`superpowers/plans/2026-06-02-user-central-tenant-rbac.md` — one initiative,
three trees, two different slugs (`user-centric-rbac` vs
`user-central-tenant-rbac`). There is no single place to look for "everything
about this feature."

## Goals

- One directory shape, used consistently across all five repos.
- A feature's proposal, design spec, implementation plan, and any spun-off
  tickets live together, findable by one slug.
- Non-feature-scoped docs (ops runbooks, process guides, standalone small
  tasks) get their own top-level homes, since grouping them by feature would
  scatter things people need fast during an outage.
- AI-planning skill output (brainstorming, writing-plans) lands directly in
  the right place with no separate namespace to reconcile later.

## Non-goals

- Redesigning the content or template of any individual doc type.
- Changing how runbooks/guides are authored — only where they live (already
  top-level, unchanged).

## Structure

```
docs/
  <loose files>.md            # repo-wide reference docs: architecture.md,
                               # permissions.md, containerization.md, etc.
                               # Kept loose at the root — few in number, not
                               # worth a dedicated folder.
  features/
    <feature-slug>/
      proposal.md              # initial idea / suggestion (brainstorming output)
      design.md                # approved spec
      plan.md                  # implementation plan
      tickets/                 # only if the feature spun off discrete,
        YYYY-MM-DD-<item>.md   # dated work items
    assessment-<name>/         # security/risk assessments — same shape as a
                                # feature folder (their own proposal/design/etc.
                                # as applicable)
  runbooks/
    deployment/
      prod-release.md
      prod-rollback.md
      prod-emergency-hotfix.md
      ...
  guides/
    <topic>.md                 # process/how-to docs, not tied to one feature
  tasks/
    YYYY-MM-DD-<task>.md       # standalone items with no parent feature
                                # (e.g. a one-off bug fix, a lone hardening task)
```

### Rules

- A feature folder holds only the stages that actually exist for it — no
  empty placeholder files.
- File names inside a feature folder are fixed (`proposal.md`, `design.md`,
  `plan.md`), not dated. Git history covers revisions. If a feature genuinely
  needs multiple plan revisions or phases living side by side, use
  `plans/YYYY-MM-DD-<phase>.md` (or `tickets/YYYY-MM-DD-<item>.md`) instead of
  a single file — same pattern already used for `tickets/`.
- No `superpowers/` wrapper directory. Brainstorming/writing-plans skill
  output is configured to write directly into `features/<slug>/`.
- A doc belongs in `tasks/` only if it has no parent feature. Once a task is
  understood to be part of a larger feature's work, it moves into that
  feature's `tickets/` subfolder instead. This is why the top-level dir is
  named `tasks/` rather than `tickets/` — to avoid collision with the
  per-feature `tickets/` subfolder.
- fluent-mobile's `design/` (visual mockups/screenshots) folds into the
  relevant feature folder as `features/<slug>/design/*.png`.

## Migration

Applied per repo via `git mv`, preserving history, with a short
`docs/README.md` added to each repo explaining the convention so it's
discoverable and so skill output lands in the right place going forward.

Scope: fluent-ai, fluent-api, fluent-mobile, fluent-web. fluent-platform is
deferred — it already has an in-progress, differently-shaped restructuring
attempt (flat `docs/{plans,specs,tickets,assessments}/`, no feature grouping)
sitting uncommitted on the `task/add-docs-structure` branch, and needs to be
reconciled with this design before its own migration proceeds.

Feature-slug mapping is best-effort from what exists today. Where a feature's
artifacts already carry drifted slugs (e.g. fluent-api's RBAC work), the
migration reconciles them to a single slug rather than preserving the drift.
