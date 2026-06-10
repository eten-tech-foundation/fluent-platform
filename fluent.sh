#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Runtime detection (prefer native Podman pods) ─────────────────────────────

detect_runtime() {
  if command -v podman &>/dev/null; then
    RUNTIME_MODE="podman-pod"
    RUNTIME="podman"
  elif command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    RUNTIME_MODE="docker-compose"
    COMPOSE_CMD="docker compose"
  elif command -v docker &>/dev/null && command -v docker-compose &>/dev/null; then
    RUNTIME_MODE="docker-compose"
    COMPOSE_CMD="docker-compose"
  else
    echo "Error: No container runtime found."
    echo "Install one of:"
    echo "  - Podman (native pods)"
    echo "  - Docker Desktop (includes docker compose V2)"
    echo "  - Docker Engine + docker-compose"
    exit 1
  fi
}

detect_runtime

# ── Color helpers ─────────────────────────────────────────────────────────────

YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
NC='\033[0m'

echo_running() { echo -e "${YELLOW}>>> $1${NC}"; }
echo_success() { echo -e "${GREEN}>>> $1${NC}"; }
echo_error()   { echo -e "${RED}>>> $1${NC}"; }

# ── Configuration ─────────────────────────────────────────────────────────────

POD_NAME="fluent"
DB_PORT="${DB_PORT:-5432}"
API_PORT="${API_PORT:-9999}"
AI_PORT="${AI_PORT:-8200}"
WEB_PORT="${WEB_PORT:-5173}"

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

REPO_SCRIPTS=(
  "fapi.sh"
  "fai.sh"
  "fweb.sh"
)

# ── Repo script delegation ──────────────────────────────────────────────────

run_repo_script() {
  local repo="$1"
  shift
  local ctx
  ctx=$(repo_context "$repo")
  if [ -z "$ctx" ]; then
    echo_error "Unknown repo: $repo"
    exit 1
  fi
  local idx
  case "$repo" in
    api|worker) idx=0 ;;
    ai)         idx=1 ;;
    web)        idx=2 ;;
    *)          echo_error "Unknown repo: $repo"; exit 1 ;;
  esac
  FLUENT_ECOSYSTEM=1 \
    FLUENT_POD_NAME="$POD_NAME" \
    FLUENT_CONTAINER_PREFIX="fluent-" \
    FLUENT_DB_PORT="$DB_PORT" \
    FLUENT_API_PORT="$API_PORT" \
    FLUENT_AI_PORT="$AI_PORT" \
    FLUENT_WEB_PORT="$WEB_PORT" \
    "$ctx/${REPO_SCRIPTS[$idx]}" "$@"
}

# ── Repo helpers ──────────────────────────────────────────────────────────────

check_repos() {
  local missing=0
  for i in "${!REPOS[@]}"; do
    if [ -d "${REPOS[$i]}" ]; then
      echo "  [ok] ${REPO_NAMES[$i]} -> ${REPOS[$i]}"
    else
      echo "  [missing] ${REPO_NAMES[$i]} -> ${REPOS[$i]}"
      missing=1
    fi
  done
  return $missing
}

repo_exists() {
  local repo="$1"
  case "$repo" in
    api) [ -d "$API_CONTEXT" ] ;;
    ai)  [ -d "$AI_CONTEXT" ]  ;;
    web) [ -d "$WEB_CONTEXT" ] ;;
    *)   return 1 ;;
  esac
}

repo_context() {
  local repo="$1"
  case "$repo" in
    api) echo "$API_CONTEXT" ;;
    ai)  echo "$AI_CONTEXT"  ;;
    web) echo "$WEB_CONTEXT" ;;
    *)   echo "" ;;
  esac
}

# ── Podman pod management ───────────────────────────────────────────────────

