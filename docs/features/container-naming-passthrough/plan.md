# Container Naming & Passthrough Exec — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make repo-passthrough commands (e.g. `./fluent.sh api run db:migrate-rbac`) find the running service regardless of which tool started the stack, by exec'ing containers by stable name instead of via a directory-derived Docker Compose project.

**Architecture:** Pin deterministic, mode-scoped `container_name:` on every compose service, then change the Docker branch of each repo script's exec/shell helpers to `docker exec <container>` (mirroring the already-working Podman branch `$RUNTIME exec <container>`). This removes the Compose-project dependency entirely and unifies both runtimes onto one `<binary> exec <name>` path.

**Tech Stack:** Bash, Docker Compose v2 (`docker compose`), Podman pods, YAML compose files.

**Spec:** `docs/features/container-naming-passthrough/design.md`

---

## Repos & working directories

This plan spans three sibling repos under `/Users/kasey/code/github.com/eten-tech-foundation/`:
- `fluent-platform/` (compose.yaml, docs) — the repo this plan lives in
- `fluent-api/` (compose.yaml, fapi.sh)
- `fluent-ai/` (compose.yaml, fai.sh)

`fluent-web` is intentionally **not touched** — it has no compose.yaml and `fweb.sh` already execs by flat name; it is fixed by Task 1's platform `container_name: fluent-web`.

Commit each task in the repo whose files it changes.

## File structure

| File | Responsibility | Change |
|------|----------------|--------|
| `fluent-platform/compose.yaml` | ecosystem stack definition | add `container_name` to db/api/worker/ai/web |
| `fluent-api/compose.yaml` | standalone api stack | add `container_name` to db/api/worker |
| `fluent-ai/compose.yaml` | standalone ai stack | add `container_name` to db/ai |
| `fluent-api/fapi.sh` | api repo helper | Docker-branch exec/shell/psql → `docker exec` by name |
| `fluent-ai/fai.sh` | ai repo helper | Docker-branch exec/shell/psql → `docker exec` by name |
| `fluent-platform/docs/containerization.md` | container docs | document naming scheme + one-stack constraint |

---

### Task 1: Pin container names in the platform compose

**Files:**
- Modify: `fluent-platform/compose.yaml`

Ecosystem container names must equal what the repo scripts compute in ecosystem mode
(`CONTAINER_PREFIX=fluent-`): `fluent-db`, `fluent-api`, `fluent-worker`, `fluent-ai`,
`fluent-web`.

- [ ] **Step 1: Add `container_name` to the `db` service**

In `fluent-platform/compose.yaml`, the `db` service begins:

```yaml
  db:
    image: postgres:16-alpine
```

Change to:

```yaml
  db:
    container_name: fluent-db
    image: postgres:16-alpine
```

- [ ] **Step 2: Add `container_name` to `api`, `worker`, `ai`, `web`**

Each of these services begins with a `build:` block. Insert a `container_name:` line as the
first child of each service key.

`api`:
```yaml
  api:
    container_name: fluent-api
    build:
```

`worker`:
```yaml
  worker:
    container_name: fluent-worker
    build:
```

`ai`:
```yaml
  ai:
    container_name: fluent-ai
    build:
```

`web`:
```yaml
  web:
    container_name: fluent-web
    build:
```

- [ ] **Step 3: Validate compose config parses**

Run (from `fluent-platform/`):
```bash
docker compose config >/dev/null && echo "compose OK"
```
Expected: `compose OK` (no YAML/schema errors).

- [ ] **Step 4: Verify the names resolved**

Run:
```bash
docker compose config | grep -E 'container_name'
```
Expected: lines showing `container_name: fluent-db`, `fluent-api`, `fluent-worker`,
`fluent-ai`, `fluent-web`.

- [ ] **Step 5: Commit**

```bash
cd /Users/kasey/code/github.com/eten-tech-foundation/fluent-platform
git add compose.yaml
git commit -m "fix(compose): pin ecosystem container_name on all services

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Pin container names in the fluent-api standalone compose

**Files:**
- Modify: `fluent-api/compose.yaml`

Standalone names must equal `fapi.sh` standalone vars (`CONTAINER_PREFIX=fluent-api-`):
`fluent-api-db`, `fluent-api-api`, `fluent-api-worker`.

- [ ] **Step 1: Add `container_name` to `db`**

```yaml
  db:
    container_name: fluent-api-db
    image: postgres:16-alpine
```

- [ ] **Step 2: Add `container_name` to `api` and `worker`**

`api`:
```yaml
  api:
    container_name: fluent-api-api
    build:
```

`worker`:
```yaml
  worker:
    container_name: fluent-api-worker
    build:
```

- [ ] **Step 3: Validate**

Run (from `fluent-api/`):
```bash
docker compose config | grep -E 'container_name'
```
Expected: `fluent-api-db`, `fluent-api-api`, `fluent-api-worker`.

- [ ] **Step 4: Commit**

```bash
cd /Users/kasey/code/github.com/eten-tech-foundation/fluent-api
git add compose.yaml
git commit -m "fix(compose): pin standalone container_name on db/api/worker

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Pin container names in the fluent-ai standalone compose

