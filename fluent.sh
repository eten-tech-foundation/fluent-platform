#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Runtime detection (prefer native Podman pods) ──────────────────────────────────────────

detect_runtime() {
  if command -v podman &>/dev/null; then
    RUNTIME_MODE="podman-pod"
    PODMAN_CMD="podman"
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

# Podman pod configuration ----------------------------------------------------
POD_NAME="fluent-platform"
DB_PORT="${DB_PORT:-5432}"
API_PORT="${API_PORT:-9999}"
AI_PORT="${AI_PORT:-8200}"
WEB_PORT="${WEB_PORT:-5173}"

# Pod management functions ----------------------------------------------------
pod_create() {
  if $PODMAN_CMD pod exists "$POD_NAME" 2>/dev/null; then
    echo "Pod $POD_NAME already exists"
    return
  fi
  
  echo "Creating pod $POD_NAME..."
  $PODMAN_CMD pod create \
    --name "$POD_NAME" \
    --share \
    --publish "${DB_PORT}:5432" \
    --publish "${API_PORT}:9999" \
    --publish "${AI_PORT}:8200" \
    --publish "${WEB_PORT}:5173"
}

pod_destroy() {
  if $PODMAN_CMD pod exists "$POD_NAME" 2>/dev/null; then
    echo "Removing pod $POD_NAME..."
    $PODMAN_CMD pod rm "$POD_NAME" -f
  fi
}

create_volumes() {
  echo "Creating volumes..."
  $PODMAN_CMD volume create fluent-pgdata 2>/dev/null || true
  $PODMAN_CMD volume create fluent-api-node-modules 2>/dev/null || true
  $PODMAN_CMD volume create fluent-worker-node-modules 2>/dev/null || true
  $PODMAN_CMD volume create fluent-web-node-modules 2>/dev/null || true
}

wait_for_db() {
  echo "Waiting for database to be ready..."
  while ! $PODMAN_CMD exec db pg_isready -U postgres -d fluent 2>/dev/null; do
    sleep 2
  done
}

wait_for_api() {
  echo "Waiting for API to be ready..."
  while ! curl -f http://localhost:${API_PORT}/health 2>/dev/null; do
    sleep 2
  done
}

# Service container functions -------------------------------------------------
start_db_container() {
  if $PODMAN_CMD container exists db 2>/dev/null; then
    echo "Database container already exists"
    return
  fi
  
  echo "Starting database container..."
  $PODMAN_CMD run -d \
    --name db \
    --pod "$POD_NAME" \
    -e POSTGRES_USER=postgres \
    -e POSTGRES_PASSWORD=postgres \
    -e POSTGRES_DB=fluent \
    -v fluent-pgdata:/var/lib/postgresql/data \
    -v ./db/init:/docker-entrypoint-initdb.d \
    --health-cmd "pg_isready -U postgres -d fluent" \
    --health-interval 5s \
    --health-timeout 5s \
    --health-retries 5 \
    docker.io/postgres:16-alpine
}

start_api_container() {
  if $PODMAN_CMD container exists api 2>/dev/null; then
    echo "API container already exists"
    return
  fi
  
  # Validate build context
  if [ ! -d "${API_CONTEXT:-../fluent-api}" ]; then
    echo "Error: API context not found: ${API_CONTEXT:-../fluent-api}"
    echo "Please ensure the fluent-api repository is cloned and accessible."
    exit 1
  fi
  
  echo "Building API image..."
  $PODMAN_CMD build -t fluent-api "${API_CONTEXT:-../fluent-api}" -f Dockerfile.dev
  
  echo "Starting API container..."
  $PODMAN_CMD run -d \
    --name api \
    --pod "$POD_NAME" \
    -e DATABASE_URL=postgres://postgres:postgres@localhost:5432/fluent \
    -e EXPORTS_DIR=/app/exports \
    --env-file "${API_CONTEXT:-../fluent-api}/.env" \
    -v "${API_CONTEXT:-../fluent-api}/src:/app/src:ro" \
    -v "${API_CONTEXT:-../fluent-api}/tsconfig.json:/app/tsconfig.json:ro" \
    -v "${API_CONTEXT:-../fluent-api}/drizzle.config.ts:/app/drizzle.config.ts:ro" \
    -v "${API_CONTEXT:-../fluent-api}/docker-entrypoint.sh:/app/docker-entrypoint.sh:ro" \
    -v fluent-api-node-modules:/app/node_modules \
    --tmpfs /tmp:noexec,nosuid,size=64m \
    --tmpfs /app/.cache:noexec,nosuid,size=128m \
    --tmpfs /app/exports:noexec,nosuid,size=256m \
    --security-opt no-new-privileges:true \
    --cap-drop ALL \
    --user 1001:1001 \
    --read-only \
    fluent-api
}

start_worker_container() {
  if $PODMAN_CMD container exists worker 2>/dev/null; then
    echo "Worker container already exists"
    return
  fi
  
  echo "Starting worker container..."
  $PODMAN_CMD run -d \
    --name worker \
    --pod "$POD_NAME" \
    -e DATABASE_URL=postgres://postgres:postgres@localhost:5432/fluent \
    -e EXPORTS_DIR=/app/exports \
    --env-file "${API_CONTEXT:-../fluent-api}/.env" \
    -v "${API_CONTEXT:-../fluent-api}/src:/app/src:ro" \
    -v "${API_CONTEXT:-../fluent-api}/tsconfig.json:/app/tsconfig.json:ro" \
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
}

start_ai_container() {
  if $PODMAN_CMD container exists ai 2>/dev/null; then
    echo "AI container already exists"
    return
  fi
  
  # Validate build context
  if [ ! -d "${AI_CONTEXT:-../fluent-ai}" ]; then
    echo "Error: AI context not found: ${AI_CONTEXT:-../fluent-ai}"
    echo "Please ensure the fluent-ai repository is cloned and accessible."
    exit 1
  fi
  
  echo "Building AI image..."
  $PODMAN_CMD build -t fluent-ai "${AI_CONTEXT:-../fluent-ai}" -f Dockerfile.dev
  
  echo "Starting AI container..."
  $PODMAN_CMD run -d \
    --name ai \
    --pod "$POD_NAME" \
    -e DATABASE_URL="postgresql+asyncpg://postgres:postgres@localhost:5432/fluent" \
    -e ENVIRONMENT=development \
    -e DEBUG=true \
    -e UV_CACHE_DIR=/app/.cache/uv \
    --env-file "${AI_CONTEXT:-../fluent-ai}/.env" \
    -v "${AI_CONTEXT:-../fluent-ai}/src:/app/src:ro" \
    -v "${AI_CONTEXT:-../fluent-ai}/pyproject.toml:/app/pyproject.toml:ro" \
    -v "${AI_CONTEXT:-../fluent-ai}/uv.lock:/app/uv.lock:ro" \
    -v "${AI_CONTEXT:-../fluent-ai}/docker-entrypoint.sh:/app/docker-entrypoint.sh:ro" \
    --tmpfs /tmp:nosuid,size=64m \
    --tmpfs /app/.cache:noexec,nosuid,size=128m \
    --security-opt no-new-privileges:true \
    --cap-drop ALL \
    --user 1001:1001 \
    --read-only \
    fluent-ai
}

start_web_container() {
  if $PODMAN_CMD container exists web 2>/dev/null; then
    echo "Web container already exists"
    return
  fi
  
  # Validate build context
  if [ ! -d "${WEB_CONTEXT:-../fluent-web}" ]; then
    echo "Error: Web context not found: ${WEB_CONTEXT:-../fluent-web}"
    echo "Please ensure the fluent-web repository is cloned and accessible."
    exit 1
  fi
  
  echo "Building Web image..."
  $PODMAN_CMD build -t fluent-web "${WEB_CONTEXT:-../fluent-web}" -f Dockerfile.dev
  
  echo "Starting Web container..."
  $PODMAN_CMD run -d \
    --name web \
    --pod "$POD_NAME" \
    -e COREPACK_HOME=/app/.cache/corepack \
    -v "${WEB_CONTEXT:-../fluent-web}/src:/app/src" \
    -v "${WEB_CONTEXT:-../fluent-web}/public:/app/public:ro" \
    -v "${WEB_CONTEXT:-../fluent-web}/index.html:/app/index.html:ro" \
    -v "${WEB_CONTEXT:-../fluent-web}/vite.config.ts:/app/vite.config.ts" \
    -v "${WEB_CONTEXT:-../fluent-web}/tsconfig.json:/app/tsconfig.json:ro" \
    -v "${WEB_CONTEXT:-../fluent-web}/tsconfig.node.json:/app/tsconfig.node.json:ro" \
    -v "${WEB_CONTEXT:-../fluent-web}/components.json:/app/components.json:ro" \
    -v "${WEB_CONTEXT:-../fluent-web}/eslint.config.js:/app/eslint.config.js:ro" \
    -v "${WEB_CONTEXT:-../fluent-web}/.env:/app/.env:ro" \
    -v fluent-web-node-modules:/app/node_modules \
    --tmpfs /tmp:nosuid,size=64m \
    --tmpfs /app/.cache:noexec,nosuid,uid=1001,gid=1001,size=128m \
    --security-opt no-new-privileges:true \
    --cap-drop ALL \
    --user 1001:1001 \
    fluent-web
}

# Podman-specific command functions -------------------------------------------
podman_up() {
  echo "Starting services with Podman pods..."
  create_volumes
  pod_create
  start_db_container
  wait_for_db
  start_api_container
  wait_for_api
  start_worker_container
  start_ai_container
  start_web_container
  echo "All services started!"
}

podman_down() {
  echo "Stopping services..."
  pod_destroy
  echo "Services stopped."
}

podman_logs() {
  local service="${1:-}"
  if [ -z "$service" ]; then
    $PODMAN_CMD logs -f --pod "$POD_NAME"
  else
    $PODMAN_CMD logs -f "$service"
  fi
}

podman_status() {
  $PODMAN_CMD pod ps
  if $PODMAN_CMD pod exists "$POD_NAME" 2>/dev/null; then
    echo ""
    echo "Containers in pod $POD_NAME:"
    $PODMAN_CMD ps --pod "$POD_NAME"
  fi
}

podman_shell() {
  local service="${1:-api}"
  if [ "$service" = "db" ]; then
    $PODMAN_CMD exec db psql -U postgres -d fluent
  else
    $PODMAN_CMD exec "$service" sh
  fi
}

podman_run() {
  local service="${1:?Usage: fluent.sh run <service> <script>}"
  shift
  if [ "$service" = "ai" ]; then
    $PODMAN_CMD exec "$service" uv run "$@"
  else
    $PODMAN_CMD exec "$service" npm run "$@"
  fi
}

podman_test() {
  local service="${1:?Usage: fluent.sh test <service>}"
  shift
  if [ "$service" = "ai" ]; then
    $PODMAN_CMD exec ai uv run pytest "$@"
  else
    $PODMAN_CMD exec "$service" npm run test "$@"
  fi
}

# Docker Compose fallback functions -------------------------------------------
compose_up() {
  $COMPOSE_CMD up -d --build "$@"
}

compose_down() {
  $COMPOSE_CMD down "$@"
}

compose_logs() {
  $COMPOSE_CMD logs -f "$@"
}

compose_status() {
  $COMPOSE_CMD ps "$@"
}

compose_shell() {
  local service="${1:-api}"
  if [ "$service" = "db" ]; then
    $COMPOSE_CMD exec db psql -U postgres -d fluent
  else
    $COMPOSE_CMD exec "$service" sh
  fi
}

compose_run() {
  local service="${1:?Usage: fluent.sh run <service> <script>}"
  shift
  if [ "$service" = "ai" ]; then
    $COMPOSE_CMD exec "$service" uv run "$@"
  else
    $COMPOSE_CMD exec "$service" npm run "$@"
  fi
}

compose_test() {
  local service="${1:?Usage: fluent.sh test <service>}"
  shift
  if [ "$service" = "ai" ]; then
    $COMPOSE_CMD exec ai uv run pytest "$@"
  else
    $COMPOSE_CMD exec "$service" npm run test "$@"
  fi
}

# Runtime-specific command dispatch -------------------------------------------
up() {
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    podman_up "$@"
  else
    compose_up "$@"
  fi
}

down() {
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    podman_down "$@"
  else
    compose_down "$@"
  fi
}

logs() {
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    podman_logs "$@"
  else
    compose_logs "$@"
  fi
}

status() {
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    podman_status "$@"
  else
    compose_status "$@"
  fi
}

shell() {
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    podman_shell "$@"
  else
    compose_shell "$@"
  fi
}

run() {
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    podman_run "$@"
  else
    compose_run "$@"
  fi
}

test() {
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    podman_test "$@"
  else
    compose_test "$@"
  fi
}

# Runtime-specific database commands -------------------------------------------
db_migrate() {
  local target="${1:-all}"
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    case "$target" in
      api)
        echo "Running fluent-api migrations..."
        $PODMAN_CMD exec api npx drizzle-kit migrate
        ;;
      ai)
        echo "Running fluent-ai migrations..."
        echo "  (no migrations configured yet)"
        ;;
      all)
        read -rp "Run migrations for all services? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          $PODMAN_CMD exec api npx drizzle-kit migrate
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
  else
    case "$target" in
      api)
        echo "Running fluent-api migrations..."
        $COMPOSE_CMD exec api npx drizzle-kit migrate
        ;;
      ai)
        echo "Running fluent-ai migrations..."
        echo "  (no migrations configured yet)"
        ;;
      all)
        read -rp "Run migrations for all services? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          $COMPOSE_CMD exec api npx drizzle-kit migrate
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
  fi
}