pod_create() {
  if $RUNTIME pod exists "$POD_NAME" 2>/dev/null; then
    echo_success "Pod $POD_NAME already exists"
    return
  fi
  echo_running "Creating pod $POD_NAME..."
  $RUNTIME pod create \
    --name "$POD_NAME" \
    --share "net,ipc,uts" \
    --network=slirp4netns \
    -p "${DB_PORT}:5432" \
    -p "${API_PORT}:9999" \
    -p "${AI_PORT}:8200" \
    -p "${WEB_PORT}:5173"
}

pod_destroy() {
  if $RUNTIME pod exists "$POD_NAME" 2>/dev/null; then
    echo_running "Removing pod $POD_NAME..."
    $RUNTIME pod rm "$POD_NAME" -f
  fi
}

create_volumes() {
  echo_running "Creating volumes..."
  $RUNTIME volume create fluent-pgdata 2>/dev/null || true
  $RUNTIME volume create fluent-api-node-modules 2>/dev/null || true
  $RUNTIME volume create fluent-worker-node-modules 2>/dev/null || true
  $RUNTIME volume create fluent-web-node-modules 2>/dev/null || true
  $RUNTIME volume create fluent-ai-logs 2>/dev/null || true
  $RUNTIME volume create fluent-web-eslintcache 2>/dev/null || true
}

wait_for_db() {
  echo_running "Waiting for database to be ready..."
  while ! $RUNTIME exec fluent-db pg_isready -U postgres -d fluent 2>/dev/null; do
    sleep 2
  done
  echo_success "Database is ready"
}

# ── Podman container lifecycle ────────────────────────────────────────────────

start_db_container() {
  if $RUNTIME container exists fluent-db 2>/dev/null; then
    echo_success "Database container already exists"
    return
  fi
  echo_running "Starting database container..."
  $RUNTIME run -d \
    --name fluent-db \
    --pod "$POD_NAME" \
    -e POSTGRES_USER=postgres \
    -e POSTGRES_PASSWORD=postgres \
    -e POSTGRES_DB=fluent \
    -v fluent-pgdata:/var/lib/postgresql/data \
    --health-cmd "pg_isready -U postgres -d fluent" \
    --health-interval 5s \
    --health-timeout 5s \
    --health-retries 5 \
    docker.io/postgres:16-alpine
  echo_success "Database container started"
}

# ── Ecosystem commands (Podman) ───────────────────────────────────────────────

podman_up() {
  echo_running "Starting services with Podman..."
  create_volumes
  pod_create
  start_db_container
  wait_for_db
  run_repo_script api up
  run_repo_script ai up
  run_repo_script web up
  echo_success "All services started!"
}

