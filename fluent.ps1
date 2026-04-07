#Requires -Version 5.1
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",
    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$Args
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# ── Runtime detection (prefer native Podman pods) ──────────────────────────────────────────

function Get-RuntimeMode {
    if (Get-Command podman -ErrorAction SilentlyContinue) {
        return @{
            Mode = "podman-pod"
            Command = "podman"
        }
    }
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $v2 = & docker compose version 2>&1
        if ($LASTEXITCODE -eq 0) { 
            return @{
                Mode = "docker-compose"
                Command = "docker compose"
            }
        }
        if (Get-Command docker-compose -ErrorAction SilentlyContinue) { 
            return @{
                Mode = "docker-compose"
                Command = "docker-compose"
            }
        }
    }
    Write-Error @"
No container runtime found. Install one of:
  - Podman (native pods)
  - Docker Desktop (includes docker compose V2)
  - Docker Engine + docker-compose
"@
    exit 1
}

$Runtime = Get-RuntimeMode
$RuntimeMode = $Runtime.Mode
$ContainerCmd = $Runtime.Command

# Color helpers -----------------------------------------------------------------
$Yellow = "`e[1;33m"
$Green = "`e[1;32m"
$Red = "`e[1;31m"
$NoColor = "`e[0m"

function Write-Running {
    param([string]$Message)
    Write-Host "${Yellow}>>> $Message${NoColor}"
}

function Write-Success {
    param([string]$Message)
    Write-Host "${Green}>>> $Message${NoColor}"
}

function Write-Error-Color {
    param([string]$Message)
    Write-Host "${Red}>>> $Message${NoColor}"
}

# Podman pod configuration ----------------------------------------------------
$PodName = "fluent"
$DbPort = if ($env:DB_PORT) { $env:DB_PORT } else { "5432" }
$ApiPort = if ($env:API_PORT) { $env:API_PORT } else { "9999" }
$AiPort = if ($env:AI_PORT) { $env:AI_PORT } else { "8200" }
$WebPort = if ($env:WEB_PORT) { $env:WEB_PORT } else { "5173" }

# Pod management functions ----------------------------------------------------
function New-Pod {
    $existing = & $ContainerCmd pod exists $PodName 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Pod $PodName already exists"
        return
    }
    
    Write-Running "Creating pod $PodName..."
    & $ContainerCmd pod create --name $PodName --share "net,ipc,uts" `
        -p "${DbPort}:5432" `
        -p "${ApiPort}:9999" `
        -p "${AiPort}:8200" `
        -p "${WebPort}:5173"
}

function Remove-Pod {
    $existing = & $ContainerCmd pod exists $PodName 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Running "Removing pod $PodName..."
        & $ContainerCmd pod rm $PodName -f
    }
}

function New-Volumes {
    Write-Running "Creating volumes..."
    & $ContainerCmd volume create fluent-pgdata 2>$null | Out-Null
    & $ContainerCmd volume create fluent-api-node-modules 2>$null | Out-Null
    & $ContainerCmd volume create fluent-worker-node-modules 2>$null | Out-Null
    & $ContainerCmd volume create fluent-web-node-modules 2>$null | Out-Null
}

function Wait-Database {
    Write-Running "Waiting for database to be ready..."
    do {
        Start-Sleep -Seconds 2
        & $ContainerCmd exec db pg_isready -U postgres -d fluent 2>$null | Out-Null
    } while ($LASTEXITCODE -ne 0)
    Write-Success "Database is ready"
}

function Wait-Api {
    Write-Running "Waiting for API to be ready..."
    do {
        Start-Sleep -Seconds 2
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:${ApiPort}/health" -TimeoutSec 2 -ErrorAction Stop
        } catch {
            continue
        }
    } while ($response.StatusCode -ne 200)
    Write-Success "API is ready"
}

# Service container functions -------------------------------------------------
function Start-DatabaseContainer {
    $existing = & $ContainerCmd container exists db 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Database container already exists"
        return
    }
    
    Write-Running "Starting database container..."
    & $ContainerCmd run -d --name fluent_db --pod $PodName `
        -e POSTGRES_USER=postgres `
        -e POSTGRES_PASSWORD=postgres `
        -e POSTGRES_DB=fluent `
        -v fluent-pgdata:/var/lib/postgresql/data `
        -v ./db/init:/docker-entrypoint-initdb.d `
        --health-cmd "pg_isready -U postgres -d fluent" `
        --health-interval 5s `
        --health-timeout 5s `
        --health-retries 5 `
        docker.io/postgres:16-alpine
    Write-Success "Database container started"
}

