#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Runtime detection (prefer Podman) ──────────────────────────────────────────

detect_runtime() {
  if command -v podman &>/dev/null && command -v podman-compose &>/dev/null; then
    COMPOSE_CMD="podman-compose"
  elif command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker &>/dev/null && command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
  else
    echo "Error: No container runtime found."
    echo "Install one of:"
    echo "  - Podman + podman-compose"
    echo "  - Docker Desktop (includes docker compose V2)"
    echo "  - Docker Engine + docker-compose"
    exit 1
  fi
}

detect_runtime

# ── Repo path helpers ──────────────────────────────────────────────────────────

API_CONTEXT="${API_CONTEXT:-../fluent-api}"
AI_CONTEXT="${AI_CONTEXT:-../fluent-ai}"
WEB_CONTEXT="${WEB_CONTEXT:-../fluent-web}"

REPOS=("$API_CONTEXT" "$AI_CONTEXT" "$WEB_CONTEXT")
REPO_NAMES=("fluent-api" "fluent-ai" "fluent-web")
REPO_URLS=(
  "git@github.com:eten-tech-foundation/fluent-api.git"
  "git@github.com:eten-tech-foundation/fluent-ai.git"
  "git@github.com:eten-tech-foundation/fluent-web.git"
)

check_repos() {
  local missing=0
  for i in "${!REPOS[@]}"; do
    if [ -d "${REPOS[$i]}" ]; then
      echo "  [ok] ${REPO_NAMES[$i]} → ${REPOS[$i]}"
    else
      echo "  [missing] ${REPO_NAMES[$i]} → ${REPOS[$i]}"
      missing=1
    fi
  done
  return $missing
}

# ── Commands ───────────────────────────────────────────────────────────────────

cmd="${1:-help}"
shift || true

