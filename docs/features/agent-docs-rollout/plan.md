# Agent docs rollout: fluent-api and fluent-ai

Status: filed as fluent-api#498 and fluent-ai#91 (2026-11-12).

## Why

fluent-web#545 / PR #546 gave fluent-web agent docs that help with PR reviews and implementation:

| fluent-web file | Role |
| --- | --- |
| `AGENTS.md` | One-line repo description, then "read only what the task needs": which doc to open for which kind of task, plus the 1–2 rules that apply to every change. Loaded on every request, so it holds pointers, not content. |
| `docs/code-map.md` | Where each feature lives, its key files, the endpoints it calls, and the boundaries with other repos. |
| `docs/domain-rules.md` | Rules the code and tests rely on (permissions, scripture text, saving, async, flags). **Each rule names the code that holds it and a test that pins it** (or says no test covers it). Intentional behaviors that look like bugs are called out at the top. A PR that breaks a rule updates the file. |
| `README.md#checks-before-a-pr` | What `precheck` covers, what CI adds, which checks draft PRs skip. |
| `scripts/check-docs-structure.sh` | Allows `docs/adr/`. |

Feature PRs since then (#583, #614, #620, #629, …) update `code-map.md` and `domain-rules.md` in
the same PR, so the docs are staying current.

fluent-api and fluent-ai already have the earlier layer (#499 equivalents: `docs/agents/`
issue tracker, triage labels, domain docs). They lack the code map, domain rules and task routing.

## Current state

| | fluent-web | fluent-api | fluent-ai |
| --- | --- | --- | --- |
| `AGENTS.md` task routing | yes | no (has Code standards section) | no |
| `CLAUDE.md` → `@AGENTS.md` | **no** | yes | **no** |
| `docs/code-map.md` | yes | no; `ARCHITECTURE.md` covers patterns, not where things are | no; `docs/architecture.md` is a generic FastAPI template that doesn't match `src/app` (e.g. both `routers/` and `api/v1/endpoints/` exist) |
| `docs/domain-rules.md` | yes | no; `docs/permissions.md` (30K) and `docs/ai-suggestions-workflow.md` hold some of it as reference prose | no; `docs/api-data-dependencies.md` holds one rule |
| `CONTEXT.md` / `docs/adr/` | no / no | yes / yes | no / no |
| Docs check allows `adr/` | yes | yes | **no** |
| Validation guidance | README section | `docs/guides/code-standards.md` + `pre-pr-standards` skill (`npm run verify`) | none for agents; CI runs `ruff check`, `ruff format --check`, `mypy`, `pytest`, docs check |
| Enforced coding standard | no | yes (FA-L/C/R) | no |

Other observations: fluent-ai has three `greek-room-integration-*.md` files at the repo root
(outside `docs/`), and `.gitignore` ignores `.claude/`, so fluent-ai can't commit a skill the way
fluent-api does.

## Scope

In: the fluent-web pattern (routing `AGENTS.md`, code map, domain rules, validation guidance,
`CLAUDE.md` pointer, `adr/` allowance) in fluent-api and fluent-ai.

Out: coding standards for fluent-ai and fluent-web (separate work). This plan must not create a
fluent-ai rule catalog by the back door. `domain-rules.md` holds behavioral invariants, not style
or structure.

## Boundaries between docs (decide once, apply in both repos)

- **code-map.md**: _where_ things are and what they call. Links to `ARCHITECTURE.md` for _how_
  modules are shaped; doesn't restate it.
- **domain-rules.md**: _what behavior must hold_, with code + test citations. In fluent-api it
  never restates an FA rule; if a rule is structural, it belongs in `code-standards.md`.
- **Existing long reference docs** (`permissions.md`, `ai-suggestions-workflow.md`): stay as the
  deep reference. Domain rules summarize the invariant in one bullet and link the section. Don't
  copy the role–permission matrix.
- **AGENTS.md**: pointers only, plus at most two always-on rules (e.g. "don't hand-edit
  migrations", "run `npm run verify`").

## Decisions (2026-11-12)

1. **Behavior review is the ticket engineer's job.** While writing the domain rules, the engineer
   working the ticket decides, for each behavior found, whether it is the desired behavior. The
   docs and agent guides record the _desired_ behavior. Where the code differs:
   - a deliberate **exception** is recorded in `domain-rules.md` next to the rule, with the reason;
   - a **grandfathered divergence** (code doesn't match the desired rule and should change) is
     marked as such in `domain-rules.md` and listed in a follow-on ticket to resolve it. The
     follow-on is filed by the engineer before the docs PR merges and linked from the PR.
2. **`docs/permissions.md` stays** the deep reference for fluent-api auth. Domain rules summarize
   each invariant in one bullet and link the section.
3. **fluent-ai `docs/architecture.md` was the target structure.** Much of it still holds; update
   it so it matches `src/app` today, rather than relabelling it.
4. **One ticket per repo.** The scope is tight enough; sub-steps below are checklist items, not
   separate tickets.

## Tickets

The two tickets can run in parallel. Follow #546's process: draft PR first, Kasey reviews where
each kind of context belongs, then ready for review.

Common acceptance criteria (both tickets):

- [ ] `AGENTS.md` stays short and only points to docs needed for specific tasks.
- [ ] Every path, endpoint and link in the new docs exists on `main`.
- [ ] Every domain rule cites the code that holds it and a test that pins it, or says no test
      covers it; every cited test exists and passes.
- [ ] Each rule states the desired behavior; exceptions are recorded with a reason;
      grandfathered divergences are marked and listed in a linked follow-on ticket.
- [ ] Existing docs are linked, not duplicated.
- [ ] The repo's full check passes, including the docs structure check.

### fluent-api: Route agents from AGENTS.md, add a code map and domain rules

**AGENTS.md**

- [ ] Rewrite to the fluent-web shape: one-line description ("Fluent's backend: Hono + Drizzle on
      Postgres; the only backend for fluent-web, calls fluent-ai over HTTP"), then "Read only
      what the task needs":
  - where a domain/endpoint lives → `docs/code-map.md`
  - permissions, scripture text, saving, async jobs, content protection → `docs/domain-rules.md`
  - writing code in `src/` → `docs/guides/code-standards.md` (keep the existing Code standards
    section; it's the repo's always-on rule)
  - module shape and layering → `ARCHITECTURE.md`; auth detail → `docs/permissions.md`
  - setup, migrations, DB → `CONTRIBUTING.md`, `docs/db-provisioning-and-setup.md`
- [ ] Keep the Docs and Agent skills sections as they are.

**docs/code-map.md**

- [ ] **Outside this repo**: fluent-web (only browser client, session cookie via better-auth),
      fluent-ai (outbound calls, auth to it, callbacks back in), Aquifer/YouVersion proxies,
      Bible audio/TTS providers, Postgres schema ownership (link the db-ownership-separation
      feature), App Insights.
- [ ] **App shell**: `src/index.ts`, `src/server/app.ts`, `src/routes/`, `src/middlewares/`,
      `src/env.ts`.
- [ ] **Domains**: one bullet per `src/domains/*` (≈24): responsibility, key files, route
      prefixes, and which fluent-web feature calls it. Use the endpoint strings fluent-web's
      code map uses so a search finds both sides.
- [ ] **Workers, DB, shared code**: `src/workers/`, `src/db/` (schema, migrations, seeds),
      `src/lib/`.
- [ ] **Feature docs**: index of `docs/features/*`.
- [ ] README project-structure section links the code map rather than duplicating it.

**docs/domain-rules.md**

Same header as fluent-web's ("rules the current code and tests rely on… if a change has to break a
rule, say so in the PR and update this file"), plus a short legend for exceptions and
grandfathered divergences. Candidate sections, to confirm against the code:

- [ ] **Permissions**: authn chain layers, `authorize()` scoping, org managers ⊇ PM powers, what
      fluent-web relies on the API to check (fluent-web's rules name gaps such as
      `assign-selected` not checking translator roles or chapter status; decide whether that's
      desired, an exception, or a divergence). Link `permissions.md` sections.
- [ ] **Scripture text and content protection**: verse storage, USFM import/validation/export,
      pericopes, Bible/TTS licence fence, what may leave the API to third parties.
- [ ] **Saving**: translated-verse writes, last-save-wins (intentional, matching fluent-web),
      versioned-resource writers (link the existing skill).
- [ ] **Async**: workers, AI suggestion job lifecycle and callbacks (link
      `ai-suggestions-workflow.md`), catalogue-sync watermarks, startup ordering (ADR 0001).
- [ ] **Feature flags / env**: what's gated and where.
- [ ] No bullet restates an FA rule; structural rules belong in `code-standards.md`.
- [ ] Where fluent-web's `domain-rules.md` cites API code by pinned SHA, cross-link the matching
      API rule.

**Keeping it current**

- [ ] Add one step to `.claude/skills/pre-pr-standards/SKILL.md`: if the diff adds/moves a domain
      or endpoint, update `code-map.md`; if it changes a behavior in `domain-rules.md`, update the
      rule. Not a new FA rule.

**Follow-on**

- [ ] File the grandfathered-divergences ticket (or note in the PR that there are none).

### fluent-ai: CLAUDE.md, routing AGENTS.md, code map, domain rules, architecture refresh

**Setup**

- [ ] Add `CLAUDE.md` containing `@AGENTS.md` (Claude Code doesn't read `AGENTS.md` on its own).
- [ ] Add `adr` to `allowed=` in `scripts/check-docs-structure.sh` (same change as
      fluent-api#361 / fluent-web#546; `docs/agents/domain.md` already says ADRs go there).
- [ ] Move the three root `greek-room-integration-*.md` files to
      `docs/features/greek-room-integration/` and fix links, so the rules can cite their final
      path.

**AGENTS.md and validation**

- [ ] Rewrite `AGENTS.md`: description ("FastAPI service + worker for AI jobs; only fluent-api
      calls it, authenticated by API key"), task routing (code map, domain rules,
      `docs/architecture.md`, README), and a "Before you finish" line with the CI commands. Say
      whether they run on the host or via `fai.sh` inside the container.
- [ ] Add "Checks before a PR" to `README.md` mirroring `pre-merge.yml` (ruff check, ruff format
      check, mypy, pytest, docs structure; note anything draft PRs skip).

**docs/architecture.md**

- [ ] Update it to match `src/app` today: keep what still holds, fix what's out of date (e.g.
      the `routers/` vs `api/v1/endpoints/` split, removed `projects` files). It stays the
      "how modules are shaped" doc; the code map is "where things are". Not a coding standard:
      no rule IDs, no enforcement.

**docs/code-map.md**

- [ ] **Outside this repo**: fluent-api is the only caller (API keys, admin router), callbacks to
      the API, model providers in `core/ai_clients`, Greek Room, TTS providers, own DB schema
      with no reads of `public` (link `api-data-dependencies.md`).
- [ ] **App shell**: `main.py`, config, middleware, logging, errors.
- [ ] **HTTP**: `api/v1/endpoints/*` and `routers/*`, saying which is current.
- [ ] **Worker and jobs**: `worker/`, job types (suggestions, pericope headings, repeated words,
      TTS clips), stats endpoint.
- [ ] **Services, CRUD, models, DB/migrations/seeds**.

**docs/domain-rules.md**

Same header and legend as fluent-api's. Candidate sections, to confirm against the code:

- [ ] **Auth**: API-key creation/hashing/rotation, admin endpoints, what's unauthenticated
      (health).
- [ ] **Jobs**: enqueue → claim → process → callback; retries, failure states, idempotency, what
      the stats/alerting endpoint counts (link `docs/features/ai-jobs-health`).
- [ ] **Data ownership**: no reads of API-owned tables; anything needed comes over HTTP.
- [ ] **Content protection**: Bible text sent to model providers, TTS licence fence and clip
      reuse (link `docs/features/source-tts`), what may be cached.
- [ ] **Greek Room**: decisions from the moved integration docs.
- [ ] Python tests cite as `tests/...::test_name`.

**Keeping it current**

- [ ] `AGENTS.md`'s "Before you finish" line also says: update `code-map.md` / `domain-rules.md`
      when the change affects them (`.claude/` is gitignored here, so no skill).

**Follow-on**

- [ ] File the grandfathered-divergences ticket (or note in the PR that there are none).

## Spotted in fluent-web (not in scope, worth a one-liner)

fluent-web has no `CLAUDE.md`, so Claude Code sessions there don't load `AGENTS.md` unless a
parent directory's `CLAUDE.md` happens to. Same one-line fix as the fluent-ai ticket.
