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

wait_for_api() {
  echo_running "Waiting for API to be ready..."
  local retries=30
  while [ "$retries" -gt 0 ]; do
    if curl -sf "http://localhost:${API_PORT}/health" 2>/dev/null; then
      echo_success "API is ready"
      return
    fi
    retries=$((retries - 1))
    echo -n "."
    sleep 3
  done
  echo ""
  echo_error "API did not become healthy in time"
  exit 1
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
    -v "$SCRIPT_DIR/db/init:/docker-entrypoint-initdb.d:ro" \
    --health-cmd "pg_isready -U postgres -d fluent" \
    --health-interval 5s \
    --health-timeout 5s \
    --health-retries 5 \
    docker.io/postgres:16-alpine
  echo_success "Database container started"
}

start_api_container() {
  if $RUNTIME container exists fluent-api 2>/dev/null; then
    echo_success "API container already exists"
    return
  fi
  if [ ! -d "$API_CONTEXT" ]; then
    echo_error "API context not found: $API_CONTEXT"
    exit 1
  fi
  echo_running "Building API image..."
  $RUNTIME build -t fluent-api "$API_CONTEXT" -f Dockerfile.dev
  local -a env_flags=(
    -e "NODE_ENV=development"
    -e "DATABASE_URL=postgres://postgres:postgres@localhost:5432/fluent"
    -e "EXPORTS_DIR=/app/exports"
  )
  if [[ -f "$API_CONTEXT/.env" ]]; then
    env_flags+=(--env-file "$API_CONTEXT/.env")
  fi
  echo_running "Starting API container..."
  $RUNTIME run -d \
    --name fluent-api \
    --pod "$POD_NAME" \
    "${env_flags[@]}" \
    -v "$API_CONTEXT/src:/app/src:ro" \
    -v "$API_CONTEXT/tsconfig.json:/app/tsconfig.json:ro" \
    -v "$API_CONTEXT/drizzle.config.ts:/app/drizzle.config.ts:ro" \
    -v "$API_CONTEXT/docker-entrypoint.sh:/app/docker-entrypoint.sh:ro" \
    -v fluent-api-node-modules:/app/node_modules \
    --tmpfs /tmp:noexec,nosuid,size=64m \
    --tmpfs /app/.cache:noexec,nosuid,size=128m \
    --tmpfs /app/exports:noexec,nosuid,size=256m \
    --security-opt no-new-privileges:true \
    --cap-drop ALL \
    --user 1001:1001 \
    --read-only \
    --health-cmd "curl -f http://localhost:9999/health" \
    --health-interval 10s \
    --health-timeout 5s \
    --health-retries 5 \
    --health-start-period 15s \
    fluent-api
  echo_success "API container started"
}

start_worker_container() {
  if $RUNTIME container exists fluent-worker 2>/dev/null; then
    echo_success "Worker container already exists"
    return
  fi
  local -a env_flags=(
    -e "NODE_ENV=development"
    -e "DATABASE_URL=postgres://postgres:postgres@localhost:5432/fluent"
    -e "EXPORTS_DIR=/app/exports"
  )
  if [[ -f "$API_CONTEXT/.env" ]]; then
    env_flags+=(--env-file "$API_CONTEXT/.env")
  fi
  echo_running "Starting worker container..."
  $RUNTIME run -d \
    --name fluent-worker \
    --pod "$POD_NAME" \
    "${env_flags[@]}" \
    -v "$API_CONTEXT/src:/app/src:ro" \
    -v "$API_CONTEXT/tsconfig.json:/app/tsconfig.json:ro" \
    -v fluent-worker-node-modules:/app/node_modules \
    --tmpfs /tmp:noexec,nosuid,size=64m \
    --tmpfs /app/.cache:noexec,nosuid,size=128m \
    --tmpfs /app/exports:noexec,nosuid,size=256m \
    --security-opt no-new-privileges:true \
    --cap-drop ALL \
    --user 1001:1001 \
    --read-only \
    fluent-api \
    dumb-init -- npx tsx watch src/workers/standalone-worker.ts
  echo_success "Worker container started"
}

