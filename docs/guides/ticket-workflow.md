# Ticket workflow

How tickets move through the Fluent development pipeline: the shared project
board, what each stage means, and the labels a ticket carries.

## The board

One org-level GitHub Project — **"Fluent"** (`eten-tech-foundation` project
**#4**, id `PVT_kwDOB8vK1s4A34c5`) — is shared by fluent-web, fluent-api,
fluent-ai, fluent-mobile and fluent-platform. An issue lives in exactly one
repo's number space; the board's **Status** field is the pipeline.

Creating an issue does not put it on the board. A ticket enters the pipeline
at `In Progress (Product)` — when you create one, add it to the project and
set the status yourself (see [Board mechanics](#board-mechanics)).

## The pipeline

```
Backlog → In Progress (Product) → Product Ready → Sprint Shaping
        → Dev Ready → In Progress (Dev) → In PR Review → In QA
        → Passed QA → To Deploy → Done
```

- **Backlog** — tickets that may be considered later.
- **In Progress (Product)** — product is creating/refining the ticket. New
  tickets start here.
- **Product Ready** — engineering, generally the lead, looks over the ticket
  to identify gaps. Blockers and related features are identified, and the QA
  path is marked with `Full QA` or `DevQA`.
- **Sprint Shaping** — the ticket is reviewed: the engineering team asks
  questions, product explains and clarifies intent, labels are applied
  (`bug`, `github_actions`, etc.), and effort estimates are set for dev and
  QA.
- **Dev Ready** — ready for a dev to take:
  - Claim by self-assigning, then move the ticket to `In Progress (Dev)`.
  - `ready-for-agent` tickets are the AFK contract: implementable without
    asking follow-up questions.
  - Agents do not take `ready-for-human` tickets.
  - The `SP<n>` label for the current sprint is applied when the ticket is
    accepted into the sprint.
- **In Progress (Dev)** — actively being worked.
- **In PR Review** — a PR is open and ready for review by other engineers:
  - The PR is linked to the ticket.
  - A draft PR means the ticket stays `In Progress (Dev)` — the assigned dev
    requests feedback directly instead.
  - Engineering completes PRs for each other — a reviewer may carry a PR
    over the line.
  - On approval the feature branch merges to `main` and deploys to the dev
    environment automatically. Make sure env vars or other special tasks for
    the dev environment are handled.
  - For `DevQA` tickets, PR approval *is* QA approval: the ticket moves
    straight to `Passed QA` and the normal release steps continue.
  - Update the dev effort to reflect the actual time taken.
- **In QA** — merged and deployed to the QA environment, ready for QA
  review:
  - The QA engineer is assigned to the ticket.
  - If QA finds issues, the ticket goes back to `In Progress (Dev)` and the
    dev who worked it handles the feedback.
  - On approval the ticket moves to `Passed QA` and QA is unassigned.
- **Passed QA** — the dev ensures everything is ready for release: env var
  changes, special deployment tasks and anything else the deploy needs are
  noted and ready. Then move the ticket to `To Deploy`.
- **To Deploy** — ships with the next release to production.
- **Done** — complete and deployed to production.

## Labels

Labels live on the issue itself, not on board fields. Label vocabularies
differ per repo; this is the shared core and each repo's extras.

### Triage labels (all five repos)

These describe how ready the *writeup* is, independent of pipeline stage.

| Label | Color | Meaning |
| --- | --- | --- |
| `needs-triage` | `#FBCA04` | Maintainer needs to evaluate this issue. |
| `needs-info` | `#D93F0B` | Waiting on reporter for more information. |
| `ready-for-agent` | `#0E8A16` | Fully specified, ready for an AFK agent. |
| `ready-for-human` | `#1D76DB` | Fully specified, ready for a human engineer. |
| `wontfix` | `#ffffff` | Will not be actioned. |

Use them as a cycle, not permanent states. `needs-triage` marks an issue
nobody has evaluated — the triage queue is `--label needs-triage`. Evaluation
resolves it: `needs-info` when the writeup lacks something only the reporter
can supply (always paired with a comment saying exactly what's missing, and
removed when the answer arrives), `ready-for-agent`/`ready-for-human` when
it's well-specified, or `wontfix`. A reporter who goes silent stays parked on
`needs-info` until it's closed as stale.

They resolve ahead of the pipeline — a `needs-*` label on a `Dev Ready`
ticket is a smell. In `Dev Ready`, `ready-for-agent` is the queue an AFK
agent claims from, and the correct bounce when an agent can't proceed is
`needs-info` plus a comment, not a guess.

### QA-path labels (all five repos)

Applied at `Product Ready`, deciding who verifies the work:

| Label | Color | Meaning |
| --- | --- | --- |
| `Full QA` | `#0075CA` | Goes through the normal QA pass in `In QA`. |
| `DevQA` | `#2550d0` | Engineering does the QA; PR approval doubles as QA sign-off and the ticket skips `In QA`. |

### Sprint membership: `SP<n>` labels

`SP<n>` marks which sprint took the ticket (e.g. `SP18`), applied when it is
accepted into the sprint. A ticket carried over between sprints accumulates
labels (`SP16` + `SP17` + `SP18` = third sprint on it). The board also has a
**Sprint** iteration field, currently unused — labels are the operative
mechanism.

### Repo and work-type labels

- **Area/repo tag**: fluent-web uses `web-app`, `server`, `mobile app`,
  `roadmap`; fluent-api uses `mobile requirement` for work driven by the
  mobile app; fluent-mobile uses `API Work Required` when it needs new
  fluent-api capability.
- **Type**: `bug`, `enhancement`, `chore` (mobile only), `documentation`.
- **`Blocker`** (web, api): blocks other work or a release. Distinct from
  **`BLOCKED`** (mobile only): this issue is blocked by another issue.
- **Automation**: `automated` (ai, mobile), `dependencies`, `github_actions`,
  `javascript`, `python:uv`, `preview-build`, `nightly-preview`, `ci` —
  Dependabot/CI labels; leave them alone.

### Other board fields

- **Priority**: `P0`, `P1`, `P2` (single select, id
  `PVTSSF_lADOB8vK1s4A34c5zgs8ass`).
- **Milestones**: product milestones (e.g. `Text Drafting`,
  `Audio Recording`; `(M)` suffix = mobile). Single select, id
  `PVTSSF_lADOB8vK1s4A34c5zg1P_W0`.
- **Estimate**: effort estimate; set at Sprint Shaping and updated to actual
  dev effort on completion.
- **Start date** / **End date**: free fields, lightly used.
- **Repository** / **Parent issue** / **Sub-issues progress**: maintained by
  GitHub.

## Board mechanics

`gh project` commands need the `project` auth scope
(`gh auth refresh -s project` if you get a scope error).

```bash
# Add an issue to the board
gh project item-add 4 --owner eten-tech-foundation --url <issue-url>

# Set Status by name — no id lookups needed
gh project item-edit 4 --owner eten-tech-foundation --url <issue-url> \
  --field Status --value "In QA"
```

For scripts and API calls you can address items by GraphQL node id instead.
Project id: `PVT_kwDOB8vK1s4A34c5`. Status field id:
`PVTSSF_lADOB8vK1s4A34c5zgs8akY`. Option ids:

| Status | Option id |
| --- | --- |
| Backlog | `f75ad846` |
| In Progress (Product) | `47fc9ee4` |
| Product Ready | `98236657` |
| Sprint Shaping | `75636d82` |
| Dev Ready | `400f32e3` |
| In Progress (Dev) | `db53740f` |
| In PR Review | `19224fda` |
| In QA | `bb3c3d02` |
| Passed QA | `effbac47` |
| To Deploy | `8706b8cd` |
| Done | `3c942df6` |

## Conventions

- **One issue, one repo.** File it in the repo that owns the code change.
  Cross-repo work means linked issues, not one ticket spanning repos.
- **PRs link the issue** (`Closes #<n>`).
- Deploy path: merge to `main` deploys to **dev** automatically; cutting a
  CalVer release tag deploys it to **QA**; `promote-to-prod` ships to
  production.