compose_up() {
  local services=("$@")
  if [ ${#services[@]} -eq 0 ]; then
    $COMPOSE_CMD up -d --build
  else
    $COMPOSE_CMD up -d --build --no-deps "${services[@]}"
  fi
}

compose_down() {
  local services=("$@")
  if [ ${#services[@]} -eq 0 ]; then
    $COMPOSE_CMD down
  else
    $COMPOSE_CMD rm -sf "${services[@]}"
  fi
}

compose_restart() {
  local services=("$@")
  if [ ${#services[@]} -eq 0 ]; then
    $COMPOSE_CMD restart
  else
    $COMPOSE_CMD restart "${services[@]}"
  fi
}

compose_logs() {
  $COMPOSE_CMD logs -f "$@"
}

compose_status() {
  $COMPOSE_CMD ps
}

compose_shell() {
  local service="${1:-api}"
  if [ "$service" = "db" ]; then
    $COMPOSE_CMD exec db psql -U postgres -d fluent
  else
    $COMPOSE_CMD exec "$service" sh
  fi
}

compose_clean() {
  local target="${1:-all}"
  if [ "$target" = "all" ]; then
    $COMPOSE_CMD down -v
    rm -f "$API_CONTEXT/.db-initialized" "$AI_CONTEXT/.db-initialized"
    echo_success "All containers and volumes removed"
  else
    $COMPOSE_CMD rm -sf "$target"
    case "$target" in
      api|worker) rm -f "$API_CONTEXT/.db-initialized" ;;
      ai)         rm -f "$AI_CONTEXT/.db-initialized" ;;
    esac
    echo_success "$target container removed"
  fi
}

compose_fresh() {
  $COMPOSE_CMD down -v --rmi local --remove-orphans
  rm -f "$API_CONTEXT/.db-initialized" "$AI_CONTEXT/.db-initialized"
  echo_success "All containers, volumes, and images removed"
}

compose_build() {
  local services=("$@")
  if [ ${#services[@]} -eq 0 ]; then
    $COMPOSE_CMD build --no-cache
  else
    $COMPOSE_CMD build --no-cache "${services[@]}"
  fi
}

# ── Ecosystem commands (Podman) ───────────────────────────────────────────────

podman_down() {
  echo_running "Stopping services..."
  pod_destroy
  echo_success "Services stopped."
}

podman_restart() {
  local services=("$@")
  if [ ${#services[@]} -eq 0 ]; then
    echo_running "Restarting all services..."
    pod_destroy
    podman_up
  else
    for service in "${services[@]}"; do
      echo_running "Restarting $service..."
      $RUNTIME rm -f "fluent-$service" 2>/dev/null || true
      run_repo_script "$service" up
    done
    echo_success "Restarted services: ${services[*]}"
  fi
}

podman_logs() {
  local service="${1:-}"
  if [ -z "$service" ]; then
    $RUNTIME pod logs -f "$POD_NAME"
  else
    $RUNTIME pod logs --container "fluent-$service" -f "$POD_NAME"
  fi
}

podman_status() {
  $RUNTIME pod ps
  if $RUNTIME pod exists "$POD_NAME" 2>/dev/null; then
    echo ""
    echo "Containers in pod $POD_NAME (all states):"
    $RUNTIME ps -a --filter "pod=$POD_NAME"
  fi
}

podman_shell() {
  local service="${1:-api}"
  if [ "$service" = "db" ]; then
    $RUNTIME exec -it fluent-db psql -U postgres -d fluent
  else
    $RUNTIME exec -it "fluent-$service" sh
  fi
}

podman_clean() {
  local target="${1:-all}"
  if [ "$target" = "all" ]; then
    pod_destroy
    $RUNTIME volume rm fluent-pgdata fluent-api-node-modules fluent-worker-node-modules fluent-web-node-modules fluent-ai-logs fluent-web-eslintcache 2>/dev/null || true
    rm -f "$API_CONTEXT/.db-initialized" "$AI_CONTEXT/.db-initialized"
    echo_success "All containers and volumes removed"
  else
    $RUNTIME rm -f "fluent-$target" 2>/dev/null || true
    case "$target" in
      api|worker) rm -f "$API_CONTEXT/.db-initialized" ;;
      ai)         rm -f "$AI_CONTEXT/.db-initialized" ;;
    esac
    echo_success "$target container and related data removed"
  fi
}

podman_fresh() {
  echo_running "This will destroy ALL containers, volumes, and images for this project."
  read -rp "Continue? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    pod_destroy
    $RUNTIME volume rm fluent-pgdata fluent-api-node-modules fluent-worker-node-modules fluent-web-node-modules fluent-ai-logs fluent-web-eslintcache 2>/dev/null || true
    $RUNTIME rmi -f fluent-api fluent-ai fluent-web 2>/dev/null || true
    rm -f "$API_CONTEXT/.db-initialized" "$AI_CONTEXT/.db-initialized"
    echo_success "All containers, volumes, and images removed"
  else
    echo "Aborted."
  fi
}
# ── Repo-specific command dispatchers ───────────────────────────────────────────

# Run a command inside a service container (Docker or Podman)
repo_exec() {
  local repo="$1"
  shift
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    $RUNTIME exec "fluent-$repo" "$@"
  else
    $COMPOSE_CMD exec "$repo" "$@"
  fi
}

# Start a single service and its dependencies
repo_up() {
  local repo="$1"
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    create_volumes
    pod_create
    start_db_container
    wait_for_db
  fi
  run_repo_script "$repo" up
}

repo_down() {
  local repo="$1"
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    $RUNTIME rm -f "fluent-$repo" 2>/dev/null || true
  else
    $COMPOSE_CMD rm -sf "$repo"
  fi
}

repo_restart() {
  local repo="$1"
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    $RUNTIME rm -f "fluent-$repo" 2>/dev/null || true
    run_repo_script "$repo" up
  else
    $COMPOSE_CMD restart "$repo"
  fi
}

repo_logs() {
  local repo="$1"
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    $RUNTIME logs -f "fluent-$repo"
  else
    $COMPOSE_CMD logs -f "$repo"
  fi
}

repo_shell() {
  local repo="$1"
  if [ "$repo" = "db" ]; then
    if [ "$RUNTIME_MODE" = "podman-pod" ]; then
      $RUNTIME exec -it fluent-db psql -U postgres -d fluent
    else
      $COMPOSE_CMD exec db psql -U postgres -d fluent
    fi
  else
    repo_exec "$repo" sh
  fi
}

# Dev/test/format/typecheck commands per repo
handle_repo_cmd() {
  local repo="$1"
  local cmd="$2"
  shift 2

  if ! repo_exists "$repo"; then
    echo_error "Repository context not found: $(repo_context "$repo")"
    echo_error "Run './fluent.sh setup' to clone missing repos."
    exit 1
  fi

  case "$cmd" in
    up)           repo_up "$repo" ;;
    down)         repo_down "$repo" ;;
    restart)      repo_restart "$repo" ;;
    logs)         repo_logs "$repo" ;;
    shell)        repo_shell "$repo" ;;
    *)            run_repo_script "$repo" "$cmd" "$@" ;;
  esac
}
# ── Ecosystem database commands ─────────────────────────────────────────────

