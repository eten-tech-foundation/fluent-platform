# Align `provision-db.ts` (dev/qa) with the DB ownership separation model

> **Status: IN REVIEW** — [fluent-api#322](https://github.com/eten-tech-foundation/fluent-api/pull/322).
> Tasks 1–5 implemented; CodeRabbit's first review round (4 actionable + 1
> nitpick) addressed and replied to on the PR. Task 6 (live verification
> against Azure dev/qa) and the outstanding docs guide below remain.

**Parent feature:** [`db-ownership-separation`](../plan.md) — implemented for local
Docker (standalone + platform) via `bootstrap.ts` (fluent-api) and
`bootstrap.py` (fluent-ai). This ticket closes the gap for the dev/qa Azure
path, which was out of scope for the original plan and still runs the
pre-separation role model.

**Repo:** `fluent-api` (`src/db/scripts/provision-db.ts` and its supporting
env-config/docs). No changes needed in `fluent-ai` or `fluent-platform` —
see Scope decision below.

## Problem

`provision-db.ts` provisions the shared dev/qa Azure Postgres database, but
it still implements the role model the parent plan replaced:

| | Local (bootstrap.ts / bootstrap.py) | Dev/QA (provision-db.ts, current) |
|---|---|---|
| Roles | 4 flat login roles: `api_migrator`, `api_user`, `ai_migrator`, `ai_user` | 5 NOLOGIN group roles + 4 login roles (`db_admin`, `migrations`, `web_user`, `ai_user`) |
| Migration user(s) | Separate per service | One shared `migrations` login does DDL across every schema |
| API runtime role name | `api_user` | `web_user` |
| AI → `public` access | None — denied | `ai_user` holds `role_ai_reader`: `SELECT` on all of `public` |
| Persistent admin | None (bootstrap runs transiently as the Postgres superuser) | `db_admin` login persists with `CREATEROLE` |

The `role_ai_reader` grant means AI retains full read access to API-owned
data in dev and qa — the exact cross-schema read the parent plan eliminated
locally. Dev/qa is currently *less* isolated than local, which is backwards:
these are the environments closest to prod.

## Scope decision

Two ways to close this gap:

1. **Single script, corrected roles** — keep one script in `fluent-api`
   provisioning both schemas for dev/qa, but replace the group-role /
   `db_admin` / `role_ai_reader` model with the plan's
   `api_migrator`/`api_user`/`ai_migrator`/`ai_user` roles and zero
   cross-schema grants.
2. **Full split** — move AI's dev/qa provisioning into a new script in
   `fluent-ai`, mirroring the local `bootstrap.py`/`bootstrap.ts` split.

**Decision: (1).** Full split touches two repos and the deployment pipeline
that invokes `provision-db.ts` today, for no isolation benefit beyond what
(1) already achieves — the resulting grants are identical either way, only
which process issues the DDL differs. Revisit if `fluent-ai` ever gets its
own dev/qa deploy pipeline independent of `fluent-api`'s.

## Target role model (dev/qa, matching bootstrap.ts / bootstrap.py)

| Role | Type | Owns / granted on | Notes |
|---|---|---|---|
| `api_migrator` | LOGIN | Owns `public`, `drizzle`; `CREATE` on database | DDL for API schemas only |
| `api_user` | LOGIN | DML on `public` (via default privileges from `api_migrator`); owns `pgboss` | Runtime role; pg-boss manages its own schema |
| `ai_migrator` | LOGIN | Owns `ai` | DDL for AI schema only |
| `ai_user` | LOGIN | DML on `ai` (via default privileges from `ai_migrator`) | Runtime role; **no grant on `public`** |

No NOLOGIN group roles, no `db_admin`, no shared `migrations` login,
no `role_ai_reader`. This is the same shape as `bootstrap.ts` — the dev/qa
script differs only in (a) provisioning both services' roles in one pass
since one Azure DB backs both, and (b) the Azure-specific ownership
reassignment / bootstrap-user-role-grant logic that already exists in
`provision-db.ts` for non-superuser hosts (`azure_pg_admin`).