start_ai_container() {
  if $RUNTIME container exists fluent-ai 2>/dev/null; then
    echo_success "AI container already exists"
    return
  fi
  if [ ! -d "$AI_CONTEXT" ]; then
    echo_error "AI context not found: $AI_CONTEXT"
    exit 1
  fi
  echo_running "Building AI image..."
  $RUNTIME build -t fluent-ai "$AI_CONTEXT" -f Dockerfile.dev
  local -a env_flags=(
    -e "DATABASE_URL=postgresql+asyncpg://postgres:postgres@localhost:5432/fluent"
    -e "ENVIRONMENT=development"
    -e "DEBUG=true"
    -e "UV_CACHE_DIR=/app/.cache/uv"
  )
  if [[ -f "$AI_CONTEXT/.env" ]]; then
    env_flags+=(--env-file "$AI_CONTEXT/.env")
  fi
  echo_running "Starting AI container..."
  $RUNTIME run -d \
    --name fluent-ai \
    --pod "$POD_NAME" \
    "${env_flags[@]}" \
    -v "$AI_CONTEXT/src:/app/src:ro" \
    -v "$AI_CONTEXT/tests:/app/tests:ro" \
    -v "$AI_CONTEXT/pyproject.toml:/app/pyproject.toml:ro" \
    -v "$AI_CONTEXT/uv.lock:/app/uv.lock:ro" \
    -v "$AI_CONTEXT/docker-entrypoint.sh:/app/docker-entrypoint.sh:ro" \
    -v fluent-ai-logs:/app/logs \
    --tmpfs /tmp:nosuid,size=64m \
    --tmpfs /app/.cache:noexec,nosuid,size=128m \
    --security-opt no-new-privileges:true \
    --cap-drop ALL \
    --user 1001:1001 \
    --read-only \
    fluent-ai
  echo_success "AI container started"
}

start_web_container() {
  if $RUNTIME container exists fluent-web 2>/dev/null; then
    echo_success "Web container already exists"
    return
  fi
  if [ ! -d "$WEB_CONTEXT" ]; then
    echo_error "Web context not found: $WEB_CONTEXT"
    exit 1
  fi
  echo_running "Building Web image..."
  $RUNTIME build -t fluent-web "$WEB_CONTEXT" -f Dockerfile.dev
  local -a env_flags=(
    -e "COREPACK_HOME=/app/.cache/corepack"
    -e "COREPACK_ENABLE_AUTO_PIN=0"
    -e "VITE_API_URL=http://localhost:${API_PORT}"
  )
  if [[ -f "$WEB_CONTEXT/.env" ]]; then
    env_flags+=(--env-file "$WEB_CONTEXT/.env")
  fi
  echo_running "Starting Web container..."
  $RUNTIME run -d \
    --name fluent-web \
    --pod "$POD_NAME" \
    "${env_flags[@]}" \
    -v "$WEB_CONTEXT/src:/app/src" \
    -v "$WEB_CONTEXT/public:/app/public:ro" \
    -v "$WEB_CONTEXT/index.html:/app/index.html:ro" \
    -v "$WEB_CONTEXT/vite.config.ts:/app/vite.config.ts" \
    -v "$WEB_CONTEXT/tsconfig.json:/app/tsconfig.json:ro" \
    -v "$WEB_CONTEXT/tsconfig.node.json:/app/tsconfig.node.json:ro" \
    -v "$WEB_CONTEXT/components.json:/app/components.json:ro" \
    -v "$WEB_CONTEXT/eslint.config.js:/app/eslint.config.js:ro" \
    -v "$WEB_CONTEXT/.prettierrc.js:/app/.prettierrc.js:ro" \
    -v "$WEB_CONTEXT/.prettierignore:/app/.prettierignore:ro" \
    -v "$WEB_CONTEXT/.env:/app/.env:ro" \
    -v fluent-web-node-modules:/app/node_modules \
    -v fluent-web-eslintcache:/app/.eslintcache \
    --tmpfs /tmp:nosuid,size=64m \
    --tmpfs /app/.cache:noexec,nosuid,uid=1001,gid=1001,size=128m \
    --security-opt no-new-privileges:true \
    --cap-drop ALL \
    --user 1001:1001 \
    fluent-web
  echo_success "Web container started"
}
# ── Ecosystem commands (Docker Compose) ───────────────────────────────────────

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