db_migrate() {
  local target="${1:-all}"
  case "$target" in
    api)
      echo_running "Running fluent-api migrations..."
      if [ "$RUNTIME_MODE" = "podman-pod" ]; then
        repo_exec api npx drizzle-kit migrate
      else
        $COMPOSE_CMD exec api npx drizzle-kit migrate
      fi
      echo_success "API migrations completed"
      ;;
    ai)
      echo_running "Running fluent-ai migrations..."
      if [ "$RUNTIME_MODE" = "podman-pod" ]; then
        repo_exec ai uv run alembic upgrade head
      else
        $COMPOSE_CMD exec ai uv run alembic upgrade head
      fi
      echo_success "AI migrations completed"
      ;;
    all)
      read -rp "Run migrations for all services? [y/N] " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        db_migrate api
        db_migrate ai
      else
        echo "Aborted."
      fi
      ;;
    web|db)
      echo_error "The $target service does not have its own migrations."
      exit 1
      ;;
    *)
      echo_error "Unknown migrate target: $target (use api, ai, or all)"
      exit 1
      ;;
  esac
}

db_seed() {
  local target="${1:-all}"
  case "$target" in
    api)
      echo_running "Running fluent-api seeds..."
      if [ "$RUNTIME_MODE" = "podman-pod" ]; then
        repo_exec api npx tsx src/db/seeds/roles.ts
        repo_exec api npx tsx src/db/seeds/rbac.ts
      else
        $COMPOSE_CMD exec api npx tsx src/db/seeds/roles.ts
        $COMPOSE_CMD exec api npx tsx src/db/seeds/rbac.ts
      fi
      echo_success "API seeds completed"
      ;;
    ai)
      echo_running "Running fluent-ai seeds..."
      if [ "$RUNTIME_MODE" = "podman-pod" ]; then
        repo_exec ai env PYTHONPATH=/app/src uv run python -m app.db.seeds
      else
        $COMPOSE_CMD exec ai env PYTHONPATH=/app/src uv run python -m app.db.seeds
      fi
      echo_success "AI seeds completed"
      ;;
    all)
      read -rp "Run seeds for all services? [y/N] " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        db_seed api
        db_seed ai
      else
        echo "Aborted."
      fi
      ;;
    web|db)
      echo_error "The $target service does not have its own seeds."
      exit 1
      ;;
    *)
      echo_error "Unknown seed target: $target (use api, ai, or all)"
      exit 1
      ;;
  esac
}