## Tasks

### Task 1: Rewrite the role/grant logic in `provision-db.ts`

**File:** `fluent-api/src/db/scripts/provision-db.ts`

- [x] Remove the group-role layer entirely: delete `role_web_data`,
      `role_ai_data`, `role_ai_reader`, `role_pgboss_user`, `role_migrations`
      and the `ensureGroupRole`/`grantRole`-to-login-role plumbing built
      around them.
- [x] Replace the 4 login roles with `api_migrator`, `api_user`,
      `ai_migrator`, `ai_user` (drop `db_admin` and `migrations`).
- [x] Schema ownership: `public` and `drizzle` → `api_migrator`; `ai` →
      `ai_migrator`; `pgboss` → `api_user` (`AUTHORIZATION`, matching
      `bootstrap.ts`'s pgboss-owned-by-runtime-role contract in
      `queue.ts`).
- [x] Schema-level grants: `api_user` gets `USAGE` + DML on `public` only;
      `ai_user` gets `USAGE` + DML on `ai` only. **No grant of any kind for
      `ai_user` on `public`, and none for `api_user` on `ai`.**
- [x] `api_migrator` gets `USAGE, CREATE` on `public`/`drizzle`/`pgboss`
      only (not `ai`); `ai_migrator` gets `USAGE, CREATE` on `ai` only (not
      `public`/`drizzle`/`pgboss`). Each also needs `CREATE ON DATABASE`
      only if its own migration tool requires it (drizzle-kit's
      `CREATE SCHEMA IF NOT EXISTS drizzle` check — Alembic does not need
      this).
- [x] Bootstrap-user role grants (the Azure `azure_pg_admin` workaround at
      the end of step 3): grant `api_migrator` and `ai_migrator` to the
      connecting bootstrap user instead of `db_admin`/`migrations`, so
      `ALTER DEFAULT PRIVILEGES FOR ROLE <role>` still succeeds on
      non-superuser hosts.
- [x] Ownership reassignment of pre-existing objects (current step 6):
      split by schema — `public`/`drizzle` tables/sequences/views/enums →
      owner `api_migrator`; `ai` schema objects → owner `ai_migrator`.
      `pgboss` is excluded (already owned by `api_user`, unchanged).
- [x] Default privileges (current step 7): mirror `bootstrap.ts`/
      `bootstrap.py` — `ALTER DEFAULT PRIVILEGES FOR ROLE api_migrator IN
      SCHEMA public/drizzle GRANT ... TO api_user`, and `FOR ROLE
      ai_migrator IN SCHEMA ai GRANT ... TO ai_user`. Drop every default-
      privilege statement that touches `role_ai_reader` or the old
      `role_web_data`/`role_ai_data` names.
- [x] Update the file's header comment (lines 1–52) to describe the new
      model instead of the old one.

### Task 2: Update `DbProvisionConfig` and env-configs

**Files:**
- `fluent-api/src/db/env-configs/types.ts`
- `fluent-api/src/db/env-configs/dev.ts`
- `fluent-api/src/db/env-configs/qa.ts`

- [x] Replace `dbAdminPassword`/`migrationsPassword`/`webUserPassword` in
      `DbProvisionConfig` with `apiMigratorPassword`/`apiUserPassword`/
      `aiMigratorPassword` (keep `aiUserPassword`).
- [x] Update `dev.ts`/`qa.ts` `provision` blocks to read
      `API_MIGRATOR_PASSWORD`, `API_USER_PASSWORD`, `AI_MIGRATOR_PASSWORD`,
      `AI_USER_PASSWORD` from env instead of `DB_ADMIN_PASSWORD`/
      `MIGRATIONS_PASSWORD`/`WEB_USER_PASSWORD`.
- [x] Update `provision-db.ts`'s `main()` required-vars block (currently
      `DB_ADMIN_PASSWORD`/`MIGRATIONS_PASSWORD`/`WEB_USER_PASSWORD`/
      `AI_USER_PASSWORD`) to match.