function Start-ApiContainer {
    $existing = & $ContainerCmd container exists api 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "API container already exists"
        return
    }
    
    # Validate build context
    $apiContext = if ($env:API_CONTEXT) { $env:API_CONTEXT } else { "../fluent-api" }
    if (-not (Test-Path $apiContext)) {
        Write-Error-Color "API context not found: $apiContext"
        Write-Error-Color "Please ensure the fluent-api repository is cloned and accessible."
        exit 1
    }
    
    Write-Running "Building API image..."
    & $ContainerCmd build -t fluent-api $apiContext -f Dockerfile.dev
    
    Write-Running "Starting API container..."
    & $ContainerCmd run -d --name fluent_api --pod $PodName `
        -e DATABASE_URL=postgres://postgres:postgres@localhost:5432/fluent `
        -e EXPORTS_DIR=/app/exports `
        --env-file "$apiContext/.env" `
        -v "$apiContext/src:/app/src:ro" `
        -v "$apiContext/tsconfig.json:/app/tsconfig.json:ro" `
        -v "$apiContext/drizzle.config.ts:/app/drizzle.config.ts:ro" `
        -v "$apiContext/docker-entrypoint.sh:/app/docker-entrypoint.sh:ro" `
        -v fluent-api-node-modules:/app/node_modules `
        --tmpfs /tmp:noexec,nosuid,size=64m `
        --tmpfs /app/.cache:noexec,nosuid,size=128m `
        --tmpfs /app/exports:noexec,nosuid,size=256m `
        --security-opt no-new-privileges:true `
        --cap-drop ALL `
        --user 1001:1001 `
        --read-only `
        --health-cmd "curl -f http://localhost:9999/health" `
        --health-interval 10s `
        --health-timeout 5s `
        --health-retries 5 `
        --health-start-period 15s `
        fluent-api
    Write-Success "API container started"
}

function Start-WorkerContainer {
    $existing = & $ContainerCmd container exists worker 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Worker container already exists"
        return
    }
    
    Write-Running "Starting worker container..."
    $apiContext = if ($env:API_CONTEXT) { $env:API_CONTEXT } else { "../fluent-api" }
    & $ContainerCmd run -d --name fluent_worker --pod $PodName `
        -e DATABASE_URL=postgres://postgres:postgres@localhost:5432/fluent `
        -e EXPORTS_DIR=/app/exports `
        --env-file "$apiContext/.env" `
        -v "$apiContext/src:/app/src:ro" `
        -v "$apiContext/tsconfig.json:/app/tsconfig.json:ro" `
        -v fluent-worker-node-modules:/app/node_modules `
        --tmpfs /tmp:noexec,nosuid,size=64m `
        --tmpfs /app/.cache:noexec,nosuid,size=128m `
        --tmpfs /app/exports:noexec,nosuid,size=256m `
        --security-opt no-new-privileges:true `
        --cap-drop ALL `
        --user 1001:1001 `
        --read-only `
        fluent-api dumb-init -- npx tsx watch src/workers/standalone-worker.ts
    Write-Success "Worker container started"
}