db_init() {
  echo_running "Full database initialization (migrations + seeds)..."
  read -rp "This will run all migrations and seeds. Continue? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    if [ "$RUNTIME_MODE" = "podman-pod" ]; then
      repo_exec api npm run db:setup
      repo_exec ai env PYTHONPATH=/app/src uv run python src/app/db/scripts/setup.py
    else
      $COMPOSE_CMD exec api npm run db:setup
      $COMPOSE_CMD exec ai env PYTHONPATH=/app/src uv run python src/app/db/scripts/setup.py
    fi
    echo_success "Database initialization complete."
  else
    echo "Aborted."
  fi
}

db_psql() {
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    $RUNTIME exec -it fluent-db psql -U postgres -d fluent
  else
    $COMPOSE_CMD exec db psql -U postgres -d fluent
  fi
}

db_studio() {
  echo "Running Drizzle Studio on host (requires local Node.js)..."
  echo "Connects to DB via DATABASE_URL in .env (localhost:${DB_PORT:-5432})"
  npx drizzle-kit studio
}

# ── Ecosystem lifecycle commands ──────────────────────────────────────────────

setup() {
  echo "=== Fluent Platform Setup ==="
  echo ""

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
  echo "  1. Fill in credentials in each .env file (Auth0, API keys, etc.)"
  echo "  2. Run: ./fluent.sh up"
}

ecosystem_build() {
  local services=("$@")
  if [ ${#services[@]} -eq 0 ]; then
    services=("api" "ai" "web")
  fi
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    echo_running "Building specified images: ${services[*]}"
    for service in "${services[@]}"; do
      run_repo_script "$service" build
    done
  else
    if [ ${#services[@]} -eq 0 ]; then
      $COMPOSE_CMD build --no-cache
    else
      $COMPOSE_CMD build --no-cache "${services[@]}"
    fi
  fi
  echo_success "Build complete"
}

ecosystem_clean() {
  local target="${1:-all}"
  echo_running "This will remove containers AND volumes (full DB reset)."
  read -rp "Continue? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    if [ "$RUNTIME_MODE" = "podman-pod" ]; then
      podman_clean "$target"
    else
      compose_clean "$target"
    fi
  else
    echo "Aborted."
  fi
}

ecosystem_fresh() {
  echo_running "This will destroy ALL containers, volumes, and images for this project."
  read -rp "Continue? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    if [ "$RUNTIME_MODE" = "podman-pod" ]; then
      podman_fresh
    else
      compose_fresh
    fi
    echo ""
    echo_success "Clean slate. Run './fluent.sh up' to rebuild and start everything."
  else
    echo "Aborted."
  fi
}

# ── Main command dispatcher ───────────────────────────────────────────────────

echo "Runtime mode: $RUNTIME_MODE"
if [ "$RUNTIME_MODE" = "podman-pod" ]; then
  echo "Using native Podman pods"
else
  echo "Using Docker Compose ($COMPOSE_CMD)"
fi
echo ""

cmd="${1:-help}"
shift || true

# Detect prefix-style repo commands
handle_ecosystem() {
  case "$cmd" in
    up)
      if [ "$RUNTIME_MODE" = "podman-pod" ]; then
        podman_up
      else
        compose_up "$@"
      fi
      ;;
    down)
      if [ "$RUNTIME_MODE" = "podman-pod" ]; then
        podman_down
      else
        compose_down "$@"
      fi
      ;;
    restart)
      if [ "$RUNTIME_MODE" = "podman-pod" ]; then
        podman_restart "$@"
      else
        compose_restart "$@"
      fi
      ;;
    logs)
      if [ "$RUNTIME_MODE" = "podman-pod" ]; then
        podman_logs "$@"
      else
        compose_logs "$@"
      fi
      ;;
    status)
      if [ "$RUNTIME_MODE" = "podman-pod" ]; then
        podman_status
      else
        compose_status
      fi
      ;;
    shell)
      if [ "$RUNTIME_MODE" = "podman-pod" ]; then
        podman_shell "$@"
      else
        compose_shell "$@"
      fi
      ;;
    db:migrate)  db_migrate "$@" ;;
    db:seed)     db_seed "$@" ;;
    db:init)     db_init ;;
    db:psql)     db_psql ;;
    db:studio)   db_studio ;;
    clean)       ecosystem_clean "$@" ;;
    fresh)       ecosystem_fresh ;;
    build)       ecosystem_build "$@" ;;
    setup)       setup ;;
    check-repos) check_repos ;;
    help)
      cat <<'USAGE'
