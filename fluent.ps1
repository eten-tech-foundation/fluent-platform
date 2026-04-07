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

# Podman pod configuration ----------------------------------------------------
$PodName = "fluent-platform"
$DbPort = if ($env:DB_PORT) { $env:DB_PORT } else { "5432" }
$ApiPort = if ($env:API_PORT) { $env:API_PORT } else { "9999" }
$AiPort = if ($env:AI_PORT) { $env:AI_PORT } else { "8200" }
$WebPort = if ($env:WEB_PORT) { $env:WEB_PORT } else { "5173" }

# Pod management functions ----------------------------------------------------
function New-Pod {
    $existing = & $ContainerCmd pod exists $PodName 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Pod $PodName already exists"
        return
    }
    
    Write-Host "Creating pod $PodName..."
    & $ContainerCmd pod create --name $PodName --share `
        -p "${DbPort}:5432" `
        -p "${ApiPort}:9999" `
        -p "${AiPort}:8200" `
        -p "${WebPort}:5173"
}

function Remove-Pod {
    $existing = & $ContainerCmd pod exists $PodName 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Removing pod $PodName..."
        & $ContainerCmd pod rm $PodName -f
    }
}

function New-Volumes {
    Write-Host "Creating volumes..."
    & $ContainerCmd volume create fluent-pgdata 2>$null | Out-Null
    & $ContainerCmd volume create fluent-api-node-modules 2>$null | Out-Null
    & $ContainerCmd volume create fluent-worker-node-modules 2>$null | Out-Null
    & $ContainerCmd volume create fluent-web-node-modules 2>$null | Out-Null
}

function Wait-Database {
    Write-Host "Waiting for database to be ready..."
    do {
        Start-Sleep -Seconds 2
        & $ContainerCmd exec db pg_isready -U postgres -d fluent 2>$null | Out-Null
    } while ($LASTEXITCODE -ne 0)
}

function Wait-Api {
    Write-Host "Waiting for API to be ready..."
    do {
        Start-Sleep -Seconds 2
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:${ApiPort}/health" -TimeoutSec 2 -ErrorAction Stop
        } catch {
            continue
        }
    } while ($response.StatusCode -ne 200)
}

# Service container functions -------------------------------------------------
function Start-DatabaseContainer {
    $existing = & $ContainerCmd container exists db 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Database container already exists"
        return
    }
    
    Write-Host "Starting database container..."
    & $ContainerCmd run -d --name db --pod $PodName `
        -e POSTGRES_USER=postgres `
        -e POSTGRES_PASSWORD=postgres `
        -e POSTGRES_DB=fluent `
        -v fluent-pgdata:/var/lib/postgresql/data `
        -v ./db/init:/docker-entrypoint-initdb.d `
        --health-cmd "pg_isready -U postgres -d fluent" `
        --health-interval 5s `
        --health-timeout 5s `
        --health-retries 5 `
        postgres:16-alpine
}

function Start-ApiContainer {
    $existing = & $ContainerCmd container exists api 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "API container already exists"
        return
    }
    
    Write-Host "Building API image..."
    & $ContainerCmd build -t fluent-api $ApiContext -f Dockerfile.dev
    
    Write-Host "Starting API container..."
    & $ContainerCmd run -d --name api --pod $PodName `
        -e DATABASE_URL=postgres://postgres:postgres@localhost:5432/fluent `
        -e EXPORTS_DIR=/app/exports `
        --env-file "$ApiContext/.env" `
        -v "$ApiContext/src:/app/src:ro" `
        -v "$ApiContext/tsconfig.json:/app/tsconfig.json:ro" `
        -v "$ApiContext/drizzle.config.ts:/app/drizzle.config.ts:ro" `
        -v "$ApiContext/docker-entrypoint.sh:/app/docker-entrypoint.sh:ro" `
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
}