- [x] **Addendum (from PR review):** removed `DEV_MIGRATIONS_DATABASE_URL`/
      `QA_MIGRATIONS_DATABASE_URL` and the `migrationsUrl` field on
      `EnvConfig` entirely — there was no reason for per-environment
      variants. `setup.ts` no longer resolves them; `MIGRATIONS_DATABASE_URL`
      is now the one variable for every environment, read directly by
      `drizzle.config.ts`, the same way `BOOTSTRAP_DATABASE_URL` already
      works.

### Task 3: Coordinate secret renames in dev/qa (outside this repo's code)

- [ ] Rotate/rename the Azure App Config or GitHub Actions secrets that
      currently hold `DB_ADMIN_PASSWORD`, `MIGRATIONS_PASSWORD`,
      `WEB_USER_PASSWORD` to `API_MIGRATOR_PASSWORD`, `API_USER_PASSWORD`,
      `AI_MIGRATOR_PASSWORD` — coordinate timing with whoever runs
      `db:provision:dev`/`db:provision:qa` so a stale secret doesn't
      silently provision the old role names. **Also drop
      `DEV_MIGRATIONS_DATABASE_URL`/`QA_MIGRATIONS_DATABASE_URL` in favor of
      a single `MIGRATIONS_DATABASE_URL`** — code no longer reads the
      per-environment variants (see Task 2 addendum above).
- [ ] Update `DEV_DATABASE_URL`/`MIGRATIONS_DATABASE_URL`/
      `QA_DATABASE_URL` app-config values to use `api_user`/`api_migrator`
      instead of `web_user`/`migrations`.
- [ ] This is a **breaking, hard-to-reverse change against shared dev/qa
      infrastructure** — run it only against a fresh/resettable dev DB
      first, and get sign-off before applying to qa. Leave the legacy
      roles (`db_admin`, `migrations`, `web_user`, `role_*`) in place until
      Task 4 — don't drop them here.

### Task 4: Clean up legacy roles and objects in dev/qa

Task 1 makes `provision-db.ts` create/reconcile the correct roles going
forward, but — consistent with the script's own "roles are created or
altered, never dropped" contract — it will not remove what it no longer
creates. Left alone, `db_admin`, `migrations`, `web_user`, and the five
`role_*` group roles keep existing in dev/qa indefinitely: unused login
roles with real (`db_admin`, `migrations`, `web_user`) or previously-real
(`role_ai_reader`) privileges are exactly the kind of drift this feature
exists to eliminate, so removing them is in scope, not cleanup-for-its-own-
sake.

**Gate:** only run this after Task 1–3 have shipped, the corrected
`db:provision:dev`/`db:provision:qa` has been run successfully at least
once, Task 5's verification passes, and app config has been cut over to the
new role names (nothing still authenticates as `db_admin`/`migrations`/
`web_user`) — dropping a role a running service still connects as takes
that service down.

**File (new):** `fluent-api/src/db/scripts/cleanup-legacy-provisioning.ts`
— a one-time script, run manually per environment (not wired into
`db:provision:*` or any entrypoint), following the same
superuser-bootstrap-connection pattern as `provision-db.ts`.

- [x] **Precondition check (script refuses to proceed if this fails):**
      query schema ownership (`pg_namespace`) and `pg_class` ownership
      (covers tables/views/materialized views/sequences/indexes) for
      `public`/`ai`/`drizzle`/`pgboss` and confirm nothing is still owned by
      `db_admin`, `migrations`, or `web_user`. **Extended per PR review:**
      also check `pg_type` (enums) and `pg_proc` (functions/procedures)
      ownership, since `pg_class` doesn't cover either — closes a gap where
      a legacy-owned object of one of those kinds could pass this
      precondition and then be silently removed by `DROP OWNED BY` below.
- [x] **Report before act:** print what each legacy role currently owns or
      has privileges on (`DROP OWNED BY <role>` with no prior `CASCADE`
      will error out naming the first blocking dependency — surface that
      instead of swallowing it) so a leftover dependency is caught, not
      silently cascaded away.
