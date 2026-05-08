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

The platform owns a single shared PostgreSQL container on port 5432. All services connect to it via the internal network (Docker Compose) or the shared pod network (Podman). The database is initialized by `db/init/init-db.sql` on first run, which creates roles, schemas, and default privileges.

When running an individual repo in standalone mode (`./fapi.sh up`, `./fai.sh up`), that repo brings up its own PostgreSQL container on a non-conflicting port (e.g., 5433 for fluent-ai). This allows isolated development without the full ecosystem.

### Ecosystem vs Standalone

**Ecosystem mode** (platform orchestrator):
- Single shared DB managed by `fluent-platform`
- All services run together with `compose.yaml` (Docker) or the `fluent` pod (Podman)
- Dev/test commands use prefix style: `./fluent.sh api test`, `./fluent.sh web lint`
- Database migrations and seeds are run explicitly: `./fluent.sh db:init`

**Standalone mode** (individual repos):
- Each repo manages its own DB via its own `compose.yaml` or pod
- Useful when working on a single service in isolation
- Dev commands run directly: `./fapi.sh test`, `./fweb.sh lint`

### Platform compose.yaml vs Repo compose.yaml

The platform `compose.yaml` is the authoritative ecosystem orchestrator. It:
- Defines the shared `db` service with healthchecks and init scripts
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

Under Podman, the platform uses hyphenated container names for clarity:
- `fluent-db`
- `fluent-api`
- `fluent-worker`
- `fluent-ai`
- `fluent-web`

These match the service names in the platform `compose.yaml` and are consistent across both runtime modes.
