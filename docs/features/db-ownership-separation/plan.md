# DB Ownership Separation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status (2026-06-09): IMPLEMENTED** on branch `task/refactor-from-cross-schema-reads` across `fluent-api`, `fluent-ai`, and `fluent-platform`. Verified via standalone + ecosystem Docker bring-up (four schemas with correct owners, all four roles, `ai_user` denied on `public`, both services healthy). One deviation from the steps below: the AI **standalone DB port was unified to 5432** (this plan originally specified 5433) so the AI aligns with the API/platform — run one stack at a time.

**Goal:** Make `fluent-api` and `fluent-ai` each own their own database concern — their own login users, their own migration user, their own schema(s), their own provisioning — inside one shared Postgres database, with zero cross-schema reads and identical standup whether run standalone or via `fluent-platform`.

**Architecture:** One Postgres database (`fluent`) in every mode, mirroring prod as it exists today. The API owns the `public` + `pgboss` + `drizzle` schemas; the AI owns the `ai` schema. Each service has a least-privilege runtime role and a separate migration role. Each service runs **one idempotent bootstrap** (create its own roles/schema/grants) from its entrypoint, using a privileged bootstrap URL, *before* running its own migrations — so the same mechanism works against a service-owned standalone Postgres or the platform's shared Postgres. AI no longer reads any API table directly; those reads are documented for later replacement with HTTP calls (API↔AI is already HTTP via `FLUENT_AI_URL`). pg-boss is API-internal.

**Tech Stack:** PostgreSQL 16, Drizzle ORM + drizzle-kit (API, TypeScript/tsx), Alembic + SQLAlchemy async + asyncpg (AI, Python/uv), Docker Compose / Podman, helper shell scripts.

---

## Conventions (read first — used by every task)

### Roles (created by bootstrap; dev passwords are all `password`)

| Service | Migration role (DDL, owns schema) | Runtime role (least-privilege DML) |
|---|---|---|
| API | `api_migrator` | `api_user` |
| AI  | `ai_migrator`  | `ai_user`  |

