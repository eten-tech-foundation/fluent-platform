# Container Naming & Passthrough Exec — Design

> **Status:** Approved design — 2026-06-14. Implements "Approach A — exec by stable
> container name." Next step: implementation plan via writing-plans.

## Problem

When the platform stack is running, repo-passthrough commands fail to find the running
service. Example:

```sh
./fluent.sh api run db:migrate-rbac
# -> "service api is not running" (or no such service)
```

### Root cause

The collision is a Docker **Compose project mismatch**, not a container-name clash.
None of the `compose.yaml` files set a project `name:` or per-service `container_name:`,
so Compose derives the project from the working directory:

- Platform brings the stack up → project **`fluent-platform`** → container
  `fluent-platform-api-1`.
- `./fluent.sh api run …` passes through to `fluent-api/fapi.sh` in ecosystem mode, which
  runs `docker compose exec api …` **from the `fluent-api/` directory** → resolves to
  project **`fluent-api`**, where nothing is running → failure.

The Podman path is unaffected because it `exec`s a **flat container name**
(`fluent-api`) via `$RUNTIME exec $CONTAINER`, passed down through
`FLUENT_CONTAINER_PREFIX`, so it finds the container regardless of who started it. The
Docker path is the outlier: it depends on a directory-derived Compose project that the
passthrough breaks.

### Scope of impact

- **`fluent-api`, `fluent-ai`**: affected. Their Docker path uses `docker compose exec`.
- **`fluent-web`**: also affected, but differently. It has **no `compose.yaml`** — `fweb.sh`
  uses raw `docker run`/`podman run` and already execs by flat name. But the platform
  starts web via the **platform** `compose.yaml`, naming it `fluent-platform-web-1`, while
  `fweb.sh` execs `fluent-web`. Fixed by pinning `container_name` in the platform compose
  (no `fweb.sh` change needed).
- **Platform-level `db:migrate` / `db:seed`**: already work — they run `compose exec` from
  the platform directory (correct project). Not in scope to change.

## Approach (A): exec by stable container name

Make the Docker path do what the Podman path already does — `exec` a **named container**
instead of going through `docker compose exec` (which is project-context dependent). This
unifies both runtimes onto a single `<binary> exec <container>` code path and removes the
Compose-project dependency entirely.

### 1. Deterministic, mode-scoped container naming

Pin `container_name:` on every service so names are predictable and identical across Docker
and Podman. These are exactly the names the scripts already compute via
`$API_CONTAINER` / `$AI_CONTAINER` / `CONTAINER_PREFIX`.

| Service | Ecosystem (platform compose) | Standalone (repo compose) |
|---------|------------------------------|---------------------------|
| db      | `fluent-db`                  | `fluent-api-db` / `fluent-ai-db` |
| api     | `fluent-api`                 | `fluent-api-api`          |
| worker  | `fluent-worker`              | `fluent-api-worker`       |
| ai      | `fluent-ai`                  | `fluent-ai-ai`            |
| web     | `fluent-web`                 | (raw run, already `fluent-web`) |

### 2. Exec by name, not by Compose project

In `fapi.sh` and `fai.sh`, replace the Docker branch's `$COMPOSE_CMD exec <svc> …` with
`docker exec [-it] $CONTAINER …`, mirroring the Podman branch (`$RUNTIME exec $CONTAINER`).
Three exec sites per script:

- the main `exec_api` / `exec_ai` helper (used by test/lint/format/typecheck/run/db:* cmds),
- the `shell` command,
- the `db` psql shell.

Use the literal `docker` binary in the Docker branch (Compose v1 `docker-compose` and v2
`docker compose` both imply the `docker` CLI is present). `fweb.sh` already execs by name —
no change.

Parity note: `docker exec fluent-api npm run …` runs in the image's `WORKDIR` (`/app`) as the
image's default user (1001) — identical to the already-working Podman path. We are not
relying on Compose's env/workdir injection.

### 3. Files touched

- `fluent-platform/compose.yaml` — add `container_name` to db, api, worker, ai, web
- `fluent-api/compose.yaml` — add `container_name` to db, api, worker
- `fluent-ai/compose.yaml` — add `container_name` to db, ai
- `fluent-api/fapi.sh` — swap the three Docker-branch `compose exec` sites → `docker exec`
- `fluent-ai/fai.sh` — same
- `fluent-platform/docs/containerization.md` — document the naming scheme + constraint
- `fluent-web/fweb.sh` — **no change** (verified: already execs by name)

### 4. Naming-collision stance

Names are intentionally non-overlapping by mode (`fluent-api` vs `fluent-api-api`), so the
ecosystem and standalone stacks cannot clobber each other's containers. Running both
simultaneously remains blocked by shared host ports (5432 / 9999), consistent with the
earlier port-unification decision (run one stack at a time). `container_name` disables
Compose scaling, which is acceptable for single-instance dev containers.

## Out of scope

- Changing platform-level `db:migrate` / `db:seed` (already correct).
- Allowing platform + standalone stacks to run concurrently (blocked by ports by design).
- Any change to `fweb.sh` logic or the addition of a `fluent-web/compose.yaml`.

## Test plan

For each runtime (Docker Compose **and** Podman):

1. `./fluent.sh up` (full stack).
2. `./fluent.sh api run db:migrate-rbac` → resolves the running container and succeeds
   (the original failing command).
3. `./fluent.sh ai run alembic history` → resolves and succeeds.
4. `./fluent.sh api shell` / `./fluent.sh ai shell` → opens a shell in the running container.
5. `./fluent.sh web run lint` → resolves the running web container.
6. `./fluent.sh shell db` → opens psql.
7. Standalone regression: from `fluent-api/`, `./fapi.sh up` then `./fapi.sh run db:migrate-rbac`
   still works (container `fluent-api-api`). Same for `fluent-ai`.
