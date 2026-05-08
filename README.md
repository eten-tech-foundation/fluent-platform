# Fluent Platform

Container-first orchestration for the Fluent development environment. This repo coordinates the containerized **fluent-api**, **fluent-ai**, and **fluent-web** services into a single local stack with a shared PostgreSQL database, hardened security defaults, role-based DB access, and cross-platform management scripts.

Each sibling repository is self-containerized with its own `Dockerfile.dev`, `compose.yaml`, and helper script (`fapi.sh`, `fai.sh`, `fweb.sh`). The platform orchestrator is the thin layer that wires them together for full-ecosystem local development.

## Prerequisites

- **Docker Desktop** (includes Compose V2) or **Podman** (native pods)
- **Git** (for initial repo cloning)
- **Node.js** (only needed on the host for `db:studio`)

## Repository Layout

This project expects sibling repositories in the parent directory:

```
parent/
  fluent-platform/   <- this repo (orchestrator + shared DB)
  fluent-api/        <- Node.js API + worker (self-containerized)
  fluent-ai/         <- Python AI service (self-containerized)
  fluent-web/        <- React frontend (self-containerized)
```

Override paths via environment variables if your layout differs:

```sh
export API_CONTEXT=~/projects/fluent-api
export AI_CONTEXT=~/projects/fluent-ai
export WEB_CONTEXT=~/projects/fluent-web
```

## Quick Start

```sh
# 1. First-time setup - clones sibling repos and creates .env files
./fluent.sh setup

# 2. Fill in credentials in each .env file (Auth0, API keys, etc.)

# 3. Start the full ecosystem (shared DB + all services)
./fluent.sh up

# 4. Initialize the database (first run only)
./fluent.sh db:init
```

On Windows, use `fluent.ps1` instead of `fluent.sh`.

## Container Strategy

The platform operates in two modes:

- **Ecosystem mode** (default): The platform owns a single shared PostgreSQL container on port 5432. All services connect to it. Use `./fluent.sh up` to start everything.
- **Standalone mode**: Each repo can run independently with its own DB using its own helper script (`./fapi.sh up`, `./fai.sh up`, `./fweb.sh up`). This is useful when working on a single service in isolation.

The platform `compose.yaml` is the authoritative orchestrator for Docker Compose. Under Podman, `fluent.sh` creates a `fluent` pod and starts containers directly.

## Services

| Service  | Port | Description                          | Repo script |
|----------|------|--------------------------------------|-------------|
| **db**   | 5432 | Shared PostgreSQL 16 (Alpine)        | (platform)  |
| **api**  | 9999 | Node.js REST API (Drizzle ORM)       | `fapi.sh`   |
| **worker** | -  | Background job worker (pg-boss)      | `fapi.sh`   |
| **ai**   | 8200 | Python AI service (FastAPI, asyncpg) | `fai.sh`    |
| **web**  | 5173 | React frontend (Vite dev server)     | `fweb.sh`   |

All ports are configurable via `.env` (`DB_PORT`, `API_PORT`, `AI_PORT`, `WEB_PORT`).

## Commands

```sh
./fluent.sh <command> [args]
```

### Ecosystem Commands

These operate on the full stack or a subset of services:

| Command                 | Description                                    |
|-------------------------|------------------------------------------------|
| `up [service...]`       | Start all or specific services                 |
| `down [service...]`     | Stop all or specific services                  |
| `restart [service...]`  | Restart services                               |
| `logs [service]`        | Tail logs (default: all)                       |
| `status`                | Show container status                          |
| `shell <service>`       | Open a shell (`db` opens psql)                 |
| `clean [service]`       | Remove containers and volumes (full DB reset)  |
| `fresh`                 | Destroy everything - containers, volumes, images |
| `build [service...]`  | Rebuild images without cache                   |
| `setup`                 | Clone repos, copy .env files                   |
| `check-repos`           | Verify sibling repos exist                     |

### Database Commands

| Command                | Description                                      |
|------------------------|--------------------------------------------------|
| `db:migrate [target]`  | Run migrations (`api`, `ai`, or `all`)           |
| `db:seed [target]`     | Run seed scripts (`api`, `ai`, or `all`)         |
| `db:init`              | Run all migrations then all seeds                |
| `db:studio`            | Launch Drizzle Studio on the host                |
| `db:psql`              | Open an interactive psql session                 |

### Repo-Specific Commands (Prefix Style)

Run development, test, and database commands inside a specific service container:

```sh
# API
./fluent.sh api up            # Start API service
./fluent.sh api down          # Stop API service
./fluent.sh api restart       # Restart API
./fluent.sh api logs          # Tail API logs
./fluent.sh api shell         # Open shell in API container
./fluent.sh api test          # Run API test suite
./fluent.sh api lint          # Run API linter
./fluent.sh api lint:fix      # Run API linter with auto-fix
./fluent.sh api format        # Format API code
./fluent.sh api format:check  # Check API formatting
./fluent.sh api typecheck     # Run API type checker
./fluent.sh api run <script>  # Run an npm script in API
./fluent.sh api db:migrate    # Run API migrations
./fluent.sh api db:seed       # Run API seeds
./fluent.sh api db:generate <name>   # Generate a new migration
./fluent.sh api db:dump-schema       # Dump API schema for fluent-ai sync

# AI
./fluent.sh ai up             # Start AI service
./fluent.sh ai down           # Stop AI service
./fluent.sh ai restart        # Restart AI
./fluent.sh ai logs           # Tail AI logs
./fluent.sh ai shell          # Open shell in AI container
./fluent.sh ai test           # Run AI test suite (pytest)
./fluent.sh ai lint           # Run AI linter (ruff)
./fluent.sh ai lint:fix       # Run AI linter with auto-fix
./fluent.sh ai format         # Format AI code
./fluent.sh ai format:check   # Check AI formatting
./fluent.sh ai typecheck      # Run AI type checker (mypy)
./fluent.sh ai run <command>  # Run a uv command in AI

# Web
./fluent.sh web up            # Start Web service
./fluent.sh web down          # Stop Web service
./fluent.sh web restart       # Restart Web
./fluent.sh web logs          # Tail Web logs
./fluent.sh web shell         # Open shell in Web container
./fluent.sh web test          # Run Web test suite
./fluent.sh web lint          # Run Web linter
./fluent.sh web lint:fix      # Run Web linter with auto-fix
./fluent.sh web format        # Format Web code
./fluent.sh web format:check  # Check Web formatting
./fluent.sh web typecheck     # Run Web type checker
./fluent.sh web precheck      # Run lint + format:check + typecheck + test
./fluent.sh web preview       # Preview production build
./fluent.sh web run <script>  # Run a pnpm script in Web

# Worker (lifecycle only - dev commands run via api)
./fluent.sh worker up         # Start Worker service
./fluent.sh worker down       # Stop Worker service
./fluent.sh worker restart    # Restart Worker
./fluent.sh worker logs       # Tail Worker logs
./fluent.sh worker shell      # Open shell in Worker container
```

## Environment Configuration

Copy the example and fill in your values:

```sh
# Port Mappings
DB_PORT=5432
API_PORT=9999
AI_PORT=8200
WEB_PORT=5173

# Repo Paths (override for non-standard layouts)
# API_CONTEXT=../fluent-api
# AI_CONTEXT=../fluent-ai
# WEB_CONTEXT=../fluent-web

# Database (for host tools like Drizzle Studio, psql)
DATABASE_URL=postgres://postgres:postgres@localhost:5432/fluent
```

Each sibling repo also has its own `.env.example` - the `setup` command copies these automatically.

## Database Architecture

The platform owns a single shared PostgreSQL instance initialized by `db/init/init-db.sql`. It uses a multi-schema design with role-based access control:

| Schema     | Purpose                        | Write Access       | Read Access          |
|------------|--------------------------------|--------------------|----------------------|
| `public`   | Core application data          | web_user           | web_user, ai_user    |
| `pgboss`   | Job queue (pg-boss)            | web_user, ai_user  | web_user, ai_user    |
| `ai`       | AI service data                | ai_user            | ai_user              |
| `drizzle`  | Migration tracking             | migrations         | migrations           |

Login users: `db_admin`, `migrations`, `web_user`, `ai_user`. The init script sets up all roles, schemas, and default privileges automatically on first run.

## Container Security

All application containers run with hardened defaults:

- **Non-root user** (`1001:1001`)
- **Read-only root filesystem** (`read_only: true`)
- **All Linux capabilities dropped** (`cap_drop: ALL`)
- **No privilege escalation** (`no-new-privileges: true`)
- **tmpfs** for writable scratch space (`/tmp`, `/app/.cache`, `/app/exports`)
- **Source mounts** are read-only except `src/` (needed for lint/format)
- **Named volumes** for `node_modules` to avoid anonymous volume clutter

## Development Workflow

Source code is bind-mounted into each container with hot-reload enabled. Edit files locally and changes are picked up automatically:

- **api / worker**: tsx watch mode
- **ai**: uvicorn with reload
- **web**: Vite HMR

Run linting, formatting, and type checking inside a container using prefix commands:

```sh
./fluent.sh api lint
./fluent.sh web format
./fluent.sh ai typecheck
```

## Deployment

Azure deployment configurations live in `deploy/azure/`:

- `deploy/azure/bicep/` - Azure Bicep infrastructure templates
- `deploy/azure/env/` - Per-environment image tags (`dev.env`, `staging.env`, `prod.env`)