All cross-schema reading roles from the old model (`role_ai_reader`, `web_user`, `ai_user`'s public grant, the `role_*` group roles) are **removed**. Neither service's roles have any privilege on the other's schema.

### Connection-URL environment variables (single source of truth)

Each service reads three URLs. The bootstrap script parses the runtime + migration URLs to learn which roles/passwords to create, so the URLs are authoritative.

| Var | Used by | Connects as |
|---|---|---|
| `BOOTSTRAP_DATABASE_URL` | bootstrap script only | `postgres` superuser |
| `MIGRATIONS_DATABASE_URL` | migrations only (drizzle-kit / Alembic) | the migration role |
| `DATABASE_URL` | the running app | the runtime role |

"Detection" is pure env convention: standalone compose and the platform compose each inject these three for the service; the app code only ever reads `DATABASE_URL`. No app-side discovery logic.

### Startup order (both services' entrypoints)

```
bootstrap (BOOTSTRAP_DATABASE_URL, superuser)  →  migrate (MIGRATIONS_DATABASE_URL)  →  seed  →  run app (DATABASE_URL)
```

### Important: requires a fresh DB volume

Ownership/role changes apply at provisioning time. Before verifying any mode, reset the volume (`./fapi.sh clean`, `./fai.sh clean`, or `./fluent.sh clean`). All verification steps below assume a clean volume.

---

## Phase A — fluent-api owns its DB

Work in the `fluent-api` repo.

### Task A1: Create the API bootstrap script

**Files:**
- Create: `fluent-api/src/db/scripts/bootstrap.ts`

- [ ] **Step 1: Write the bootstrap script**

```typescript
// src/db/scripts/bootstrap.ts
// Idempotent DB provisioning for the API's own concern.
// Connects as the postgres superuser (BOOTSTRAP_DATABASE_URL) and creates the
// API's migration + runtime roles, its schemas, ownership, and default grants.
// Runs identically against a standalone or platform-shared Postgres.
import postgres from 'postgres';

function parse(url: string): { user: string; password: string } {
  const u = new URL(url);
  return { user: decodeURIComponent(u.username), password: decodeURIComponent(u.password) };
}

const bootstrapUrl = process.env.BOOTSTRAP_DATABASE_URL;
const runtimeUrl = process.env.DATABASE_URL;
const migrationsUrl = process.env.MIGRATIONS_DATABASE_URL;

if (!bootstrapUrl || !runtimeUrl || !migrationsUrl) {
  throw new Error('bootstrap requires BOOTSTRAP_DATABASE_URL, DATABASE_URL, MIGRATIONS_DATABASE_URL');
}

const runtime = parse(runtimeUrl);
const migrator = parse(migrationsUrl);

async function main() {
  const sql = postgres(bootstrapUrl, { max: 1 });
  try {
    // Roles (CREATE ROLE has no IF NOT EXISTS — guard with DO blocks).
    for (const role of [migrator, runtime]) {
      await sql.unsafe(`
        DO $$ BEGIN
          IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${role.user}') THEN
            CREATE ROLE ${role.user} LOGIN PASSWORD '${role.password}';
          ELSE
            ALTER ROLE ${role.user} LOGIN PASSWORD '${role.password}';
          END IF;
        END $$;
      `);
    }

    // Migrator owns DDL surfaces; allow it to create the drizzle tracking schema.
    await sql.unsafe(`ALTER SCHEMA public OWNER TO ${migrator.user};`);
    await sql.unsafe(`GRANT CREATE ON DATABASE ${new URL(bootstrapUrl).pathname.slice(1)} TO ${migrator.user};`);

    // pgboss is API-internal; runtime role owns it so pg-boss can manage it.
    await sql.unsafe(`CREATE SCHEMA IF NOT EXISTS pgboss AUTHORIZATION ${runtime.user};`);

    // Runtime role can use public and gets DML on everything the migrator creates there.
    await sql.unsafe(`GRANT USAGE ON SCHEMA public TO ${runtime.user};`);
    await sql.unsafe(`
      ALTER DEFAULT PRIVILEGES FOR ROLE ${migrator.user} IN SCHEMA public
        GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${runtime.user};
    `);
    await sql.unsafe(`
      ALTER DEFAULT PRIVILEGES FOR ROLE ${migrator.user} IN SCHEMA public
        GRANT USAGE, SELECT ON SEQUENCES TO ${runtime.user};
    `);
    // Cover any tables already present from a prior migrate in this volume.
    await sql.unsafe(`GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${runtime.user};`);
    await sql.unsafe(`GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${runtime.user};`);

    console.log('API bootstrap complete: roles, schemas, grants ensured.');
  } finally {
    await sql.end();
  }
}

main().catch((err) => {
  console.error('API bootstrap failed:', err);
  process.exit(1);
});
```

- [ ] **Step 2: Commit**

```bash
git add src/db/scripts/bootstrap.ts
git commit -m "feat(db): add idempotent API bootstrap script"
```

### Task A2: Point drizzle-kit at the migration role

**Files:**
- Modify: `fluent-api/drizzle.config.ts`

- [ ] **Step 1: Use MIGRATIONS_DATABASE_URL for migrations**

```typescript
// drizzle.config.ts — change only the url line:
  dbCredentials: {
    url: process.env.MIGRATIONS_DATABASE_URL ?? process.env.DATABASE_URL!,
  },
```

- [ ] **Step 2: Commit**

```bash
git add drizzle.config.ts
git commit -m "chore(db): run drizzle migrations as the migration role"
```

### Task A3: Wire bootstrap into the entrypoint

**Files:**
- Modify: `fluent-api/docker-entrypoint.sh`

- [ ] **Step 1: Run bootstrap before migrate**

```sh
#!/bin/sh
set -e

echo "Bootstrapping database roles/schemas..."
npx tsx src/db/scripts/bootstrap.ts || { echo "ERROR: db bootstrap failed"; exit 1; }

echo "Running database migrations..."
npx drizzle-kit migrate || { echo "ERROR: database migrations failed"; exit 1; }

echo "Seeding roles..."
npx tsx src/db/seeds/roles.ts || { echo "ERROR: roles seed failed"; exit 1; }

echo "Seeding RBAC data..."
npx tsx src/db/seeds/rbac.ts || { echo "ERROR: RBAC seed failed"; exit 1; }

echo "Starting dev server..."
exec npx tsx watch src/index.ts
```

- [ ] **Step 2: Commit**

```bash
git add docker-entrypoint.sh
git commit -m "feat(db): bootstrap roles/schemas before API migrations"
```

### Task A4: Update standalone compose + env, delete legacy init SQL

**Files:**
- Modify: `fluent-api/compose.yaml`
- Modify: `fluent-api/.env.example`
- Delete: `fluent-api/db/init/01-init-db.sql`
- Delete: `fluent-api/db/init/01-api.sql`

- [ ] **Step 1: Remove the init mount and set per-role URLs in compose**

In `fluent-api/compose.yaml`, under the `db` service remove the init mount line:

```yaml
    volumes:
      - fluent-pgdata:/var/lib/postgresql/data
      # (deleted) - ./db/init:/docker-entrypoint-initdb.d:ro
```

In both the `api` and `worker` services, replace the single `DATABASE_URL` env with the three URLs (host `db`):

```yaml
    environment:
      BOOTSTRAP_DATABASE_URL: postgres://postgres:postgres@db:5432/fluent
      MIGRATIONS_DATABASE_URL: postgres://api_migrator:password@db:5432/fluent
      DATABASE_URL: postgres://api_user:password@db:5432/fluent
      EXPORTS_DIR: /app/exports
```

- [ ] **Step 2: Update `.env.example`** — replace the single DB line with:

```sh
# Runtime (least-privilege) role used by the app:
DATABASE_URL=postgres://api_user:password@localhost:5432/fluent
# Migration role (DDL) used by drizzle-kit:
MIGRATIONS_DATABASE_URL=postgres://api_migrator:password@localhost:5432/fluent
# Superuser used only by the bootstrap script:
BOOTSTRAP_DATABASE_URL=postgres://postgres:postgres@localhost:5432/fluent
```

- [ ] **Step 3: Delete the legacy init scripts**

```bash
git rm db/init/01-init-db.sql db/init/01-api.sql
```

- [ ] **Step 4: Commit**

```bash
git add compose.yaml .env.example
git commit -m "refactor(db): API provisions via bootstrap+migrations, drop init SQL"
```

### Task A5: Verify standalone API

- [ ] **Step 1: Clean and bring up**

Run: `./fapi.sh clean && ./fapi.sh up`
Expected: container logs show `API bootstrap complete`, migrations applied, server starts.

- [ ] **Step 2: Assert roles exist and runtime role has no superuser**

Run:
```bash
./fapi.sh shell db -c "\du api_user api_migrator"
```
Expected: both roles listed; `api_user` has no `Superuser`/`Create role` attributes.

- [ ] **Step 3: Assert the app works as api_user**

Run: `curl -f http://localhost:9999/health`
Expected: HTTP 200. (Confirms api_user can read/write public incl. BetterAuth tables.)

- [ ] **Step 4: Commit (no code change; verification only)** — proceed to Phase B.

---

## Phase B — fluent-ai owns its DB and stops reading API tables

Work in the `fluent-ai` repo.

### Task B1: Document the AI → API-table read dependencies (deliverable)

**Files:**
- Create: `fluent-ai/docs/api-data-dependencies.md`

- [ ] **Step 1: Write the dependency doc**

```markdown
# API Data Dependencies (to be served via HTTP, not cross-schema reads)

As of the DB-ownership separation, `fluent-ai` no longer has any read access to
API-owned (`public`) tables. The following code read API tables directly and was
removed. Each item must be re-implemented as an HTTP call to the fluent-api
(authenticated via the service principal / `FLUENT_AI_URL`) when the feature
that needs it is built.

| Data needed | Old direct-read site (removed) | Replacement |
|---|---|---|
| `public.projects` list | `src/app/crud/projects.py::get_projects` via `internal/project.py` (`Project(ExternalBase)`) | `GET /projects` on fluent-api |
| Single project | (scaffolded in `routers/projects.py`) | `GET /projects/{id}` on fluent-api |

Removed supporting code: `src/app/internal/project.py`, `src/app/crud/projects.py`,
`src/app/routers/projects.py`, `src/app/schemas/projects.py` (DTOs — keep a copy
if reused as the HTTP response model), and the `ExternalBase` class in
`src/app/db/base.py`.

No other `public`/operational table was read by this service at separation time.
```

- [ ] **Step 2: Commit**

```bash
git add docs/api-data-dependencies.md
git commit -m "docs(ai): record API-table reads to migrate to HTTP"
```

### Task B2: Remove cross-schema read code

**Files:**
- Delete: `fluent-ai/src/app/internal/project.py`
- Delete: `fluent-ai/src/app/crud/projects.py`
- Delete: `fluent-ai/src/app/routers/projects.py`
- Delete: `fluent-ai/src/app/schemas/projects.py`
- Modify: `fluent-ai/src/app/main.py` (remove projects router import + include)
- Modify: `fluent-ai/src/app/db/base.py` (remove `ExternalBase`)

- [ ] **Step 1: Delete the read modules**

```bash
git rm src/app/internal/project.py src/app/crud/projects.py \
       src/app/routers/projects.py src/app/schemas/projects.py
```

- [ ] **Step 2: Remove the projects router from `main.py`**

Remove the line `from app.routers import projects` and the line
`app.include_router(projects.router, tags=["projects"])`.

- [ ] **Step 3: Remove `ExternalBase` from `src/app/db/base.py`**

Delete the `ExternalBase` class and its docstring references, leaving only
`OwnedBase` and the owned-model import. The file's module docstring should no
longer mention external/public models.

- [ ] **Step 4: Verify nothing else references the removed names**

Run: `grep -rn "ExternalBase\|crud.projects\|routers import projects\|schemas.projects" src`
Expected: no matches.

- [ ] **Step 5: Run the test suite**

Run: `./fai.sh test`
Expected: PASS (no import errors from removed modules). Fix/remove any test that imported them.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(ai): remove all cross-schema reads of public tables"
```

### Task B3: Create the AI bootstrap script

**Files:**
- Create: `fluent-ai/scripts/bootstrap.py`

- [ ] **Step 1: Write the bootstrap script**

```python
# scripts/bootstrap.py
# Idempotent DB provisioning for the AI's own concern.
# Connects as the postgres superuser (BOOTSTRAP_DATABASE_URL) and creates the
# AI's migration + runtime roles, the `ai` schema, ownership, and default grants.
# Grants NO access to the public schema — the AI must use HTTP for API data.
import asyncio
import os
from urllib.parse import urlparse, unquote

import asyncpg


def _plain_dsn(url: str) -> str:
    # asyncpg wants a plain postgres:// DSN, not the SQLAlchemy +asyncpg form.
    return url.replace("postgresql+asyncpg://", "postgresql://").replace(
        "postgres+asyncpg://", "postgresql://"
    )


def _creds(url: str) -> tuple[str, str]:
    p = urlparse(_plain_dsn(url))
    return unquote(p.username or ""), unquote(p.password or "")


async def main() -> None:
    bootstrap_url = os.environ["BOOTSTRAP_DATABASE_URL"]
    runtime_user, runtime_pw = _creds(os.environ["DATABASE_URL"])
    migrator_user, migrator_pw = _creds(os.environ["MIGRATIONS_DATABASE_URL"])

    conn = await asyncpg.connect(_plain_dsn(bootstrap_url))
    try:
        for user, pw in ((migrator_user, migrator_pw), (runtime_user, runtime_pw)):
            await conn.execute(
                f"""
                DO $$ BEGIN
                  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '{user}') THEN
                    CREATE ROLE {user} LOGIN PASSWORD '{pw}';
                  ELSE
                    ALTER ROLE {user} LOGIN PASSWORD '{pw}';
                  END IF;
                END $$;
                """
            )

        await conn.execute(f"CREATE SCHEMA IF NOT EXISTS ai AUTHORIZATION {migrator_user};")
        await conn.execute(f"GRANT USAGE ON SCHEMA ai TO {runtime_user};")
        await conn.execute(
            f"ALTER DEFAULT PRIVILEGES FOR ROLE {migrator_user} IN SCHEMA ai "
            f"GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {runtime_user};"
        )
        await conn.execute(
            f"ALTER DEFAULT PRIVILEGES FOR ROLE {migrator_user} IN SCHEMA ai "
            f"GRANT USAGE, SELECT ON SEQUENCES TO {runtime_user};"
        )
        # Cover any tables already present from a prior migrate in this volume.
        await conn.execute(
            f"GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ai TO {runtime_user};"
        )
        await conn.execute(
            f"GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ai TO {runtime_user};"
        )
        print("AI bootstrap complete: ai schema, roles, grants ensured (no public access).")
    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
```

- [ ] **Step 2: Commit**

```bash
git add scripts/bootstrap.py
git commit -m "feat(db): add idempotent AI bootstrap script (ai schema only)"
```

### Task B4: Wire bootstrap into the AI entrypoint + fix runtime user docstring

**Files:**
- Modify: `fluent-ai/docker-entrypoint.sh`
- Modify: `fluent-ai/src/app/database.py` (docstring only)

- [ ] **Step 1: Run bootstrap before Alembic**

```sh
#!/usr/bin/env sh
set -e

if [ "${SKIP_DB_BOOTSTRAP:-0}" != "1" ]; then
  echo ">>> Bootstrapping ai schema/roles..."
  PYTHONPATH=/app/src uv run python scripts/bootstrap.py

  echo ">>> Applying ai-schema migrations (alembic upgrade head)..."
  uv run alembic upgrade head

  echo ">>> Running ai-schema seeds..."
  PYTHONPATH=/app/src uv run python -m app.db.seeds
fi

exec uv run fastapi dev src/app/main.py --host 0.0.0.0 --port 8200
```

- [ ] **Step 2: Fix the `database.py` docstring** — replace the role description block with:

```python
"""
database.py — Async SQLAlchemy engine and session management.

The AI service connects as `ai_user`:
  - Full DML on the `ai` schema (its own data only).
  - No access to any other schema. API data is fetched over HTTP, never via SQL.
"""
```

- [ ] **Step 3: Mount `scripts/` into the AI container (standalone)** — confirm `fluent-ai/compose.yaml` already mounts `./scripts:/app/scripts:ro` (it does). No change if present.

- [ ] **Step 4: Commit**

```bash
git add docker-entrypoint.sh src/app/database.py
git commit -m "feat(db): bootstrap ai schema before migrations; ai_user is ai-only"
```

### Task B5: Update AI standalone compose + env, delete legacy init SQL

**Files:**
- Modify: `fluent-ai/compose.yaml`
- Modify: `fluent-ai/.env.example`
- Delete: `fluent-ai/db/init/01-ai.sql`

- [ ] **Step 1: Remove the init mount in `compose.yaml`** under the `db` service:

```yaml
    volumes:
      - fluent-pgdata:/var/lib/postgresql/data
      # (deleted) - ./db/init:/docker-entrypoint-initdb.d
```

- [ ] **Step 2: Add the three URLs to the `ai` service env in `compose.yaml`** (host `db`, port 5432 inside the network):

```yaml
    environment:
      ENVIRONMENT: development
      DEBUG: "true"
      UV_CACHE_DIR: /tmp/.uv-cache
      BOOTSTRAP_DATABASE_URL: postgresql://postgres:postgres@db:5432/fluent
      MIGRATIONS_DATABASE_URL: postgresql+asyncpg://ai_migrator:password@db:5432/fluent
      DATABASE_URL: postgresql+asyncpg://ai_user:password@db:5432/fluent
```

- [ ] **Step 3: Update `.env.example`** — replace the DB block with:

```sh
# Runtime role (ai schema only):
DATABASE_URL=postgresql+asyncpg://ai_user:password@localhost:5432/fluent
# Migration role (DDL on ai):
MIGRATIONS_DATABASE_URL=postgresql+asyncpg://ai_migrator:password@localhost:5432/fluent
# Superuser used only by the bootstrap script:
BOOTSTRAP_DATABASE_URL=postgresql://postgres:postgres@localhost:5432/fluent
```

- [ ] **Step 4: Delete legacy init script**

```bash
git rm db/init/01-ai.sql
```

- [ ] **Step 5: Commit**

```bash
git add compose.yaml .env.example
git commit -m "refactor(db): AI provisions via bootstrap+alembic, drop init SQL"
```

### Task B6: Verify standalone AI

- [ ] **Step 1: Clean and bring up**

Run: `./fai.sh clean && ./fai.sh up`
Expected: logs show `AI bootstrap complete`, `alembic upgrade head` succeeds, server starts.

- [ ] **Step 2: Assert ai_user cannot read public**

Run:
```bash
./fai.sh shell db
# then in psql:
SET ROLE ai_user;
SELECT * FROM public.users LIMIT 1;
```
Expected: `ERROR: permission denied for schema public` (or relation does not exist — in standalone the AI DB has no public app tables at all). Either confirms no cross-schema read.

- [ ] **Step 3: Assert ai_user can use its own schema**

In the same psql session:
```sql
SET ROLE ai_user;
SELECT * FROM ai.api_keys LIMIT 1;
```
Expected: returns rows / empty set, NOT a permission error.

- [ ] **Step 4: Health check**

Run: `curl -f http://localhost:8200/health`
Expected: HTTP 200. Proceed to Phase C.

---

## Phase C — fluent-platform brings up both with separation

Work in the `fluent-platform` repo.

### Task C1: Rewrite the platform compose env injection

**Files:**
- Modify: `fluent-platform/compose.yaml`

- [ ] **Step 1: Set per-service URLs; remove the old shared/cross-schema env**

In the `api` and `worker` services, replace the `DATABASE_URL` line with the three URLs:

```yaml
      BOOTSTRAP_DATABASE_URL: postgres://postgres:postgres@db:5432/fluent
      MIGRATIONS_DATABASE_URL: postgres://api_migrator:password@db:5432/fluent
      DATABASE_URL: postgres://api_user:password@db:5432/fluent
```

In the `ai` service, replace the `DATABASE_URL` + `MIGRATIONS_DATABASE_URL` block (and delete the old comments about the `migrations` role hack) with:

```yaml
      BOOTSTRAP_DATABASE_URL: postgresql://postgres:postgres@db:5432/fluent
      MIGRATIONS_DATABASE_URL: postgresql+asyncpg://ai_migrator:password@db:5432/fluent
      DATABASE_URL: postgresql+asyncpg://ai_user:password@db:5432/fluent
```

Keep `FLUENT_AI_URL: http://ai:8200` on the `api` service unchanged.

- [ ] **Step 2: Confirm the shared `db` service mounts no init dir** — the platform `db` service already has no `docker-entrypoint-initdb.d` mount (its `db/init/` is README-only). Leave it superuser-only.

- [ ] **Step 3: Commit**

```bash
git add compose.yaml
git commit -m "refactor(platform): inject per-service DB roles; drop cross-schema env"
```

### Task C2: Confirm platform DB README reflects reality

**Files:**
- Modify: `fluent-platform/db/init/README.md`

- [ ] **Step 1: Update the "Shared resources" paragraph** — pg-boss is now API-internal, not cross-service. Replace it with:

```markdown
## Shared resources

There are **no cross-service shared schemas**. The API owns `public`, `pgboss`,
and `drizzle`; the AI owns `ai`. Services communicate over HTTP (`FLUENT_AI_URL`),
never by reading each other's tables. pg-boss is the API's internal job queue.
```

- [ ] **Step 2: Commit**

```bash
git add db/init/README.md
git commit -m "docs(platform): pgboss is API-internal; no shared schemas"
```

### Task C3: Verify ecosystem mode

- [ ] **Step 1: Clean and bring up the full stack**

Run: `./fluent.sh clean && ./fluent.sh up`
Expected: `db` healthy; `api` logs `API bootstrap complete` + migrations; `ai` logs `AI bootstrap complete` + alembic; `web` starts.

- [ ] **Step 2: Assert both schemas + all four roles exist in the one DB**

Run:
```bash
./fluent.sh db:psql -c "\dn"          # schemas: public, pgboss, drizzle, ai
./fluent.sh db:psql -c "\du"          # roles: api_user, api_migrator, ai_user, ai_migrator
```
Expected: all listed.

- [ ] **Step 3: Assert AI cannot read API data in the shared DB**

Run:
```bash
./fluent.sh db:psql
SET ROLE ai_user;
SELECT * FROM public.users LIMIT 1;
```
Expected: `ERROR: permission denied for schema public`.

- [ ] **Step 4: Assert services are healthy**

Run: `curl -f http://localhost:9999/health && curl -f http://localhost:8200/health`
Expected: both HTTP 200. Proceed to Phase D.

---

## Phase D — helper scripts and documentation

### Task D1: Update DB commands in the helper scripts

**Files:**
- Modify: `fluent-platform/fluent.sh` and `fluent-platform/fluent.ps1`
- Modify: `fluent-api/fapi.sh` (+ `.ps1` if present)
- Modify: `fluent-ai/fai.sh` (+ `.ps1` if present)

- [ ] **Step 1: Remove any `db:init` step that ran the old shared init SQL**

Find db-init logic: `grep -nE "init-db|db:init|docker-entrypoint-initdb|01-init" fluent-platform/fluent.sh fluent-api/fapi.sh fluent-ai/fai.sh`
Each service now self-provisions on container start (bootstrap → migrate → seed). Remove or repoint any `db:init` command so it simply (re)starts the service container, which provisions itself. Keep `db:migrate`, `db:seed`, `db:psql` working against the running DB.

- [ ] **Step 2: Verify the script help text matches** — update any usage/README strings the scripts print that mention a separate init step.

- [ ] **Step 3: Commit (per repo)**

```bash
git commit -am "chore(scripts): services self-provision; drop shared db:init"
```

### Task D2: Update architecture docs to the new model

**Files:**
- Modify: `fluent-api/ARCHITECTURE.md` (Repository Access Patterns / cross-domain — unchanged; but any DB-ownership text)
- Modify: `fluent-ai/AGENTS.md` (the "Database Ownership" + "Reading an external (read-only) table" sections)
- Modify: `fluent-platform/README.md` (the "Database Architecture" table)

- [ ] **Step 1: fluent-ai/AGENTS.md** — replace the "Database Ownership" section so it states: the AI owns only the `ai` schema (Alembic + Python seeds); it has no access to any other schema; API data is fetched via HTTP (`FLUENT_AI_URL`), see `docs/api-data-dependencies.md`. **Delete** the "Reading an external (read-only) table" subsection and any `ExternalBase` mention.

- [ ] **Step 2: fluent-platform/README.md** — replace the "Database Architecture" schema-ownership table with the new model:

```markdown
The platform runs one shared PostgreSQL database (`fluent`). Each service owns its
own roles, schemas, and migrations and provisions itself on startup (bootstrap →
migrate → seed). There are no cross-schema reads.

| Schema    | Owner / migrator | Runtime role | Notes                         |
|-----------|------------------|--------------|-------------------------------|
| public    | api_migrator     | api_user     | Core API data (Drizzle)       |
| pgboss    | api_user         | api_user     | API-internal job queue        |
| drizzle   | api_migrator     | api_migrator | Drizzle migration tracking    |
| ai        | ai_migrator      | ai_user      | AI service data (Alembic)     |

Services communicate over HTTP (`FLUENT_AI_URL`), never by reading each other's tables.
```

- [ ] **Step 3: fluent-api ARCHITECTURE.md** — if it asserts anything about a shared multi-schema/cross-read DB model, update to: API owns `public`/`pgboss`/`drizzle`; least-privilege `api_user` at runtime, `api_migrator` for DDL.

- [ ] **Step 4: Commit (per repo)**

```bash
git commit -am "docs: describe per-service DB ownership, no cross-schema reads"
```

### Task D3: Final end-to-end verification matrix

- [ ] **Step 1: Standalone API** — `./fapi.sh clean && ./fapi.sh up`; `curl -f localhost:9999/health` → 200.
- [ ] **Step 2: Standalone AI** — `./fai.sh clean && ./fai.sh up`; `curl -f localhost:8200/health` → 200; `ai_user` cannot read public (Task B6 Step 2).
- [ ] **Step 3: Ecosystem** — `./fluent.sh clean && ./fluent.sh up`; both health checks 200; schemas/roles present; `ai_user` denied on `public` (Task C3 Step 3).
- [ ] **Step 4: Grep guard** — `grep -rn "role_ai_reader\|ExternalBase\|01-init-db" fluent-api fluent-ai fluent-platform` → no matches (legacy model fully removed).
- [ ] **Step 5: Commit a short CHANGELOG/summary note** in `fluent-platform/docs/` if desired.

---

## Self-review notes

- **Spec coverage:** API owns DB+migrations (A1–A5); AI owns DB+migrations (B3–B6); standalone + platform standup (A4/B5/C1, verified A5/B6/C3); seamless env-convention detection (Conventions + per-mode env injection); intentionally simple single provisioning path (entrypoint bootstrap; legacy init SQL deleted A4/B5); separate users + separate migration users (Conventions, bootstrap scripts); AI cross-schema reads removed + **documented** per user request (B1 deliverable + B2); pg-boss API-internal (C2). 
- **Out of scope (explicit):** corpus store, publish-promotion workflow, mediated-access read/command endpoints (separate Approach-D app work; see `architecture-approach-d-mediated-access.md`).
- **Type/name consistency:** role names `api_user`/`api_migrator`/`ai_user`/`ai_migrator` and env vars `BOOTSTRAP_/MIGRATIONS_/DATABASE_URL` are used identically across all tasks.
- **Assumption to confirm at execution:** fresh DB volumes are used (ownership/role changes are provisioning-time); all verify steps `clean` first.
```