function Start-AiContainer {
    $existing = & $ContainerCmd container exists ai 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "AI container already exists"
        return
    }
    
    # Validate build context
    $aiContext = if ($env:AI_CONTEXT) { $env:AI_CONTEXT } else { "../fluent-ai" }
    if (-not (Test-Path $aiContext)) {
        Write-Error-Color "AI context not found: $aiContext"
        Write-Error-Color "Please ensure the fluent-ai repository is cloned and accessible."
        exit 1
    }
    
    Write-Running "Building AI image..."
    & $ContainerCmd build -t fluent-ai $aiContext -f Dockerfile.dev
    
    Write-Running "Starting AI container..."
    & $ContainerCmd run -d --name fluent_ai --pod $PodName `
        -e DATABASE_URL="postgresql+asyncpg://postgres:postgres@localhost:5432/fluent" `
        -e ENVIRONMENT=development `
        -e DEBUG=true `
        -e UV_CACHE_DIR=/app/.cache/uv `
        --env-file "$aiContext/.env" `
        -v "$aiContext/src:/app/src:ro" `
        -v "$aiContext/pyproject.toml:/app/pyproject.toml:ro" `
        -v "$aiContext/uv.lock:/app/uv.lock:ro" `
        -v "$aiContext/docker-entrypoint.sh:/app/docker-entrypoint.sh:ro" `
        --tmpfs /tmp:nosuid,size=64m `
        --tmpfs /app/.cache:noexec,nosuid,size=128m `
        --security-opt no-new-privileges:true `
        --cap-drop ALL `
        --user 1001:1001 `
        --read-only `
        fluent-ai
    Write-Success "AI container started"
}