podman_up() {
  echo_running "Starting services with Podman..."
  create_volumes
  pod_create
  start_db_container
  wait_for_db
  start_api_container
  wait_for_api
  start_worker_container
  start_ai_container
  start_web_container
  echo_success "All services started!"
}

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
      case "$service" in
        db)     start_db_container ;;
        api)    start_api_container ;;
        worker) start_worker_container ;;
        ai)     start_ai_container ;;
        web)    start_web_container ;;
        *)      echo_error "Unknown service: $service" ;;
      esac
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
    case "$repo" in
      db)     : ;;  # already started
      api)    start_api_container ; wait_for_api ;;
      worker) start_api_container; wait_for_api; start_worker_container ;;
      ai)     start_api_container; wait_for_api; start_ai_container ;;
      web)    start_api_container; wait_for_api; start_web_container ;;
    esac
    echo_success "$repo started"
  else
    $COMPOSE_CMD up -d --build "$repo"
  fi
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
    case "$repo" in
      db)     start_db_container ;;
      api)    start_api_container ; wait_for_api ;;
      worker) start_worker_container ;;
      ai)     start_ai_container ;;
      web)    start_web_container ;;
    esac
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

  case "$repo" in
    api)
      case "$cmd" in
        up)           repo_up api ;;
        down)         repo_down api ;;
        restart)      repo_restart api ;;
        logs)         repo_logs api ;;
        shell)        repo_shell api ;;
        test)         repo_exec api npm run test "$@" ;;
        lint)         repo_exec api npm run lint ;;
        lint:fix)     repo_exec api npm run lint:fix ;;
        format)       repo_exec api npm run format ;;
        format:check) repo_exec api npm run format:check ;;
        typecheck)    repo_exec api npm run typecheck ;;
        run)          repo_exec api npm run "$@" ;;
        db:migrate)   repo_exec api npx drizzle-kit migrate ;;
        db:seed)
          repo_exec api npx tsx src/db/seeds/roles.ts
          repo_exec api npx tsx src/db/seeds/rbac.ts
          ;;
        db:generate)
          local name="${1:?Usage: fluent.sh api db:generate <name>}"
          repo_exec api npx drizzle-kit generate --name "$name"
          ;;
        db:dump-schema)
          local output="${1:-}"
          if [ -z "$output" ]; then
            output="$SCRIPT_DIR/db/schema-dump.sql"
          fi
          echo_running "Dumping API public schema to $output..."
          {
            echo "-- Schema-only dump of fluent-api public tables."
            echo "-- Auto-generated. Regenerate with: ./fluent.sh api db:dump-schema [path]"
            if [ "$RUNTIME_MODE" = "podman-pod" ]; then
              $RUNTIME exec fluent-db pg_dump -U postgres --schema-only --schema=public fluent
            else
              $COMPOSE_CMD exec -T db pg_dump -U postgres --schema-only --schema=public fluent
            fi
          } > "$output"
          echo_success "Schema dumped to $output"
          ;;
        *)            echo_error "Unknown api command: $cmd"; exit 1 ;;
      esac
      ;;
    ai)
      case "$cmd" in
        up)           repo_up ai ;;
        down)         repo_down ai ;;
        restart)      repo_restart ai ;;
        logs)         repo_logs ai ;;
        shell)        repo_shell ai ;;
        test)         repo_exec ai uv run pytest tests/ -v "$@" ;;
        lint)         repo_exec ai uv run ruff check ;;
        lint:fix)     repo_exec ai uv run ruff check --fix ;;
        format)       repo_exec ai uv run ruff format ;;
        format:check) repo_exec ai uv run ruff format --check ;;
        typecheck)    repo_exec ai uv run mypy src ;;
        run)          repo_exec ai uv run "$@" ;;
        db:migrate)   echo "(no migrations configured yet)" ;;
        db:seed)      echo "(no seeds configured yet)" ;;
        *)            echo_error "Unknown ai command: $cmd"; exit 1 ;;
      esac
      ;;
    web)
      case "$cmd" in
        up)           repo_up web ;;
        down)         repo_down web ;;
        restart)      repo_restart web ;;
        logs)         repo_logs web ;;
        shell)        repo_shell web ;;
        test)         repo_exec web pnpm test "$@" ;;
        lint)         repo_exec web pnpm lint ;;
        lint:fix)     repo_exec web pnpm lint:fix ;;
        format)       repo_exec web pnpm format ;;
        format:check) repo_exec web pnpm format:check ;;
        typecheck)    repo_exec web pnpm typecheck ;;
        precheck)     repo_exec web pnpm precheck ;;
        preview)      repo_exec web pnpm preview ;;
        run)          repo_exec web pnpm "$@" ;;
        *)            echo_error "Unknown web command: $cmd"; exit 1 ;;
      esac
      ;;
    worker)
      case "$cmd" in
        up)           repo_up worker ;;
        down)         repo_down worker ;;
        restart)      repo_restart worker ;;
        logs)         repo_logs worker ;;
        shell)        repo_shell worker ;;
        *)            echo_error "Worker does not support '$cmd'. Use 'api' for dev commands."; exit 1 ;;
      esac
      ;;
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
      echo "  (no migrations configured yet)"
      ;;
    all)
      read -rp "Run migrations for all services? [y/N] " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        db_migrate api
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
      echo "  (no seeds configured yet)"
      ;;
    all)
      read -rp "Run seeds for all services? [y/N] " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        db_seed api
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
    db_migrate api
    db_seed api
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
      case "$service" in
        api|worker) $RUNTIME build -t fluent-api "$API_CONTEXT" -f Dockerfile.dev ;;
        ai)         $RUNTIME build -t fluent-ai "$AI_CONTEXT" -f Dockerfile.dev ;;
        web)        $RUNTIME build -t fluent-web "$WEB_CONTEXT" -f Dockerfile.dev ;;
        *)          echo_error "Unknown buildable service: $service"; exit 1 ;;
      esac
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
  db:migrate [target]     Run migrations (api, ai, or all)
  db:seed [target]        Run seeds (api, ai, or all)
  db:init                 Run all migrations then all seeds
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
  api db:dump-schema      Dump API schema for fluent-ai sync

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
  handle_ecosystem "$cmd" "$@"
fi