Usage: ./fluent.sh <command> [args]

Ecosystem commands:
  up [service...]         Start all services or specific ones
  down [service...]       Stop all or specific services
  restart [service...]    Restart services
  logs [service]          Tail logs (default: all)
  status                  Show container status
  shell <service>           Open a shell (db opens psql)

Database:
  db:init                 Run all migrations then all seeds
  db:migrate [target]     Run migrations (api, ai, or all)
  db:seed [target]        Run seeds (api, ai, or all)
  db:psql                 Open psql session
  db:studio               Launch Drizzle Studio on the host

Lifecycle:
  clean [service]         Remove containers and volumes
  fresh                   Destroy everything and rebuild
  build [service...]      Rebuild images
  setup                   Clone repos, copy .env files
  check-repos             Verify sibling repos exist

Repo-specific commands (prefix style):
  api up                  Start API service
  api down                Stop API service
  api restart             Restart API
  api logs                Tail API logs
  api shell               Open shell in API container
  api test                Run API test suite
  api lint                Run API linter
  api lint:fix            Run API linter with auto-fix
  api format              Format API code
  api format:check        Check API formatting
  api typecheck           Run API type checker
  api run <script>        Run an npm script in API
  api db:migrate          Run API migrations
  api db:seed             Run API seeds
  api db:generate <name>  Generate a new migration

  ai up                   Start AI service
  ai down                 Stop AI service
  ai restart              Restart AI
  ai logs                 Tail AI logs
  ai shell                Open shell in AI container
  ai test                 Run AI test suite
  ai lint                 Run AI linter (ruff)
  ai lint:fix             Run AI linter with auto-fix
  ai format               Format AI code
  ai format:check         Check AI formatting
  ai typecheck            Run AI type checker (mypy)
  ai run <command>        Run a uv command in AI

  web up                  Start Web service
  web down                Stop Web service
  web restart             Restart Web
  web logs                Tail Web logs
  web shell               Open shell in Web container
  web test                Run Web test suite
  web lint                Run Web linter
  web lint:fix            Run Web linter with auto-fix
  web format              Format Web code
  web format:check        Check Web formatting
  web typecheck           Run Web type checker
  web precheck            Run lint + format:check + typecheck + test
  web preview             Preview production build
  web run <script>        Run a pnpm script in Web

  worker up               Start Worker service
  worker down             Stop Worker service
  worker restart          Restart Worker
  worker logs             Tail Worker logs
  worker shell            Open shell in Worker container
USAGE
      ;;
    *)
      echo_error "Unknown command: $cmd"
      echo "Run './fluent.sh help' for usage."
      exit 1
      ;;
  esac
}

# Prefix-style: fluent.sh <repo> <cmd>
if [ "$cmd" = "api" ] || [ "$cmd" = "ai" ] || [ "$cmd" = "web" ] || [ "$cmd" = "worker" ]; then
  repo="$cmd"
  repo_cmd="${1:-up}"
  shift || true
  handle_repo_cmd "$repo" "$repo_cmd" "$@"
else
  handle_ecosystem "$@"
fi