function Start-WebContainer {
    $existing = & $ContainerCmd container exists web 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Web container already exists"
        return
    }
    
    # Validate build context
    $webContext = if ($env:WEB_CONTEXT) { $env:WEB_CONTEXT } else { "../fluent-web" }
    if (-not (Test-Path $webContext)) {
        Write-Error-Color "Web context not found: $webContext"
        Write-Error-Color "Please ensure the fluent-web repository is cloned and accessible."
        exit 1
    }
    
    Write-Running "Building Web image..."
    & $ContainerCmd build -t fluent-web $webContext -f Dockerfile.dev
    
    Write-Running "Starting Web container..."
    & $ContainerCmd run -d --name fluent_web --pod $PodName `
        -e COREPACK_HOME=/app/.cache/corepack `
        -v "$webContext/src:/app/src" `
        -v "$webContext/public:/app/public:ro" `
        -v "$webContext/index.html:/app/index.html:ro" `
        -v "$webContext/vite.config.ts:/app/vite.config.ts" `
        -v "$webContext/tsconfig.json:/app/tsconfig.json:ro" `
        -v "$webContext/tsconfig.node.json:/app/tsconfig.node.json:ro" `
        -v "$webContext/components.json:/app/components.json:ro" `
        -v "$webContext/eslint.config.js:/app/eslint.config.js:ro" `
        -v "$webContext/.env:/app/.env:ro" `
        -v fluent-web-node-modules:/app/node_modules `
        --tmpfs /tmp:nosuid,size=64m `
        --tmpfs /app/.cache:noexec,nosuid,size=128m `
        --security-opt no-new-privileges:true `
        --cap-drop ALL `
        --user 1001:1001 `
        fluent-web
    Write-Success "Web container started"
}

# Podman-specific command functions -------------------------------------------
function Invoke-PodmanUp {
    Write-Running "Starting services with Podman pods..."
    New-Volumes
    New-Pod
    Start-DatabaseContainer
    Wait-Database
    Start-ApiContainer
    Wait-Api
    Start-WorkerContainer
    Start-AiContainer
    Start-WebContainer
    Write-Success "All services started!"
}

function Invoke-PodmanDown {
    Write-Running "Stopping services..."
    Remove-Pod
    Write-Success "Services stopped."
}

function Invoke-PodmanLogs {
    if ($Args.Count -eq 0) {
        & $ContainerCmd logs -f --pod $PodName
    } else {
        & $ContainerCmd logs -f $Args[0]
    }
}

function Invoke-PodmanStatus {
    & $ContainerCmd pod ps
    $existing = & $ContainerCmd pod exists $PodName 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "Containers in pod $PodName:"
        & $ContainerCmd ps --pod $PodName
    }
}

function Invoke-PodmanShell {
    $service = if ($Args.Count -gt 0) { $Args[0] } else { "api" }
    if ($service -eq "db") {
        & $ContainerCmd exec db psql -U postgres -d fluent
    } else {
        & $ContainerCmd exec $service sh
    }
}

function Invoke-PodmanRun {
    if ($Args.Count -lt 2) { Write-Error-Color "Usage: fluent.ps1 run <service> <script>"; exit 1 }
    $service = $Args[0]
    $remaining = $Args[1..($Args.Count - 1)]
    if ($service -eq "ai") {
        & $ContainerCmd exec $service uv run @remaining
    } else {
        & $ContainerCmd exec $service npm run @remaining
    }
}

function Invoke-PodmanTest {
    if ($Args.Count -lt 1) { Write-Error-Color "Usage: fluent.ps1 test <service>"; exit 1 }
    $service = $Args[0]
    $remaining = if ($Args.Count -gt 1) { $Args[1..($Args.Count - 1)] } else { @() }
    if ($service -eq "ai") {
        & $ContainerCmd exec ai uv run pytest @remaining
    } else {
        & $ContainerCmd exec $service npm run test @remaining
    }
}

# Docker Compose fallback functions -------------------------------------------
function Invoke-Compose {
    param([string[]]$ComposeArgs)
    if ($ContainerCmd -eq "docker compose") {
        & docker compose @ComposeArgs
    } else {
        & $ContainerCmd @ComposeArgs
    }
}

# ── Repo path helpers ──────────────────────────────────────────────────────────

$ApiContext = if ($env:API_CONTEXT) { $env:API_CONTEXT } else { "../fluent-api" }
$AiContext  = if ($env:AI_CONTEXT)  { $env:AI_CONTEXT }  else { "../fluent-ai" }
$WebContext = if ($env:WEB_CONTEXT) { $env:WEB_CONTEXT } else { "../fluent-web" }

$Repos = @(
    @{ Name = "fluent-api"; Path = $ApiContext; Url = "git@github.com:eten-tech-foundation/fluent-api.git" },
    @{ Name = "fluent-ai";  Path = $AiContext;  Url = "git@github.com:eten-tech-foundation/fluent-ai.git" },
    @{ Name = "fluent-web"; Path = $WebContext;  Url = "git@github.com:eten-tech-foundation/fluent-web.git" }
)

function Test-Repos {
    $missing = $false
    foreach ($repo in $Repos) {
        if (Test-Path $repo.Path) {
            Write-Host "  [ok] $($repo.Name) -> $($repo.Path)"
        } else {
            Write-Host "  [missing] $($repo.Name) -> $($repo.Path)"
            $missing = $true
        }
    }
    return -not $missing
}

# ── Commands ───────────────────────────────────────────────────────────────────

switch ($Command) {
    "up" {
        if ($RuntimeMode -eq "podman-pod") {
            Invoke-PodmanUp
        } else {
            Invoke-Compose @("up", "-d", "--build") + $Args
        }
    }
    "down" {
        if ($RuntimeMode -eq "podman-pod") {
            Invoke-PodmanDown
        } else {
            Invoke-Compose @("down") + $Args
        }
    }
    "restart" {
        if ($RuntimeMode -eq "podman-pod") {
            if ($Args.Count -eq 0) {
                Write-Host "Restarting all services..."
                Remove-Pod
                Invoke-PodmanUp
            } else {
                foreach ($service in $Args) {
                    Write-Host "Restarting $service..."
                    & $ContainerCmd rm -f $service 2>$null | Out-Null
                    switch ($service) {
                        "db" { Start-DatabaseContainer }
                        "api" { Start-ApiContainer }
                        "worker" { Start-WorkerContainer }
                        "ai" { Start-AiContainer }
                        "web" { Start-WebContainer }
                        default { Write-Host "Unknown service: $service" }
                    }
                }
            }
        } else {
            Invoke-Compose @("restart") + $Args
        }
    }
    "logs" {
        if ($RuntimeMode -eq "podman-pod") {
            Invoke-PodmanLogs $Args
        } else {
            Invoke-Compose @("logs", "-f") + $Args
        }
    }
    "status" {
        if ($RuntimeMode -eq "podman-pod") {
            Invoke-PodmanStatus
        } else {
            Invoke-Compose @("ps") + $Args
        }
    }
    "shell" {
        if ($RuntimeMode -eq "podman-pod") {
            Invoke-PodmanShell $Args
        } else {
            $service = if ($Args.Count -gt 0) { $Args[0] } else { "api" }
            if ($service -eq "db") {
                Invoke-Compose @("exec", "db", "psql", "-U", "postgres", "-d", "fluent")
            } else {
                Invoke-Compose @("exec", $service, "sh")
            }
        }
    }
    "run" {
        if ($RuntimeMode -eq "podman-pod") {
            Invoke-PodmanRun $Args
        } else {
            if ($Args.Count -lt 2) { Write-Error "Usage: fluent.ps1 run <service> <script>"; exit 1 }
            $service = $Args[0]
            $remaining = $Args[1..($Args.Count - 1)]
            Invoke-Compose @("exec", $service, "npm", "run") + $remaining
        }
    }
    "test" {
        if ($RuntimeMode -eq "podman-pod") {
            Invoke-PodmanTest $Args
        } else {
            if ($Args.Count -lt 1) { Write-Error "Usage: fluent.ps1 test <service>"; exit 1 }
            $service = $Args[0]
            $remaining = if ($Args.Count -gt 1) { $Args[1..($Args.Count - 1)] } else { @() }
            if ($service -eq "ai") {
                Invoke-Compose @("exec", "ai", "uv", "run", "pytest") + $remaining
            } else {
                Invoke-Compose @("exec", $service, "npm", "run", "test") + $remaining
            }
        }
    }

    # ── Database commands ──────────────────────────────────────────────────────

    "db:migrate" {
        $target = if ($Args.Count -gt 0) { $Args[0] } else { "all" }
        if ($RuntimeMode -eq "podman-pod") {
            switch ($target) {
                "api" {
                    Write-Running "Running fluent-api migrations..."
                    & $ContainerCmd exec api npx drizzle-kit migrate
                    Write-Success "API migrations completed"
                }
                "ai" {
                    Write-Running "Running fluent-ai migrations..."
                    Write-Host "  (no migrations configured yet)"
                }
                "all" {
                    $confirm = Read-Host "Run migrations for all services? [y/N]"
                    if ($confirm -match "^[Yy]$") {
                        Write-Running "Running fluent-api migrations..."
                        & $ContainerCmd exec api npx drizzle-kit migrate
                        Write-Success "All migrations completed"
                    } else {
                        Write-Host "Aborted."
                    }
                }
                { $_ -in "web", "db" } {
                    Write-Error-Color "The $target service does not have its own migrations."
                    exit 1
                }
                default {
                    Write-Error-Color "Unknown migrate target: $target (use api, ai, or all)"
                    exit 1
                }
            }
        } else {
            switch ($target) {
                "api" {
                    Write-Running "Running fluent-api migrations..."
                    Invoke-Compose @("exec", "api", "npx", "drizzle-kit", "migrate")
                    Write-Success "API migrations completed"
                }
                "ai" {
                    Write-Running "Running fluent-ai migrations..."
                    Write-Host "  (no migrations configured yet)"
                }
                "all" {
                    $confirm = Read-Host "Run migrations for all services? [y/N]"
                    if ($confirm -match "^[Yy]$") {
                        Write-Running "Running fluent-api migrations..."
                        Invoke-Compose @("exec", "api", "npx", "drizzle-kit", "migrate")
                        Write-Success "All migrations completed"
                    } else {
                        Write-Host "Aborted."
                    }
                }
                { $_ -in "web", "db" } {
                    Write-Error-Color "The $target service does not have its own migrations."
                    exit 1
                }
                default {
                    Write-Error-Color "Unknown migrate target: $target (use api, ai, or all)"
                    exit 1
                }
            }
        }
    }
    "db:seed" {
        $target = if ($Args.Count -gt 0) { $Args[0] } else { "all" }
        if ($RuntimeMode -eq "podman-pod") {
            switch ($target) {
                "api" {
                    Write-Running "Running fluent-api seeds..."
                    & $ContainerCmd exec api npx tsx src/db/seeds/rbac.ts
                    Write-Success "API seeds completed"
                }
                "ai" {
                    Write-Running "Running fluent-ai seeds..."
                    Write-Host "  (no seeds configured yet)"
                }
                "all" {
                    $confirm = Read-Host "Run seeds for all services? [y/N]"
                    if ($confirm -match "^[Yy]$") {
                        Write-Running "Running fluent-api seeds..."
                        & $ContainerCmd exec api npx tsx src/db/seeds/rbac.ts
                        Write-Success "All seeds completed"
                    } else {
                        Write-Host "Aborted."
                    }
                }
                { $_ -in "web", "db" } {
                    Write-Error-Color "The $target service does not have its own seeds."
                    exit 1
                }
                default {
                    Write-Error-Color "Unknown seed target: $target (use api, ai, or all)"
                    exit 1
                }
            }
        } else {
            switch ($target) {
                "api" {
                    Write-Running "Running fluent-api seeds..."
                    Invoke-Compose @("exec", "api", "npx", "tsx", "src/db/seeds/rbac.ts")
                    Write-Success "API seeds completed"
                }
                "ai" {
                    Write-Running "Running fluent-ai seeds..."
                    Write-Host "  (no seeds configured yet)"
                }
                "all" {
                    $confirm = Read-Host "Run seeds for all services? [y/N]"
                    if ($confirm -match "^[Yy]$") {
                        Write-Running "Running fluent-api seeds..."
                        Invoke-Compose @("exec", "api", "npx", "tsx", "src/db/seeds/rbac.ts")
                        Write-Success "All seeds completed"
                    } else {
                        Write-Host "Aborted."
                    }
                }
                { $_ -in "web", "db" } {
                    Write-Error-Color "The $target service does not have its own seeds."
                    exit 1
                }
                default {
                    Write-Error-Color "Unknown seed target: $target (use api, ai, or all)"
                    exit 1
                }
            }
        }
    }
    "db:init" {
        Write-Running "Full database initialization (migrations + seeds)..."
        $confirm = Read-Host "This will run all migrations and seeds. Continue? [y/N]"
        if ($confirm -match "^[Yy]$") {
            if ($RuntimeMode -eq "podman-pod") {
                & $ContainerCmd exec api npx drizzle-kit migrate
                & $ContainerCmd exec api npx tsx src/db/seeds/rbac.ts
            } else {
                & $MyInvocation.MyCommand.Path "db:migrate" "api"
                & $MyInvocation.MyCommand.Path "db:seed" "api"
            }
            Write-Success "Database initialization complete."
        } else {
            Write-Host "Aborted."
        }
    }
    "db:studio" {
        Write-Running "Running Drizzle Studio on host (requires local Node.js)..."
        Write-Host "Connects to DB via DATABASE_URL in .env (localhost:$DbPort)"
        npx drizzle-kit studio
    }
    "db:psql" {
        if ($RuntimeMode -eq "podman-pod") {
            & $ContainerCmd exec db psql -U postgres -d fluent
        } else {
            Invoke-Compose @("exec", "db", "psql", "-U", "postgres", "-d", "fluent")
        }
    }

    # Lifecycle commands -----------------------------------------------------------
    "clean" {
        $target = if ($Args.Count -gt 0) { $Args[0] } else { "all" }
        Write-Running "This will remove containers AND volumes (full DB reset)."
        $confirm = Read-Host "Continue? [y/N]"
        if ($confirm -match "^[Yy]$") {
            if ($RuntimeMode -eq "podman-pod") {
                if ($target -eq "all") {
                    Remove-Pod
                    & $ContainerCmd volume rm fluent-pgdata fluent-api-node-modules fluent-worker-node-modules fluent-web-node-modules 2>$null | Out-Null
                    $apiContext = if ($env:API_CONTEXT) { $env:API_CONTEXT } else { "../fluent-api" }
                    $aiContext = if ($env:AI_CONTEXT) { $env:AI_CONTEXT } else { "../fluent-ai" }
                    Remove-Item -Force -ErrorAction SilentlyContinue "$apiContext/.db-initialized"
                    Remove-Item -Force -ErrorAction SilentlyContinue "$aiContext/.db-initialized"
                    Write-Success "All containers and volumes removed"
                } else {
                    & $ContainerCmd rm -f $target 2>$null | Out-Null
                    $apiContext = if ($env:API_CONTEXT) { $env:API_CONTEXT } else { "../fluent-api" }
                    $aiContext = if ($env:AI_CONTEXT) { $env:AI_CONTEXT } else { "../fluent-ai" }
                    switch ($target) {
                        { $_ -in "api", "worker" } { Remove-Item -Force -ErrorAction SilentlyContinue "$apiContext/.db-initialized" }
                        "ai" { Remove-Item -Force -ErrorAction SilentlyContinue "$aiContext/.db-initialized" }
                    }
                    Write-Success "$target container and related data removed"
                }
            } else {
                if ($target -eq "all") {
                    Invoke-Compose @("down", "-v")
                    $apiContext = if ($env:API_CONTEXT) { $env:API_CONTEXT } else { "../fluent-api" }
                    $aiContext = if ($env:AI_CONTEXT) { $env:AI_CONTEXT } else { "../fluent-ai" }
                    Remove-Item -Force -ErrorAction SilentlyContinue "$apiContext/.db-initialized"
                    Remove-Item -Force -ErrorAction SilentlyContinue "$aiContext/.db-initialized"
                    Write-Success "All containers and volumes removed"
                } else {
                    Invoke-Compose @("rm", "-sf", $target)
                    $apiContext = if ($env:API_CONTEXT) { $env:API_CONTEXT } else { "../fluent-api" }
                    $aiContext = if ($env:AI_CONTEXT) { $env:AI_CONTEXT } else { "../fluent-ai" }
                    switch ($target) {
                        { $_ -in "api", "worker" } { Remove-Item -Force -ErrorAction SilentlyContinue "$apiContext/.db-initialized" }
                        "ai" { Remove-Item -Force -ErrorAction SilentlyContinue "$aiContext/.db-initialized" }
                    }
                    Write-Success "$target container and related data removed"
                }
            }
        } else {
            Write-Host "Aborted."
        }
    }
    "fresh" {
        Write-Running "This will destroy ALL containers, volumes, and images for this project."
        Write-Running "The database will be wiped and everything will be rebuilt from scratch."
        $confirm = Read-Host "Continue? [y/N]"
        if ($confirm -match "^[Yy]$") {
            if ($RuntimeMode -eq "podman-pod") {
                Remove-Pod
                & $ContainerCmd volume rm fluent-pgdata fluent-api-node-modules fluent-worker-node-modules fluent-web-node-modules 2>$null | Out-Null
                & $ContainerCmd rmi -f fluent-api fluent-ai fluent-web 2>$null | Out-Null
                $apiContext = if ($env:API_CONTEXT) { $env:API_CONTEXT } else { "../fluent-api" }
                $aiContext = if ($env:AI_CONTEXT) { $env:AI_CONTEXT } else { "../fluent-ai" }
                Remove-Item -Force -ErrorAction SilentlyContinue "$apiContext/.db-initialized"
                Remove-Item -Force -ErrorAction SilentlyContinue "$aiContext/.db-initialized"
            } else {
                Invoke-Compose @("down", "-v", "--rmi", "local", "--remove-orphans")
                $apiContext = if ($env:API_CONTEXT) { $env:API_CONTEXT } else { "../fluent-api" }
                $aiContext = if ($env:AI_CONTEXT) { $env:AI_CONTEXT } else { "../fluent-ai" }
                Remove-Item -Force -ErrorAction SilentlyContinue "$apiContext/.db-initialized"
                Remove-Item -Force -ErrorAction SilentlyContinue "$aiContext/.db-initialized"
            }
            Write-Host ""
            Write-Success "Clean slate. Run '.\fluent.ps1 up' to rebuild and start everything."
        } else {
            Write-Host "Aborted."
        }
    }
    "build" {
        $services = $Args
        
        if ($RuntimeMode -eq "podman-pod") {
            if ($services.Count -eq 0) {
                Write-Running "Building all images..."
                $services = @("api", "ai", "web")
            } else {
                Write-Running "Building specified services: $($services -join ', ')"
            }
            
            # Validate build contexts exist for requested services
            $missingContexts = @()
            foreach ($service in $services) {
                switch ($service) {
                    "api" {
                        $apiContext = if ($env:API_CONTEXT) { $env:API_CONTEXT } else { "../fluent-api" }
                        if (-not (Test-Path $apiContext)) { $missingContexts += "API context: $apiContext" }
                    }
                    "ai" {
                        $aiContext = if ($env:AI_CONTEXT) { $env:AI_CONTEXT } else { "../fluent-ai" }
                        if (-not (Test-Path $aiContext)) { $missingContexts += "AI context: $aiContext" }
                    }
                    "web" {
                        $webContext = if ($env:WEB_CONTEXT) { $env:WEB_CONTEXT } else { "../fluent-web" }
                        if (-not (Test-Path $webContext)) { $missingContexts += "Web context: $webContext" }
                    }
                    default {
                        Write-Error-Color "Unknown service '$service' (use: api, ai, web)"
                        exit 1
                    }
                }
            }
            
            if ($missingContexts.Count -gt 0) {
                Write-Error-Color "Missing build contexts:"
                foreach ($context in $missingContexts) {
                    Write-Host "  - $context"
                }
                Write-Host ""
                Write-Host "Please ensure all repositories are cloned and accessible, or run:"
                Write-Host "  .\fluent.ps1 setup"
                exit 1
            }
            
            # Build requested services
            foreach ($service in $services) {
                switch ($service) {
                    "api" {
                        Write-Running "Building API image..."
                        $apiContext = if ($env:API_CONTEXT) { $env:API_CONTEXT } else { "../fluent-api" }
                        & $ContainerCmd build -t fluent-api $apiContext -f Dockerfile.dev
                        Write-Success "API image built successfully"
                    }
                    "ai" {
                        Write-Running "Building AI image..."
                        $aiContext = if ($env:AI_CONTEXT) { $env:AI_CONTEXT } else { "../fluent-ai" }
                        & $ContainerCmd build -t fluent-ai $aiContext -f Dockerfile.dev
                        Write-Success "AI image built successfully"
                    }
                    "web" {
                        Write-Running "Building Web image..."
                        $webContext = if ($env:WEB_CONTEXT) { $env:WEB_CONTEXT } else { "../fluent-web" }
                        & $ContainerCmd build -t fluent-web $webContext -f Dockerfile.dev
                        Write-Success "Web image built successfully"
                    }
                }
            }
            Write-Success "Build process completed"
        } else {
            if ($services.Count -eq 0) {
                Write-Running "Building all Docker Compose services..."
                Invoke-Compose @("build", "--no-cache")
            } else {
                Write-Running "Building specified Docker Compose services: $($services -join ', ')"
                Invoke-Compose @("build", "--no-cache") + $services
            }
            Write-Success "Docker Compose build completed"
        }
    }
    "setup" {
        Write-Host "=== Fluent Platform Setup ==="
        Write-Host ""

        Write-Host "Checking sibling repositories..."
        $allPresent = Test-Repos

        if (-not $allPresent) {
            Write-Host ""
            Write-Host "Missing repositories detected. Clone them with:"
            foreach ($repo in $Repos) {
                if (-not (Test-Path $repo.Path)) {
                    Write-Host "  git clone $($repo.Url) $($repo.Path)"
                }
            }
            Write-Host ""
            $cloneConfirm = Read-Host "Clone missing repos now? [y/N]"
            if ($cloneConfirm -match "^[Yy]$") {
                foreach ($repo in $Repos) {
                    if (-not (Test-Path $repo.Path)) {
                        Write-Host "Cloning $($repo.Name)..."
                        git clone $repo.Url $repo.Path
                    }
                }
            }
        }

        Write-Host ""

        if (-not (Test-Path .env)) {
            Copy-Item .env.example .env
            Write-Host "Created .env from .env.example"
        } else {
            Write-Host ".env already exists, skipping."
        }

        foreach ($repo in $Repos) {
            if ((Test-Path $repo.Path) -and (Test-Path "$($repo.Path)/.env.example") -and (-not (Test-Path "$($repo.Path)/.env"))) {
                Copy-Item "$($repo.Path)/.env.example" "$($repo.Path)/.env"
                Write-Host "Created $($repo.Path)/.env from .env.example"
            }
        }

        Write-Host ""
        Write-Host "Setup complete. Next steps:"
        Write-Host "  1. Fill in credentials in each .env file (Auth0, etc.)"
        Write-Host "  2. Run: .\fluent.ps1 up"
    }
    default {
        @"
Usage: .\fluent.ps1 <command> [args]

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
"@
    }
}

# Runtime mode display --------------------------------------------------------
Write-Host "Runtime mode: $RuntimeMode"
if ($RuntimeMode -eq "podman-pod") {
    Write-Host "Using native Podman pods"
} else {
    Write-Host "Using Docker Compose"
}
Write-Host ""