db_seed() {
  local target="${1:-all}"
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    case "$target" in
      api)
        echo "Running fluent-api seeds..."
        $PODMAN_CMD exec api npx tsx src/db/seeds/rbac.ts
        ;;
      ai)
        echo "Running fluent-ai seeds..."
        echo "  (no seeds configured yet)"
        ;;
      all)
        read -rp "Run seeds for all services? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          $PODMAN_CMD exec api npx tsx src/db/seeds/rbac.ts
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
  else
    case "$target" in
      api)
        echo "Running fluent-api seeds..."
        $COMPOSE_CMD exec api npx tsx src/db/seeds/rbac.ts
        ;;
      ai)
        echo "Running fluent-ai seeds..."
        echo "  (no seeds configured yet)"
        ;;
      all)
        read -rp "Run seeds for all services? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
          $COMPOSE_CMD exec api npx tsx src/db/seeds/rbac.ts
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
  fi
}

db_init() {
  echo "Full database initialization (migrations + seeds)..."
  read -rp "This will run all migrations and seeds. Continue? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    db_migrate api
    db_seed api
    echo "Database initialization complete."
  else
    echo "Aborted."
  fi
}

db_psql() {
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    $PODMAN_CMD exec db psql -U postgres -d fluent
  else
    $COMPOSE_CMD exec db psql -U postgres -d fluent
  fi
}

