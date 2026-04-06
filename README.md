# Fluent Platform

Orchestration layer for the Fluent development environment. This repo ties together the API, AI, web, and database services into a single containerized stack with hardened security defaults, role-based database access, and cross-platform management scripts.

## Prerequisites

- **Docker Desktop** (includes Compose V2) or **Podman** (includes podman compose)
- **Git** (for initial repo cloning)
- **Node.js** (only needed on the host for `db:studio`)

## Repository Layout

This project expects sibling repositories in the parent directory:

```
parent/
  fluent-platform/   ← this repo
  fluent-api/        ← Node.js API + worker
  fluent-ai/         ← Python AI service
  fluent-web/        ← React frontend (Vite)
```

Override paths via environment variables if your layout differs:

```sh
export API_CONTEXT=~/projects/fluent-api
export AI_CONTEXT=~/projects/fluent-ai
export WEB_CONTEXT=~/projects/fluent-web
```

## Quick Start

```sh
# 1. First-time setup — clones sibling repos and creates .env files
./fluent.sh setup

# 2. Fill in credentials in each .env file (Auth0, etc.)

# 3. Start everything
./fluent.sh up
```

On Windows, use `fluent.ps1` instead of `fluent.sh`.

## Services

| Service  | Port | Description                          |
|----------|------|--------------------------------------|
| **db**   | 5432 | PostgreSQL 16 (Alpine)               |
| **api**  | 9999 | Node.js REST API (Drizzle ORM)       |
| **worker** | —  | Background job worker (pg-boss)      |
| **ai**   | 8200 | Python AI service (FastAPI, asyncpg) |
| **web**  | 5173 | React frontend (Vite dev server)     |

All ports are configurable via `.env` (`DB_PORT`, `API_PORT`, `AI_PORT`, `WEB_PORT`).

## Commands

```
./fluent.sh <command> [args]
```

### Service Management

| Command                    | Description                              |
|----------------------------|------------------------------------------|
| `up [service...]`          | Start all or specific services           |
| `down [service...]`        | Stop all or specific services            |
| `restart [service...]`     | Restart services                         |
| `logs [service]`           | Tail logs (default: all)                 |
| `status`                   | Show container status                    |
| `shell <service>`          | Open a shell (`db` opens psql)           |
| `run <service> <script>`   | Run an npm/pnpm script in a container    |
| `test <service>`           | Run tests (pytest for ai, npm for others)|

### Database

| Command              | Description                                      |
|----------------------|--------------------------------------------------|
| `db:migrate [target]`| Run migrations (`api`, `ai`, or `all`)           |
| `db:seed [target]`   | Run seed scripts (`api`, `ai`, or `all`)         |
| `db:init`            | Run all migrations then all seeds                |
| `db:studio`          | Launch Drizzle Studio on the host                |
| `db:psql`            | Open an interactive psql session                 |

### Lifecycle

| Command              | Description                                        |
|----------------------|----------------------------------------------------|
| `build [service...]` | Rebuild containers without cache                   |
| `clean [service]`    | Remove containers and volumes (full DB reset)      |
| `fresh`              | Destroy everything — containers, volumes, images   |
| `check-repos`        | Verify sibling repos exist                         |
| `setup`              | First-time setup — clone repos, copy .env files    |

## Environment Configuration

Copy the example and fill in your values:

```sh
cp .env.example .env
```

```env
# Port Mappings
DB_PORT=5432
API_PORT=9999
AI_PORT=8200
WEB_PORT=5173

# Repo Paths (override for non-standard layouts)
# API_CONTEXT=../fluent-api
# AI_CONTEXT=../fluent-ai
# WEB_CONTEXT=../fluent-web

# Database (for host tools like Drizzle Studio)
DATABASE_URL=postgres://postgres:postgres@localhost:5432/fluent
```

Each sibling repo also has its own `.env.example` — the `setup` command copies these automatically.

## Database Architecture

The database uses a multi-schema design with role-based access control:

| Schema     | Purpose                        | Write Access       | Read Access          |
|------------|--------------------------------|--------------------|----------------------|
| `public`   | Core application data          | web_user           | web_user, ai_user    |
| `pgboss`   | Job queue (pg-boss)            | web_user, ai_user  | web_user, ai_user    |
| `ai`       | AI service data                | ai_user            | ai_user              |
| `drizzle`  | Migration tracking             | migrations         | migrations           |

Login users: `db_admin`, `migrations`, `web_user`, `ai_user`. The init script (`db/init/init-db.sql`) sets up all roles, schemas, and default privileges automatically on first run.

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

Run linting, formatting, and type checking inside the container:

```sh
./fluent.sh run web pnpm run lint
./fluent.sh run web pnpm run typecheck
./fluent.sh run web pnpm run lint:fix
./fluent.sh run web pnpm run format
```

## Deployment

Azure deployment configurations live in `deploy/azure/`:

- `deploy/azure/bicep/` — Azure Bicep infrastructure templates
- `deploy/azure/env/` — Per-environment image tags (`dev.env`, `staging.env`, `prod.env`)