function Start-WorkerContainer {
    $existing = & $ContainerCmd container exists worker 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Worker container already exists"
        return
    }
    
    Write-Host "Starting worker container..."
    & $ContainerCmd run -d --name worker --pod $PodName `
        -e DATABASE_URL=postgres://postgres:postgres@localhost:5432/fluent `
        -e EXPORTS_DIR=/app/exports `
        --env-file "$ApiContext/.env" `
        -v "$ApiContext/src:/app/src:ro" `
        -v "$ApiContext/tsconfig.json:/app/tsconfig.json:ro" `
        -v fluent-worker-node-modules:/app/node_modules `
        --tmpfs /tmp:noexec,nosuid,size=64m `
        --tmpfs /app/.cache:noexec,nosuid,size=128m `
        --tmpfs /app/exports:noexec,nosuid,size=256m `
        --security-opt no-new-privileges:true `
        --cap-drop ALL `
        --user 1001:1001 `
        --read-only `
        fluent-api dumb-init -- npx tsx watch src/workers/standalone-worker.ts
}

function Start-AiContainer {
    $existing = & $ContainerCmd container exists ai 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "AI container already exists"
        return
    }
    
    Write-Host "Building AI image..."
    & $ContainerCmd build -t fluent-ai $AiContext -f Dockerfile.dev
    
    Write-Host "Starting AI container..."
    & $ContainerCmd run -d --name ai --pod $PodName `
        -e DATABASE_URL="postgresql+asyncpg://postgres:postgres@localhost:5432/fluent" `
        -e ENVIRONMENT=development `
        -e DEBUG=true `
        -e UV_CACHE_DIR=/app/.cache/uv `
        --env-file "$AiContext/.env" `
        -v "$AiContext/src:/app/src:ro" `
        -v "$AiContext/pyproject.toml:/app/pyproject.toml:ro" `
        -v "$AiContext/uv.lock:/app/uv.lock:ro" `
        -v "$AiContext/docker-entrypoint.sh:/app/docker-entrypoint.sh:ro" `
        --tmpfs /tmp:nosuid,size=64m `
        --tmpfs /app/.cache:noexec,nosuid,size=128m `
        --security-opt no-new-privileges:true `
        --cap-drop ALL `
        --user 1001:1001 `
        --read-only `
        fluent-ai
}