# Runtime-specific lifecycle commands -------------------------------------------
clean() {
  local target="${1:-all}"
  echo "This will remove containers AND volumes (full DB reset)."
  read -rp "Continue? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    if [ "$RUNTIME_MODE" = "podman-pod" ]; then
      if [ "$target" = "all" ]; then
        pod_destroy
        $PODMAN_CMD volume rm fluent-pgdata fluent-api-node-modules fluent-worker-node-modules fluent-web-node-modules 2>/dev/null || true
        rm -f "${API_CONTEXT:-../fluent-api}/.db-initialized"
        rm -f "${AI_CONTEXT:-../fluent-ai}/.db-initialized"
      else
        $PODMAN_CMD rm -f "$target" 2>/dev/null || true
        case "$target" in
          api|worker) rm -f "${API_CONTEXT:-../fluent-api}/.db-initialized" ;;
          ai) rm -f "${AI_CONTEXT:-../fluent-ai}/.db-initialized" ;;
        esac
      fi
    else
      if [ "$target" = "all" ]; then
        $COMPOSE_CMD down -v
        rm -f "${API_CONTEXT:-../fluent-api}/.db-initialized"
        rm -f "${AI_CONTEXT:-../fluent-ai}/.db-initialized"
      else
        $COMPOSE_CMD rm -sf "$target"
        case "$target" in
          api|worker) rm -f "${API_CONTEXT:-../fluent-api}/.db-initialized" ;;
          ai) rm -f "${AI_CONTEXT:-../fluent-ai}/.db-initialized" ;;
        esac
      fi
    fi
  else
    echo "Aborted."
  fi
}

