# Containerization

## Container Strategy

Prefer Podman for its default non-root execution environment.

Support Podman and Docker in the helper scripts.

### Single-Service Projects (e.g., fluent-web)

- Do not use compose

### Multi-Service Projects (e.g., fluent-ai, fluent-api)

- Use compose for Docker
- Use podman pods
- Do not use podman-compose
- All helper script commands should:
  - Handle all services by default (`./<script> up`)
  - Handle specific services by specification (`./<script> up <service>`)
  - Avoid port collisions with default port values
- Seed DB on start so that local development with a single project works
  - For example, AI and API projects should scaffold a PostgreSQL service

### Fluent-Platform

- Be the orchestrator and work with the other codebase scripts

## Platform Orchestration

The platform (`fluent-platform`) is a thin orchestrator over the self-containerized sibling repositories. It does not contain application code; it wires together the services from `fluent-api`, `fluent-ai`, and `fluent-web` into a single local development stack.

### Shared Database Model

The platform owns a single shared PostgreSQL container on port 5432. All services connect to it via the internal network (Docker Compose) or the shared pod network (Podman). The database starts **superuser-only** — there is no shared init script. **Each service self-provisions** on startup: an idempotent bootstrap step creates that service's own roles, schema, and grants (as the `postgres` superuser via `BOOTSTRAP_DATABASE_URL`), then the service runs its own migrations (as its migration role) and seeds. `fluent-api` owns `public`/`pgboss`/`drizzle` (roles `api_user`/`api_migrator`); `fluent-ai` owns `ai` (roles `ai_user`/`ai_migrator`). No service reads another's schema — there are no cross-schema reads; API↔AI is HTTP (`FLUENT_AI_URL`). See `fluent-platform/README.md` for the ownership table.

When running an individual repo in standalone mode (`./fapi.sh up`, `./fai.sh up`), that repo brings up its own PostgreSQL container on port 5432 and self-provisions the same way. Because the standalone DBs and the platform DB all use host port 5432, run one stack at a time (don't run a standalone service alongside the platform).

### Ecosystem vs Standalone

**Ecosystem mode** (platform orchestrator):
- Single shared DB managed by `fluent-platform`
- All services run together with `compose.yaml` (Docker) or the `fluent` pod (Podman)
- Dev/test commands use prefix style: `./fluent.sh api test`, `./fluent.sh web lint`
- Each service provisions its own roles/schema, migrations, and seeds on container start (bootstrap → migrate → seed); there is no shared init step

**Standalone mode** (individual repos):
- Each repo manages its own DB via its own `compose.yaml` or pod
- Useful when working on a single service in isolation
- Dev commands run directly: `./fapi.sh test`, `./fweb.sh lint`

### Platform compose.yaml vs Repo compose.yaml

The platform `compose.yaml` is the authoritative ecosystem orchestrator. It:
- Defines the shared `db` service with healthchecks (no init scripts — starts superuser-only; services self-provision)
- Injects three DB URLs per service — `BOOTSTRAP_DATABASE_URL` (superuser, for self-provisioning), `MIGRATIONS_DATABASE_URL` (migration role), `DATABASE_URL` (least-privilege runtime role)
- Defines `api`, `worker`, `ai`, and `web` services with build contexts pointing to sibling repos
- Establishes `depends_on` chains: `db` healthy -> `api` healthy -> `worker`, `ai`, `web`

Each repo's own `compose.yaml` is for standalone development and defines:
- Its own `db` service (for isolated development)
- Its application service(s)
- Internal dependencies within that repo

### Command Delegation

Under **Docker Compose**, the platform runs `docker compose` commands directly. Repo-specific commands like `./fluent.sh api test` are translated to `docker compose exec api npm run test`.

Under **Podman**, the platform creates the `fluent` pod and starts containers directly with `podman run`. Repo-specific commands use `podman exec fluent-api ...` directly. The platform does not delegate to repo scripts under Podman; it manages container lifecycle and exec directly to ensure consistent container naming.

### Container Naming

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