function Start-WebContainer {
    $existing = & $ContainerCmd container exists web 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Web container already exists"
        return
    }
    
    Write-Host "Building Web image..."
    & $ContainerCmd build -t fluent-web $WebContext -f Dockerfile.dev
    
    Write-Host "Starting Web container..."
    & $ContainerCmd run -d --name web --pod $PodName `
        -e COREPACK_HOME=/app/.cache/corepack `
        -v "$WebContext/src:/app/src" `
        -v "$WebContext/public:/app/public:ro" `
        -v "$WebContext/index.html:/app/index.html:ro" `
        -v "$WebContext/vite.config.ts:/app/vite.config.ts" `
        -v "$WebContext/tsconfig.json:/app/tsconfig.json:ro" `
        -v "$WebContext/tsconfig.node.json:/app/tsconfig.node.json:ro" `
        -v "$WebContext/components.json:/app/components.json:ro" `
        -v "$WebContext/eslint.config.js:/app/eslint.config.js:ro" `
        -v "$WebContext/.env:/app/.env:ro" `
        -v fluent-web-node-modules:/app/node_modules `
        --tmpfs /tmp:nosuid,size=64m `
        --tmpfs /app/.cache:noexec,nosuid,uid=1001,gid=1001,size=128m `
        --security-opt no-new-privileges:true `
        --cap-drop ALL `
        --user 1001:1001 `
        fluent-web
}

# Podman-specific command functions -------------------------------------------
function Invoke-PodmanUp {
    Write-Host "Starting services with Podman pods..."
    New-Volumes
    New-Pod
    Start-DatabaseContainer
    Wait-Database
    Start-ApiContainer
    Wait-Api
    Start-WorkerContainer
    Start-AiContainer
    Start-WebContainer
    Write-Host "All services started!"
}

function Invoke-PodmanDown {
    Write-Host "Stopping services..."
    Remove-Pod
    Write-Host "Services stopped."
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
    if ($Args.Count -lt 2) { Write-Error "Usage: fluent.ps1 run <service> <script>"; exit 1 }
    $service = $Args[0]
    $remaining = $Args[1..($Args.Count - 1)]
    if ($service -eq "ai") {
        & $ContainerCmd exec $service uv run @remaining
    } else {
        & $ContainerCmd exec $service npm run @remaining
    }
}

function Invoke-PodmanTest {
    if ($Args.Count -lt 1) { Write-Error "Usage: fluent.ps1 test <service>"; exit 1 }
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
                    Write-Host "Running fluent-api migrations..."
                    & $ContainerCmd exec api npx drizzle-kit migrate
                }
                "ai" {
                    Write-Host "Running fluent-ai migrations..."
                    Write-Host "  (no migrations configured yet)"
                }
                "all" {
                    $confirm = Read-Host "Run migrations for all services? [y/N]"
                    if ($confirm -match "^[Yy]$") {
                        & $ContainerCmd exec api npx drizzle-kit migrate
                    } else {
                        Write-Host "Aborted."
                    }
                }
                { $_ -in "web", "db" } {
                    Write-Error "The $target service does not have its own migrations."
                }
                default {
                    Write-Error "Unknown migrate target: $target (use api, ai, or all)"
                }
            }
        } else {
            switch ($target) {
                "api" {
                    Write-Host "Running fluent-api migrations..."
                    Invoke-Compose @("exec", "api", "npx", "drizzle-kit", "migrate")
                }
                "ai" {
                    Write-Host "Running fluent-ai migrations..."
                    Write-Host "  (no migrations configured yet)"
                }
                "all" {
                    $confirm = Read-Host "Run migrations for all services? [y/N]"
                    if ($confirm -match "^[Yy]$") {
                        & $MyInvocation.MyCommand.Path "db:migrate" "api"
                        & $MyInvocation.MyCommand.Path "db:migrate" "ai"
                    } else {
                        Write-Host "Aborted."
                    }
                }
                { $_ -in "web", "db" } {
                    Write-Error "The $target service does not have its own migrations."
                }
                default {
                    Write-Error "Unknown migrate target: $target (use api, ai, or all)"
                }
            }
        }
    }
    "db:seed" {
        $target = if ($Args.Count -gt 0) { $Args[0] } else { "all" }
        if ($RuntimeMode -eq "podman-pod") {
            switch ($target) {
                "api" {
                    Write-Host "Running fluent-api seeds..."
                    & $ContainerCmd exec api npx tsx src/db/seeds/rbac.ts
                }
                "ai" {
                    Write-Host "Running fluent-ai seeds..."
                    Write-Host "  (no seeds configured yet)"
                }
                "all" {
                    $confirm = Read-Host "Run seeds for all services? [y/N]"
                    if ($confirm -match "^[Yy]$") {
                        & $ContainerCmd exec api npx tsx src/db/seeds/rbac.ts
                    } else {
                        Write-Host "Aborted."
                    }
                }
                { $_ -in "web", "db" } {
                    Write-Error "The $target service does not have its own seeds."
                }
                default {
                    Write-Error "Unknown seed target: $target (use api, ai, or all)"
                }
            }
        } else {
            switch ($target) {
                "api" {
                    Write-Host "Running fluent-api seeds..."
                    Invoke-Compose @("exec", "api", "npx", "tsx", "src/db/seeds/rbac.ts")
                }
                "ai" {
                    Write-Host "Running fluent-ai seeds..."
                    Write-Host "  (no seeds configured yet)"
                }
                "all" {
                    $confirm = Read-Host "Run seeds for all services? [y/N]"
                    if ($confirm -match "^[Yy]$") {
                        & $MyInvocation.MyCommand.Path "db:seed" "api"
                        & $MyInvocation.MyCommand.Path "db:seed" "ai"
                    } else {
                        Write-Host "Aborted."
                    }
                }
                { $_ -in "web", "db" } {
                    Write-Error "The $target service does not have its own seeds."
                }
                default {
                    Write-Error "Unknown seed target: $target (use api, ai, or all)"
                }
            }
        }
    }
    "db:init" {
        Write-Host "Full database initialization (migrations + seeds)..."
        $confirm = Read-Host "This will run all migrations and seeds. Continue? [y/N]"
        if ($confirm -match "^[Yy]$") {
            if ($RuntimeMode -eq "podman-pod") {
                & $ContainerCmd exec api npx drizzle-kit migrate
                & $ContainerCmd exec api npx tsx src/db/seeds/rbac.ts
            } else {
                & $MyInvocation.MyCommand.Path "db:migrate" "api"
                & $MyInvocation.MyCommand.Path "db:migrate" "ai"
                & $MyInvocation.MyCommand.Path "db:seed" "api"
                & $MyInvocation.MyCommand.Path "db:seed" "ai"
            }
            Write-Host "Database initialization complete."
        } else {
            Write-Host "Aborted."
        }
    }
    "db:studio" {
        Write-Host "Running Drizzle Studio on host (requires local Node.js)..."
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

    # ── Lifecycle commands ─────────────────────────────────────────────────────

    "clean" {
        $target = if ($Args.Count -gt 0) { $Args[0] } else { "all" }
        Write-Host "This will remove containers AND volumes (full DB reset)."
        $confirm = Read-Host "Continue? [y/N]"
        if ($confirm -match "^[Yy]$") {
            if ($RuntimeMode -eq "podman-pod") {
                if ($target -eq "all") {
                    Remove-Pod
                    & $ContainerCmd volume rm fluent-pgdata fluent-api-node-modules fluent-worker-node-modules fluent-web-node-modules 2>$null | Out-Null
                    Remove-Item -Force -ErrorAction SilentlyContinue "$ApiContext/.db-initialized"
                    Remove-Item -Force -ErrorAction SilentlyContinue "$AiContext/.db-initialized"
                } else {
                    & $ContainerCmd rm -f $target 2>$null | Out-Null
                    switch ($target) {
                        { $_ -in "api", "worker" } { Remove-Item -Force -ErrorAction SilentlyContinue "$ApiContext/.db-initialized" }
                        "ai" { Remove-Item -Force -ErrorAction SilentlyContinue "$AiContext/.db-initialized" }
                    }
                }
            } else {
                if ($target -eq "all") {
                    Invoke-Compose @("down", "-v")
                    Remove-Item -Force -ErrorAction SilentlyContinue "$ApiContext/.db-initialized"
                    Remove-Item -Force -ErrorAction SilentlyContinue "$AiContext/.db-initialized"
                } else {
                    Invoke-Compose @("rm", "-sf", $target)
                    switch ($target) {
                        { $_ -in "api", "worker" } { Remove-Item -Force -ErrorAction SilentlyContinue "$ApiContext/.db-initialized" }
                        "ai" { Remove-Item -Force -ErrorAction SilentlyContinue "$AiContext/.db-initialized" }
                    }
                }
            }
        } else {
            Write-Host "Aborted."
        }
    }
    "fresh" {
        Write-Host "This will destroy ALL containers, volumes, and images for this project."
        Write-Host "The database will be wiped and everything will be rebuilt from scratch."
        $confirm = Read-Host "Continue? [y/N]"
        if ($confirm -match "^[Yy]$") {
            if ($RuntimeMode -eq "podman-pod") {
                Remove-Pod
                & $ContainerCmd volume rm fluent-pgdata fluent-api-node-modules fluent-worker-node-modules fluent-web-node-modules 2>$null | Out-Null
                & $ContainerCmd rmi -f fluent-api fluent-ai fluent-web 2>$null | Out-Null
                Remove-Item -Force -ErrorAction SilentlyContinue "$ApiContext/.db-initialized"
                Remove-Item -Force -ErrorAction SilentlyContinue "$AiContext/.db-initialized"
            } else {
                Invoke-Compose @("down", "-v", "--rmi", "local", "--remove-orphans")
                Remove-Item -Force -ErrorAction SilentlyContinue "$ApiContext/.db-initialized"
                Remove-Item -Force -ErrorAction SilentlyContinue "$AiContext/.db-initialized"
            }
            Write-Host ""
            Write-Host "Clean slate. Run '.\fluent.ps1 up' to rebuild and start everything."
        } else {
            Write-Host "Aborted."
        }
    }
    "build" {
        if ($RuntimeMode -eq "podman-pod") {
            Write-Host "Building all images..."
            & $ContainerCmd build -t fluent-api $ApiContext -f Dockerfile.dev
            & $ContainerCmd build -t fluent-ai $AiContext -f Dockerfile.dev
            & $ContainerCmd build -t fluent-web $WebContext -f Dockerfile.dev
        } else {
            Invoke-Compose @("build", "--no-cache") + $Args
        }
    }
    "check-repos" {
        Write-Host "Checking sibling repositories..."
        Test-Repos | Out-Null
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