fresh() {
  echo "This will destroy ALL containers, volumes, and images for this project."
  echo "The database will be wiped and everything will be rebuilt from scratch."
  read -rp "Continue? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    if [ "$RUNTIME_MODE" = "podman-pod" ]; then
      pod_destroy
      $PODMAN_CMD volume rm fluent-pgdata fluent-api-node-modules fluent-worker-node-modules fluent-web-node-modules 2>/dev/null || true
      $PODMAN_CMD rmi -f fluent-api fluent-ai fluent-web 2>/dev/null || true
      rm -f "${API_CONTEXT:-../fluent-api}/.db-initialized"
      rm -f "${AI_CONTEXT:-../fluent-ai}/.db-initialized"
    else
      $COMPOSE_CMD down -v --rmi local --remove-orphans
      rm -f "${API_CONTEXT:-../fluent-api}/.db-initialized"
      rm -f "${AI_CONTEXT:-../fluent-ai}/.db-initialized"
    fi
    echo ""
    echo "Clean slate. Run './fluent.sh up' to rebuild and start everything."
  else
    echo "Aborted."
  fi
}

build() {
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    echo "Building all images..."
    
    # Validate build contexts exist
    local missing_contexts=()
    [ ! -d "${API_CONTEXT:-../fluent-api}" ] && missing_contexts+=("API context: ${API_CONTEXT:-../fluent-api}")
    [ ! -d "${AI_CONTEXT:-../fluent-ai}" ] && missing_contexts+=("AI context: ${AI_CONTEXT:-../fluent-ai}")
    [ ! -d "${WEB_CONTEXT:-../fluent-web}" ] && missing_contexts+=("Web context: ${WEB_CONTEXT:-../fluent-web}")
    
    if [ ${#missing_contexts[@]} -gt 0 ]; then
      echo "Error: Missing build contexts:"
      for context in "${missing_contexts[@]}"; do
        echo "  - $context"
      done
      echo ""
      echo "Please ensure all repositories are cloned and accessible, or run:"
      echo "  ./fluent.sh setup"
      exit 1
    fi
    
    $PODMAN_CMD build -t fluent-api "${API_CONTEXT:-../fluent-api}" -f Dockerfile.dev
    $PODMAN_CMD build -t fluent-ai "${AI_CONTEXT:-../fluent-ai}" -f Dockerfile.dev
    $PODMAN_CMD build -t fluent-web "${WEB_CONTEXT:-../fluent-web}" -f Dockerfile.dev
  else
    $COMPOSE_CMD build --no-cache "$@"
  fi
}

# Runtime-specific restart command -------------------------------------------
restart() {
  if [ "$RUNTIME_MODE" = "podman-pod" ]; then
    local services=("$@")
    if [ ${#services[@]} -eq 0 ]; then
      echo "Restarting all services..."
      pod_destroy
      podman_up
    else
      for service in "${services[@]}"; do
        echo "Restarting $service..."
        $PODMAN_CMD rm -f "$service" 2>/dev/null || true
        case "$service" in
          db) start_db_container ;;
          api) start_api_container ;;
          worker) start_worker_container ;;
          ai) start_ai_container ;;
          web) start_web_container ;;
          *) echo "Unknown service: $service" ;;
        esac
      done
    fi
  else
    $COMPOSE_CMD restart "$@"
  fi
}