- [x] For each of `role_web_data`, `role_ai_data`, `role_ai_reader`,
      `role_pgboss_user`, `role_migrations`, `db_admin`, `migrations`,
      `web_user`: `DROP OWNED BY <role>;` (clears any remaining ACL
      entries and default-privilege catalog rows the role set, e.g. the
      `role_ai_reader` default privileges from Task 1) then `DROP ROLE
      <role>;`. Group roles first, then the login roles that held them —
      order doesn't matter for correctness (`DROP OWNED BY` doesn't
      require membership to be revoked first) but keeps the output
      legible.
- [x] Do **not** pass `CASCADE` to `DROP OWNED BY` by default — if it
      errors, that means something still depends on a legacy role that
      Task 1's reassignment missed, which needs investigating, not
      papering over.
- [ ] Run against dev first, confirm the app still passes health checks
      post-cleanup, then repeat against qa.
- [x] Commit the cleanup script (don't delete it after running — it's the
      record of what was removed and how, and gives qa/any future
      environment the same reproducible path).

### Task 5: Update `fluent-api`'s own docs

**File:** `fluent-api/docs/db-provisioning-and-setup.md`

- [x] Replace the role/group tables (group roles, role→login membership,
      the `db_admin`/`migrations`/`web_user` names) with the corrected
      4-role model.
- [x] Update all example connection strings, env var names
      (`DB_ADMIN_PASSWORD` → `API_MIGRATOR_PASSWORD`, etc.), and the
      `web_user`/`migrations` references throughout.
- [x] Update the stray comments in `src/lib/queue.ts` and
      `src/db/scripts/setup.ts` that still say "`web_user` in dev/qa,
      `api_user` locally" — after this change it's `api_user` in both.

### Task 6: Verify

- [ ] Run `db:provision:dev` against a disposable/reset dev DB. Confirm via
      `\du` that only `api_migrator`, `api_user`, `ai_migrator`, `ai_user`
      exist (plus the Azure admin) — no `db_admin`, `migrations`,
      `web_user`, or `role_*` roles.
- [ ] `SET ROLE ai_user; SELECT * FROM public.<any table> LIMIT 1;` →
      permission denied (mirrors the local `bootstrap.py` verification in
      the parent plan's Task B6).
- [ ] `SET ROLE api_user; SELECT * FROM ai.<any table> LIMIT 1;` →
      permission denied.
- [ ] Run `db:setup:dev` after provisioning and confirm migrations +
      seeds succeed as `api_migrator`/`api_user`.
- [ ] Grep guard: `grep -rn "db_admin\|role_ai_reader\|role_web_data\|role_ai_data\|role_pgboss_user\|role_migrations" fluent-api` → no matches outside git history.

## Outstanding

- [ ] **Write a concise provisioning guide for `fluent-api/docs/`**, covering
      how and when to run `provision-db.ts`, `cleanup-legacy-provisioning.ts`,
      and `setup.ts` against dev/qa — the order they run in, what each one
      assumes is already true before it runs (e.g. cleanup's precondition
      gate), and the minimum env vars each needs. `db-provisioning-and-setup.md`
      already exists as a broader reference doc; this guide should be the
      short, task-oriented "how do I actually run this" companion to it, not
      a duplicate. **Do this only after Task 6 (live verification) is done
      and the PR is passing** — writing it before the scripts are proven
      against real dev/qa risks documenting a procedure that doesn't
      actually work end-to-end.

## Out of scope

- Any change to `fluent-ai` or `fluent-platform` (per the scope decision
  above).
- Re-provisioning prod, if prod uses this same script or a hand-provisioned
  equivalent — track separately once this is verified in dev/qa.
- The mediated-access / HTTP replacement work for AI's former `public`
  reads — already tracked as out of scope in the parent plan and unaffected
  by this ticket (dev/qa's `ai_user` never had a legitimate reason to read
  `public` outside of matching the model these roles now correct).