**Files:**
- Modify: `fluent-ai/compose.yaml`

Standalone names must equal `fai.sh` standalone vars (`CONTAINER_PREFIX=fluent-ai-`):
`fluent-ai-db`, `fluent-ai-ai`.

- [ ] **Step 1: Add `container_name` to `db`**

```yaml
  db:
    container_name: fluent-ai-db
    image: postgres:16-alpine
```

- [ ] **Step 2: Add `container_name` to `ai`**

```yaml
  ai:
    container_name: fluent-ai-ai
    build:
```

- [ ] **Step 3: Validate**

Run (from `fluent-ai/`):
```bash
docker compose config | grep -E 'container_name'
```
Expected: `fluent-ai-db`, `fluent-ai-ai`.

- [ ] **Step 4: Commit**

```bash
cd /Users/kasey/code/github.com/eten-tech-foundation/fluent-ai
git add compose.yaml
git commit -m "fix(compose): pin standalone container_name on db/ai

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Exec by container name in `fapi.sh`

**Files:**
- Modify: `fluent-api/fapi.sh` (functions `compose_shell` ~401, `compose_exec_api` ~410, `compose_db_psql` ~441)

The Docker branch uses the literal `docker` binary (in docker-compose mode `$RUNTIME` is
empty; `docker compose` / `docker-compose` both imply the `docker` CLI). Container vars
(`$API_CONTAINER`, `$DB_CONTAINER`, `$CONTAINER_PREFIX`) are already mode-aware.

- [ ] **Step 1: Replace `compose_exec_api`**

Find:
```bash
compose_exec_api() {
  $COMPOSE_CMD exec api "$@"
}
```
Replace with:
```bash
compose_exec_api() {
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$API_CONTAINER"; then
    echo_error "API container ($API_CONTAINER) is not running. Run './fapi.sh up' first."
    exit 1
  fi
  docker exec "$API_CONTAINER" "$@"
}
```

- [ ] **Step 2: Replace `compose_shell`**

Find:
```bash
compose_shell() {
  local service="${1:-api}"
  if [ "$service" = "db" ]; then
    $COMPOSE_CMD exec db psql -U postgres -d fluent
  else
    $COMPOSE_CMD exec "$service" sh
  fi
}
```
Replace with:
```bash
compose_shell() {
  local service="${1:-api}"
  if [ "$service" = "db" ]; then
    docker exec -it "$DB_CONTAINER" psql -U postgres -d fluent
  else
    docker exec -it "${CONTAINER_PREFIX}$service" sh
  fi
}
```

- [ ] **Step 3: Replace `compose_db_psql`**

Find:
```bash
compose_db_psql() {
  $COMPOSE_CMD exec db psql -U postgres -d fluent
}
```
Replace with:
```bash
compose_db_psql() {
  docker exec -it "$DB_CONTAINER" psql -U postgres -d fluent
}
```

- [ ] **Step 4: Syntax check**

Run:
```bash
bash -n /Users/kasey/code/github.com/eten-tech-foundation/fluent-api/fapi.sh && echo "sh OK"
```
Expected: `sh OK`.

- [ ] **Step 5: Verify no stray `$COMPOSE_CMD exec` remains**

Run:
```bash
grep -n '\$COMPOSE_CMD exec' /Users/kasey/code/github.com/eten-tech-foundation/fluent-api/fapi.sh || echo "none"
```
Expected: `none` (all exec sites now use `docker exec`).

- [ ] **Step 6: Commit**

```bash
cd /Users/kasey/code/github.com/eten-tech-foundation/fluent-api
git add fapi.sh
git commit -m "fix(fapi): exec by container name, not compose project

Resolves passthrough failures when the platform started the stack.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Exec by container name in `fai.sh`

**Files:**
- Modify: `fluent-ai/fai.sh` (functions `compose_shell` ~342, `compose_exec_ai` ~351)

- [ ] **Step 1: Replace `compose_exec_ai`**

Find:
```bash
compose_exec_ai() {
  $COMPOSE_CMD exec ai "$@"
}
```
Replace with:
```bash
compose_exec_ai() {
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AI_CONTAINER"; then
    echo_error "AI container ($AI_CONTAINER) is not running. Run './fai.sh up' first."
    exit 1
  fi
  docker exec "$AI_CONTAINER" "$@"
}
```

- [ ] **Step 2: Replace `compose_shell`**

Find:
```bash
compose_shell() {
  local service="${1:-ai}"
  if [ "$service" = "db" ]; then
    $COMPOSE_CMD exec db psql -U postgres -d fluent
  else
    $COMPOSE_CMD exec "$service" sh
  fi
}
```
Replace with:
```bash
compose_shell() {
  local service="${1:-ai}"
  if [ "$service" = "db" ]; then
    docker exec -it "$DB_CONTAINER" psql -U postgres -d fluent
  else
    docker exec -it "${CONTAINER_PREFIX}$service" sh
  fi
}
```