# Runtime mode display --------------------------------------------------------
echo "Runtime mode: $RUNTIME_MODE"
if [ "$RUNTIME_MODE" = "podman-pod" ]; then
  echo "Using native Podman pods"
else
  echo "Using Docker Compose"
fi
echo ""

# Repo path helpers ----------------------------------------------------------

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
    up "$@"
    ;;
  down)
    down "$@"
    ;;
  restart)
    restart "$@"
    ;;
  logs)
    logs "$@"
    ;;
  status)
    status "$@"
    ;;
  shell)
    shell "$@"
    ;;
  run)
    run "$@"
    ;;
  test)
    test "$@"
    ;;

  # ── Database commands ──────────────────────────────────────────────────────

  db:migrate)
    db_migrate "$@"
    ;;
  db:seed)
    db_seed "$@"
    ;;
  db:init)
    db_init
    ;;
  db:studio)
    echo "Running Drizzle Studio on host (requires local Node.js)..."
    echo "Connects to DB via DATABASE_URL in .env (localhost:${DB_PORT:-5432})"
    npx drizzle-kit studio
    ;;
  db:psql)
    db_psql
    ;;

  # ── Lifecycle commands ─────────────────────────────────────────────────────

  clean)
    clean "$@"
    ;;
  fresh)
    fresh
    ;;
  build)
    build "$@"
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