case "$cmd" in
  up)
    $COMPOSE_CMD up -d --build "$@"
    ;;
  down)
    $COMPOSE_CMD down "$@"
    ;;
  restart)
    $COMPOSE_CMD restart "$@"
    ;;
  logs)
    $COMPOSE_CMD logs -f "$@"
    ;;
  status)
    $COMPOSE_CMD ps "$@"
    ;;
  shell)
    service="${1:-api}"
    if [ "$service" = "db" ]; then
      $COMPOSE_CMD exec db psql -U postgres -d fluent
    else
      $COMPOSE_CMD exec "$service" sh
    fi
    ;;
  run)
    service="${1:?Usage: fluent.sh run <service> <script>}"
    shift
    $COMPOSE_CMD exec "$service" npm run "$@"
    ;;
  test)
    service="${1:?Usage: fluent.sh test <service>}"
    shift
    if [ "$service" = "ai" ]; then
      $COMPOSE_CMD exec ai uv run pytest "$@"
    else
      $COMPOSE_CMD exec "$service" npm run test "$@"
    fi
    ;;

  # ── Database commands ──────────────────────────────────────────────────────

  db:migrate)
    target="${1:-all}"
    case "$target" in
      api)
        echo "Running fluent-api migrations..."
        $COMPOSE_CMD exec api npx drizzle-kit migrate
        ;;
      ai)
        echo "Running fluent-ai migrations..."
        # TODO: uncomment when ai schema migrations are set up
        # $COMPOSE_CMD exec ai uv run alembic upgrade head
        echo "  (no migrations configured yet)"
        ;;
      all)
        read -rp "Run migrations for all services? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          "$0" db:migrate api
          "$0" db:migrate ai
        else
          echo "Aborted."
        fi
        ;;
      web|db)
        echo "The $target service does not have its own migrations."
        exit 1
        ;;
      *)
        echo "Unknown migrate target: $target (use api, ai, or all)"
        exit 1
        ;;
    esac
    ;;
  db:seed)
    target="${1:-all}"
    case "$target" in
      api)
        echo "Running fluent-api seeds..."
        # TODO: uncomment when seed files are created
        # $COMPOSE_CMD exec api npx tsx src/db/seeds/roles.ts
        $COMPOSE_CMD exec api npx tsx src/db/seeds/rbac.ts
        # $COMPOSE_CMD exec api npx tsx src/db/seeds/users.ts
        ;;
      ai)
        echo "Running fluent-ai seeds..."
        # TODO: uncomment when ai seeds are created
        # $COMPOSE_CMD exec ai uv run python src/db/seeds/seed.py
        echo "  (no seeds configured yet)"
        ;;
      all)
        read -rp "Run seeds for all services? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          "$0" db:seed api
          "$0" db:seed ai
        else
          echo "Aborted."
        fi
        ;;
      web|db)
        echo "The $target service does not have its own seeds."
        exit 1
        ;;
      *)
        echo "Unknown seed target: $target (use api, ai, or all)"
        exit 1
        ;;
    esac
    ;;
  db:init)
    echo "Full database initialization (migrations + seeds)..."
    read -rp "This will run all migrations and seeds. Continue? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      "$0" db:migrate api
      "$0" db:migrate ai
      "$0" db:seed api
      "$0" db:seed ai
      echo "Database initialization complete."
    else
      echo "Aborted."
    fi
    ;;
  db:studio)
    echo "Running Drizzle Studio on host (requires local Node.js)..."
    echo "Connects to DB via DATABASE_URL in .env (localhost:${DB_PORT:-5432})"
    npx drizzle-kit studio
    ;;
  db:psql)
    $COMPOSE_CMD exec db psql -U postgres -d fluent
    ;;

  # ── Lifecycle commands ─────────────────────────────────────────────────────

  clean)
    target="${1:-all}"
    echo "This will remove containers AND volumes (full DB reset)."
    read -rp "Continue? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      if [ "$target" = "all" ]; then
        $COMPOSE_CMD down -v
        rm -f "${API_CONTEXT}/.db-initialized"
        rm -f "${AI_CONTEXT}/.db-initialized"
      else
        $COMPOSE_CMD rm -sf "$target"
        # Remove sentinel for the specific service if applicable
        case "$target" in
          api|worker) rm -f "${API_CONTEXT}/.db-initialized" ;;
          ai) rm -f "${AI_CONTEXT}/.db-initialized" ;;
        esac
      fi
    else
      echo "Aborted."
    fi
    ;;
  fresh)
    echo "This will destroy ALL containers, volumes, and images for this project."
    echo "The database will be wiped and everything will be rebuilt from scratch."
    read -rp "Continue? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      $COMPOSE_CMD down -v --rmi local --remove-orphans
      rm -f "${API_CONTEXT}/.db-initialized"
      rm -f "${AI_CONTEXT}/.db-initialized"
      echo ""
      echo "Clean slate. Run './fluent.sh up' to rebuild and start everything."
    else
      echo "Aborted."
    fi
    ;;
  build)
    $COMPOSE_CMD build --no-cache "$@"
    ;;
  check-repos)
    echo "Checking sibling repositories..."
    check_repos
    ;;
  setup)
    echo "=== Fluent Platform Setup ==="
    echo ""

    # Check for sibling repos
    echo "Checking sibling repositories..."
    if ! check_repos; then
      echo ""
      echo "Missing repositories detected. Clone them with:"
      for i in "${!REPOS[@]}"; do
        if [ ! -d "${REPOS[$i]}" ]; then
          echo "  git clone ${REPO_URLS[$i]} ${REPOS[$i]}"
        fi
      done
      echo ""
      read -rp "Clone missing repos now? [y/N] " clone_confirm
      if [[ "$clone_confirm" =~ ^[Yy]$ ]]; then
        for i in "${!REPOS[@]}"; do
          if [ ! -d "${REPOS[$i]}" ]; then
            echo "Cloning ${REPO_NAMES[$i]}..."
            git clone "${REPO_URLS[$i]}" "${REPOS[$i]}"
          fi
        done
      fi
    fi

    echo ""

    # Copy .env files
    if [ ! -f .env ]; then
      cp .env.example .env
      echo "Created .env from .env.example"
    else
      echo ".env already exists, skipping."
    fi

    for i in "${!REPOS[@]}"; do
      if [ -d "${REPOS[$i]}" ] && [ -f "${REPOS[$i]}/.env.example" ] && [ ! -f "${REPOS[$i]}/.env" ]; then
        cp "${REPOS[$i]}/.env.example" "${REPOS[$i]}/.env"
        echo "Created ${REPOS[$i]}/.env from .env.example"
      fi
    done

    echo ""
    echo "Setup complete. Next steps:"
    echo "  1. Fill in credentials in each .env file (Auth0, etc.)"
    echo "  2. Run: ./fluent.sh up"
    ;;
  help|*)
    cat <<'USAGE'
Usage: ./fluent.sh <command> [args]

Services:
  up [service...]        Start all or specific services
  down [service...]      Stop all or specific services
  restart [service...]   Restart specific or all services
  logs [service]         Tail logs (default: all services)
  status                 Show container status
  shell <service>        Open a shell (db opens psql)
  run <service> <script> Run an npm script in a service container
  test <service>         Run tests for a service

Database:
  db:migrate [target]    Run migrations (api, ai, or all)
  db:seed [target]       Run seeds (api, ai, or all)
  db:init                Run all migrations then all seeds
  db:studio              Launch Drizzle Studio on the host
  db:psql                Open psql session

Lifecycle:
  clean [service]        Remove containers and volumes (full reset)
  fresh                  Nuke everything: containers, volumes, and images
  build [service...]     Rebuild containers without cache
  check-repos            Verify sibling repos exist
  setup                  Clone repos, copy .env files, first-time setup
USAGE
    ;;
esac