- [ ] **Step 3: Check for a `compose_db_psql` in `fai.sh` and fix if present**

Run:
```bash
grep -n 'compose_db_psql\|\$COMPOSE_CMD exec db' /Users/kasey/code/github.com/eten-tech-foundation/fluent-ai/fai.sh || echo "none"
```
If a `compose_db_psql() { $COMPOSE_CMD exec db psql -U postgres -d fluent }` exists, replace its body with:
```bash
  docker exec -it "$DB_CONTAINER" psql -U postgres -d fluent
```
If output is `none`, skip.

- [ ] **Step 4: Syntax check**

Run:
```bash
bash -n /Users/kasey/code/github.com/eten-tech-foundation/fluent-ai/fai.sh && echo "sh OK"
```
Expected: `sh OK`.

- [ ] **Step 5: Verify no stray `$COMPOSE_CMD exec` remains**

Run:
```bash
grep -n '\$COMPOSE_CMD exec' /Users/kasey/code/github.com/eten-tech-foundation/fluent-ai/fai.sh || echo "none"
```
Expected: `none`.

- [ ] **Step 6: Commit**

```bash
cd /Users/kasey/code/github.com/eten-tech-foundation/fluent-ai
git add fai.sh
git commit -m "fix(fai): exec by container name, not compose project

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Document the naming scheme

**Files:**
- Modify: `fluent-platform/docs/containerization.md`

- [ ] **Step 1: Locate an insertion point**

Run:
```bash
grep -n '^## ' /Users/kasey/code/github.com/eten-tech-foundation/fluent-platform/docs/containerization.md
```
Pick the heading after which a "Container Naming" section fits (e.g. after the "Shared
Database Model" section). Note its line number.

- [ ] **Step 2: Insert the naming-scheme section**

Add this section at the chosen point:

```markdown
## Container Naming

Every compose service pins an explicit `container_name`, so containers have stable,
predictable names independent of the Docker Compose project (working directory) or runtime.
Names are scoped by mode so the two stacks never clobber each other:

| Service | Ecosystem (platform) | Standalone (repo) |
|---------|----------------------|-------------------|
| db      | `fluent-db`          | `fluent-api-db` / `fluent-ai-db` |
| api     | `fluent-api`         | `fluent-api-api`  |
| worker  | `fluent-worker`      | `fluent-api-worker` |
| ai      | `fluent-ai`          | `fluent-ai-ai`    |
| web     | `fluent-web`         | `fluent-web` (raw run, no compose) |

The repo helper scripts (`fapi.sh`, `fai.sh`, `fweb.sh`) `exec` these names directly
(`docker exec <name>` / `podman exec <name>`) rather than via `docker compose exec`. This is
why a passthrough such as `./fluent.sh api run db:migrate-rbac` finds the running container
no matter which tool or directory started the stack.

Because `container_name` is global to the daemon and the modes share host ports
(5432 / 9999), run **one stack at a time** — the ecosystem stack or a single standalone
repo, not both. (`container_name` also disables Compose scaling, which is fine for
single-instance dev containers.)
```

- [ ] **Step 3: Commit**

```bash
cd /Users/kasey/code/github.com/eten-tech-foundation/fluent-platform
git add docs/containerization.md
git commit -m "docs: document container naming scheme and one-stack constraint

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Integration verification (Docker + Podman)

**Files:** none (validation only)

Run the original failing command and the related exec paths against a live stack. Run the
full block once per available runtime. (Docker Compose is the primary; repeat on Podman if
available.)

- [ ] **Step 1: Bring up the full ecosystem stack**

Run (from `fluent-platform/`):
```bash
./fluent.sh up
```
Wait for services to report healthy (`./fluent.sh status`).

- [ ] **Step 2: The original failing command now works**

Run:
```bash
./fluent.sh api run db:migrate-rbac
```
Expected: it resolves the running `fluent-api` container and runs the script (no
"service not running" / "no such service" error).

- [ ] **Step 3: AI passthrough resolves**

Run:
```bash
./fluent.sh ai run alembic history
```
Expected: command runs inside `fluent-ai` and prints migration history.

- [ ] **Step 4: Web passthrough resolves**

Run:
```bash
./fluent.sh web run lint
```
Expected: runs inside `fluent-web` (no container-not-found error).

- [ ] **Step 5: Shells resolve**

Run:
```bash
./fluent.sh shell db
```
Expected: opens a `psql` prompt in `fluent-db`. Exit with `\q`.

- [ ] **Step 6: Standalone regression**

Tear down the ecosystem stack, then from `fluent-api/`:
```bash
cd ../fluent-platform && ./fluent.sh down
cd ../fluent-api && ./fapi.sh up && ./fapi.sh run db:migrate-rbac
```
Expected: runs against `fluent-api-api`. Then tear down: `./fapi.sh down`.

- [ ] **Step 7: Record results**

Note in the PR description which runtimes were exercised and that steps 2–6 passed.
```
