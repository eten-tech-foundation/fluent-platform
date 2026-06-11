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

# ── Runtime detection ─────────────────────────────────────────────────────────

function Get-RuntimeMode {
    if (Get-Command podman -ErrorAction SilentlyContinue) {
        return @{ Mode = "podman-pod"; Command = "podman" }
    }
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $v2 = & docker compose version 2>&1
        if ($LASTEXITCODE -eq 0) {
            return @{ Mode = "docker-compose"; Command = "docker compose" }
        }
        if (Get-Command docker-compose -ErrorAction SilentlyContinue) {
            return @{ Mode = "docker-compose"; Command = "docker-compose" }
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

# ── Colors ────────────────────────────────────────────────────────────────────

$Yellow = "`e[1;33m"
$Green = "`e[1;32m"
$Red = "`e[1;31m"
$NoColor = "`e[0m"

function Write-Running { param([string]$Message) Write-Host "${Yellow}>>> $Message${NoColor}" }
function Write-Success  { param([string]$Message) Write-Host "${Green}>>> $Message${NoColor}" }
function Write-Error-Color { param([string]$Message) Write-Host "${Red}>>> $Message${NoColor}" }

# ── Configuration ─────────────────────────────────────────────────────────────

$PodName = "fluent"
$DbPort   = if ($env:DB_PORT)   { $env:DB_PORT }   else { "5432" }
$ApiPort  = if ($env:API_PORT)  { $env:API_PORT }  else { "9999" }
$AiPort   = if ($env:AI_PORT)   { $env:AI_PORT }   else { "8200" }
$WebPort  = if ($env:WEB_PORT)  { $env:WEB_PORT }  else { "5173" }

$ApiContext = if ($env:API_CONTEXT) { $env:API_CONTEXT } else { "../fluent-api" }
$AiContext  = if ($env:AI_CONTEXT)  { $env:AI_CONTEXT }  else { "../fluent-ai" }
$WebContext = if ($env:WEB_CONTEXT) { $env:WEB_CONTEXT } else { "../fluent-web" }

$Repos = @(
    @{ Name = "fluent-api"; Path = $ApiContext; Url = "git@github.com:eten-tech-foundation/fluent-api.git" },
    @{ Name = "fluent-ai";  Path = $AiContext;  Url = "git@github.com:eten-tech-foundation/fluent-ai.git" },
    @{ Name = "fluent-web"; Path = $WebContext; Url = "git@github.com:eten-tech-foundation/fluent-web.git" }
)

function Test-Repos {
    $missing = $false
    foreach ($repo in $Repos) {
        if (Test-Path $repo.Path) { Write-Host "  [ok] $($repo.Name) -> $($repo.Path)" }
        else { Write-Host "  [missing] $($repo.Name) -> $($repo.Path)"; $missing = $true }
    }
    return -not $missing
}

function Invoke-Compose {
    param([string[]]$ComposeArgs)
    if ($ContainerCmd -eq "docker compose") { & docker compose @ComposeArgs }
    else { & $ContainerCmd @ComposeArgs }
}

function Invoke-Exec {
    param([string]$Service, [string[]]$CmdArgs)
    if ($RuntimeMode -eq "podman-pod") {
        $cname = "fluent-$Service"
        & $ContainerCmd exec $cname @CmdArgs
    } else {
        Invoke-Compose @("exec", $Service) + $CmdArgs
    }
}

# ── Ecosystem commands ────────────────────────────────────────────────────────

function Ecosystem-Up {
    param([string[]]$Services)
    if ($RuntimeMode -eq "podman-pod") {
        Write-Running "Starting services with Podman..."
        & $ContainerCmd volume create fluent-pgdata 2>$null | Out-Null
        & $ContainerCmd volume create fluent-api-node-modules 2>$null | Out-Null
        & $ContainerCmd volume create fluent-worker-node-modules 2>$null | Out-Null
        & $ContainerCmd volume create fluent-web-node-modules 2>$null | Out-Null
        & $ContainerCmd volume create fluent-web-cache 2>$null | Out-Null
        & $ContainerCmd volume create fluent-ai-logs 2>$null | Out-Null
        & $ContainerCmd volume create fluent-web-eslintcache 2>$null | Out-Null

        $existing = & $ContainerCmd pod exists $PodName 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Running "Creating pod $PodName..."
            & $ContainerCmd pod create --name $PodName --share "net,ipc,uts" --network=slirp4netns `
                -p "${DbPort}:5432" -p "${ApiPort}:9999" -p "${AiPort}:8200" -p "${WebPort}:5173"
        }

        # Start DB
        $dbExists = & $ContainerCmd container exists fluent-db 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Running "Starting database container..."
            & $ContainerCmd run -d --name fluent-db --pod $PodName `
                -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=fluent `
                -v fluent-pgdata:/var/lib/postgresql/data `
                --health-cmd "pg_isready -U postgres -d fluent" `
                --health-interval 5s --health-timeout 5s --health-retries 5 `
                docker.io/postgres:16-alpine
        }
        Write-Running "Waiting for database..."
        do { Start-Sleep -Seconds 2; & $ContainerCmd exec fluent-db pg_isready -U postgres -d fluent 2>$null | Out-Null }
        while ($LASTEXITCODE -ne 0)
        Write-Success "Database is ready"

        # Build and start services
        foreach ($svc in @("api","worker","ai","web")) {
            if ($Services.Count -gt 0 -and $Services -notcontains $svc) { continue }
            $cname = "fluent-$svc"
            $exists = & $ContainerCmd container exists $cname 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Success "$svc container already exists"; continue }

            switch ($svc) {
                "api" {
                    Write-Running "Building API image..."
                    & $ContainerCmd build -t fluent-api $ApiContext -f Dockerfile.dev
                    $envFlags = @("-e","NODE_ENV=development","-e","BOOTSTRAP_DATABASE_URL=postgres://postgres:postgres@localhost:5432/fluent","-e","MIGRATIONS_DATABASE_URL=postgres://api_migrator:password@localhost:5432/fluent","-e","DATABASE_URL=postgres://api_user:password@localhost:5432/fluent","-e","EXPORTS_DIR=/app/exports")
                    if (Test-Path "$ApiContext/.env") { $envFlags += @("--env-file","$ApiContext/.env") }
                    & $ContainerCmd run -d --name fluent-api --pod $PodName @envFlags `
                        -v "$ApiContext/src:/app/src:ro" -v "$ApiContext/tsconfig.json:/app/tsconfig.json:ro" `
                        -v "$ApiContext/drizzle.config.ts:/app/drizzle.config.ts:ro" `
                        -v "$ApiContext/docker-entrypoint.sh:/app/docker-entrypoint.sh:ro" `
                        -v fluent-api-node-modules:/app/node_modules `
                        --tmpfs /tmp:noexec,nosuid,size=64m --tmpfs /app/.cache:noexec,nosuid,size=128m `
                        --tmpfs /app/exports:noexec,nosuid,size=256m `
                        --security-opt no-new-privileges:true --cap-drop ALL --user 1001:1001 --read-only `
                        --health-cmd "curl -f http://localhost:9999/health" --health-interval 10s `
                        --health-timeout 5s --health-retries 5 --health-start-period 15s fluent-api
                }
                "worker" {
                    $envFlags = @("-e","NODE_ENV=development","-e","BOOTSTRAP_DATABASE_URL=postgres://postgres:postgres@localhost:5432/fluent","-e","MIGRATIONS_DATABASE_URL=postgres://api_migrator:password@localhost:5432/fluent","-e","DATABASE_URL=postgres://api_user:password@localhost:5432/fluent","-e","EXPORTS_DIR=/app/exports")
                    if (Test-Path "$ApiContext/.env") { $envFlags += @("--env-file","$ApiContext/.env") }
                    & $ContainerCmd run -d --name fluent-worker --pod $PodName @envFlags `
                        -v "$ApiContext/src:/app/src:ro" -v "$ApiContext/tsconfig.json:/app/tsconfig.json:ro" `
                        -v fluent-worker-node-modules:/app/node_modules `
                        --tmpfs /tmp:noexec,nosuid,size=64m --tmpfs /app/.cache:noexec,nosuid,size=128m `
                        --tmpfs /app/exports:noexec,nosuid,size=256m `
                        --security-opt no-new-privileges:true --cap-drop ALL --user 1001:1001 --read-only `
                        fluent-api dumb-init -- npx tsx watch src/workers/standalone-worker.ts
                }
                "ai" {
                    Write-Running "Building AI image..."
                    & $ContainerCmd build -t fluent-ai $AiContext -f Dockerfile.dev
                    $envFlags = @("-e","BOOTSTRAP_DATABASE_URL=postgresql://postgres:postgres@localhost:5432/fluent","-e","MIGRATIONS_DATABASE_URL=postgresql+asyncpg://ai_migrator:password@localhost:5432/fluent","-e","DATABASE_URL=postgresql+asyncpg://ai_user:password@localhost:5432/fluent","-e","ENVIRONMENT=development","-e","DEBUG=true","-e","UV_CACHE_DIR=/app/.cache/uv")
                    if (Test-Path "$AiContext/.env") { $envFlags += @("--env-file","$AiContext/.env") }
                    & $ContainerCmd run -d --name fluent-ai --pod $PodName @envFlags `
                        -v "$AiContext/src:/app/src:ro" -v "$AiContext/tests:/app/tests:ro" `
                        -v "$AiContext/pyproject.toml:/app/pyproject.toml:ro" `
                        -v "$AiContext/uv.lock:/app/uv.lock:ro" `
                        -v "$AiContext/docker-entrypoint.sh:/app/docker-entrypoint.sh:ro" `
                        -v fluent-ai-logs:/app/logs `
                        --tmpfs /tmp:nosuid,size=64m --tmpfs /app/.cache:noexec,nosuid,size=128m `
                        --security-opt no-new-privileges:true --cap-drop ALL --user 1001:1001 --read-only fluent-ai
                }
                "web" {
                    Write-Running "Building Web image..."
                    & $ContainerCmd build -t fluent-web $WebContext -f Dockerfile.dev
                    $envFlags = @("-e","COREPACK_HOME=/app/.cache/corepack","-e","COREPACK_ENABLE_AUTO_PIN=0","-e","VITE_API_URL=http://localhost:${ApiPort}")
                    if (Test-Path "$WebContext/.env") { $envFlags += @("--env-file","$WebContext/.env") }
                    & $ContainerCmd run -d --name fluent-web --pod $PodName @envFlags `
                        -v "$WebContext/src:/app/src" -v "$WebContext/public:/app/public:ro" `
                        -v "$WebContext/index.html:/app/index.html:ro" `
                        -v "$WebContext/vite.config.ts:/app/vite.config.ts" `
                        -v "$WebContext/tsconfig.json:/app/tsconfig.json:ro" `
                        -v "$WebContext/tsconfig.node.json:/app/tsconfig.node.json:ro" `
                        -v "$WebContext/components.json:/app/components.json:ro" `
                        -v "$WebContext/eslint.config.js:/app/eslint.config.js:ro" `
                        -v "$WebContext/.prettierrc.js:/app/.prettierrc.js:ro" `
                        -v "$WebContext/.prettierignore:/app/.prettierignore:ro" `
                        -v "$WebContext/.env:/app/.env:ro" `
                        -v fluent-web-node-modules:/app/node_modules `
                        -v fluent-web-cache:/app/.cache `
                        -v fluent-web-eslintcache:/app/.eslintcache `
                        --tmpfs /tmp:nosuid,size=64m `
                        --security-opt no-new-privileges:true --cap-drop ALL --user 1001:1001 fluent-web
                }
            }
            Write-Success "$svc container started"
        }
        Write-Success "All services started!"
    } else {
        if ($Services.Count -eq 0) { Invoke-Compose @("up", "-d", "--build") }
        else { Invoke-Compose @("up", "-d", "--build", "--no-deps") + $Services }
    }
}

function Ecosystem-Down {
    param([string[]]$Services)
    if ($RuntimeMode -eq "podman-pod") {
        if ($Services.Count -eq 0) {
            Write-Running "Stopping services..."
            & $ContainerCmd pod rm $PodName -f 2>$null | Out-Null
            Write-Success "Services stopped."
        } else {
            foreach ($svc in $Services) {
                Write-Running "Stopping $svc..."
                & $ContainerCmd rm -f "fluent-$svc" 2>$null | Out-Null
            }
        }
    } else {
        if ($Services.Count -eq 0) { Invoke-Compose @("down") }
        else { Invoke-Compose @("rm", "-sf") + $Services }
    }
}

function Ecosystem-Restart {
    param([string[]]$Services)
    if ($RuntimeMode -eq "podman-pod") {
        if ($Services.Count -eq 0) {
            Write-Running "Restarting all services..."
            & $ContainerCmd pod rm $PodName -f 2>$null | Out-Null
            Ecosystem-Up
        } else {
            foreach ($svc in $Services) {
                Write-Running "Restarting $svc..."
                & $ContainerCmd rm -f "fluent-$svc" 2>$null | Out-Null
            }
            Ecosystem-Up -Services $Services
        }
    } else {
        if ($Services.Count -eq 0) { Invoke-Compose @("restart") }
        else { Invoke-Compose @("restart") + $Services }
    }
}

function Ecosystem-Logs {
    param([string[]]$Services)
    if ($RuntimeMode -eq "podman-pod") {
        if ($Services.Count -eq 0) { & $ContainerCmd pod logs -f $PodName }
        else { & $ContainerCmd logs -f "fluent-$($Services[0])" }
    } else {
        Invoke-Compose @("logs", "-f") + $Services
    }
}

function Ecosystem-Status {
    if ($RuntimeMode -eq "podman-pod") {
        & $ContainerCmd pod ps
        $existing = & $ContainerCmd pod exists $PodName 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host ""
            Write-Host "Containers in pod $PodName:"
            & $ContainerCmd ps -a --filter "pod=$PodName"
        }
    } else {
        Invoke-Compose @("ps")
    }
}

function Ecosystem-Shell {
    param([string]$Service = "api")
    if ($Service -eq "db") {
        if ($RuntimeMode -eq "podman-pod") { & $ContainerCmd exec -it fluent-db psql -U postgres -d fluent }
        else { Invoke-Compose @("exec", "db", "psql", "-U", "postgres", "-d", "fluent") }
    } else {
        Invoke-Exec $Service @("sh")
    }
}

function Ecosystem-Clean {
    param([string]$Target = "all")
    Write-Running "This will remove containers AND volumes (full DB reset)."
    $confirm = Read-Host "Continue? [y/N]"
    if ($confirm -match "^[Yy]$") {
        if ($RuntimeMode -eq "podman-pod") {
            if ($Target -eq "all") {
                & $ContainerCmd pod rm $PodName -f 2>$null | Out-Null
                & $ContainerCmd volume rm fluent-pgdata fluent-api-node-modules fluent-worker-node-modules fluent-web-node-modules fluent-web-cache fluent-ai-logs fluent-web-eslintcache 2>$null | Out-Null
                Write-Success "All containers and volumes removed"
            } else {
                & $ContainerCmd rm -f "fluent-$Target" 2>$null | Out-Null
                Write-Success "$Target container removed"
            }
        } else {
            if ($Target -eq "all") { Invoke-Compose @("down", "-v") }
            else { Invoke-Compose @("rm", "-sf", $Target) }
        }
    } else {
        Write-Host "Aborted."
    }
}

function Ecosystem-Fresh {
    Write-Running "This will destroy ALL containers, volumes, and images."
    $confirm = Read-Host "Continue? [y/N]"
    if ($confirm -match "^[Yy]$") {
        if ($RuntimeMode -eq "podman-pod") {
            & $ContainerCmd pod rm $PodName -f 2>$null | Out-Null
            & $ContainerCmd volume rm fluent-pgdata fluent-api-node-modules fluent-worker-node-modules fluent-web-node-modules fluent-ai-logs fluent-web-eslintcache 2>$null | Out-Null
            & $ContainerCmd rmi -f fluent-api fluent-ai fluent-web 2>$null | Out-Null
        } else {
            Invoke-Compose @("down", "-v", "--rmi", "local", "--remove-orphans")
        }
        Write-Host ""
        Write-Success "Clean slate. Run '.\fluent.ps1 up' to rebuild and start everything."
    } else {
        Write-Host "Aborted."
    }
}

function Ecosystem-Build {
    param([string[]]$Services)
    if ($Services.Count -eq 0) { $Services = @("api", "ai", "web") }
    if ($RuntimeMode -eq "podman-pod") {
        foreach ($svc in $Services) {
            switch ($svc) {
                "api"  { & $ContainerCmd build -t fluent-api $ApiContext -f Dockerfile.dev }
                "ai"   { & $ContainerCmd build -t fluent-ai $AiContext -f Dockerfile.dev }
                "web"  { & $ContainerCmd build -t fluent-web $WebContext -f Dockerfile.dev }
            }
        }
    } else {
        if ($Services.Count -eq 0) { Invoke-Compose @("build", "--no-cache") }
        else { Invoke-Compose @("build", "--no-cache") + $Services }
    }
    Write-Success "Build complete"
}

# ── Repo-specific commands ──────────────────────────────────────────────────────

function Invoke-RepoCmd {
    param([string]$Repo, [string]$Cmd, [string[]]$Remaining)

    switch ($Repo) {
        "api" {
            switch ($Cmd) {
                "up"     { Ecosystem-Up -Services @("api") }
                "down"   { Ecosystem-Down -Services @("api") }
                "restart"{ Ecosystem-Restart -Services @("api") }
                "logs"   { Ecosystem-Logs -Services @("api") }
                "shell"  { Ecosystem-Shell "api" }
                "test"   { Invoke-Exec "api" @("npm", "run", "test") + $Remaining }
                "lint"   { Invoke-Exec "api" @("npm", "run", "lint") }
                "lint:fix" { Invoke-Exec "api" @("npm", "run", "lint:fix") }
                "format" { Invoke-Exec "api" @("npm", "run", "format") }
                "format:check" { Invoke-Exec "api" @("npm", "run", "format:check") }
                "typecheck" { Invoke-Exec "api" @("npm", "run", "typecheck") }
                "run"    { Invoke-Exec "api" @("npm", "run") + $Remaining }
                "db:migrate" { Invoke-Exec "api" @("npx", "drizzle-kit", "migrate") }
                "db:seed" {
                    Invoke-Exec "api" @("npx", "tsx", "src/db/seeds/roles.ts")
                    Invoke-Exec "api" @("npx", "tsx", "src/db/seeds/rbac.ts")
                }
                "db:generate" {
                    $name = if ($Remaining.Count -gt 0) { $Remaining[0] } else { throw "Usage: fluent.ps1 api db:generate <name>" }
                    Invoke-Exec "api" @("npx", "drizzle-kit", "generate", "--name", $name)
                }
                default  { Write-Error-Color "Unknown api command: $Cmd"; exit 1 }
            }
        }
        "ai" {
            switch ($Cmd) {
                "up"     { Ecosystem-Up -Services @("ai") }
                "down"   { Ecosystem-Down -Services @("ai") }
                "restart"{ Ecosystem-Restart -Services @("ai") }
                "logs"   { Ecosystem-Logs -Services @("ai") }
                "shell"  { Ecosystem-Shell "ai" }
                "test"   { Invoke-Exec "ai" @("uv", "run", "pytest", "tests/", "-v") + $Remaining }
                "lint"   { Invoke-Exec "ai" @("uv", "run", "ruff", "check") }
                "lint:fix" { Invoke-Exec "ai" @("uv", "run", "ruff", "check", "--fix") }
                "format" { Invoke-Exec "ai" @("uv", "run", "ruff", "format") }
                "format:check" { Invoke-Exec "ai" @("uv", "run", "ruff", "format", "--check") }
                "typecheck" { Invoke-Exec "ai" @("uv", "run", "mypy", "src") }
                "run"    { Invoke-Exec "ai" @("uv", "run") + $Remaining }
                "db:migrate" { Write-Host "(no migrations configured yet)" }
                "db:seed"    { Write-Host "(no seeds configured yet)" }
                default  { Write-Error-Color "Unknown ai command: $Cmd"; exit 1 }
            }
        }
        "web" {
            switch ($Cmd) {
                "up"     { Ecosystem-Up -Services @("web") }
                "down"   { Ecosystem-Down -Services @("web") }
                "restart"{ Ecosystem-Restart -Services @("web") }
                "logs"   { Ecosystem-Logs -Services @("web") }
                "shell"  { Ecosystem-Shell "web" }
                "test"   { Invoke-Exec "web" @("pnpm", "test") + $Remaining }
                "lint"   { Invoke-Exec "web" @("pnpm", "lint") }
                "lint:fix" { Invoke-Exec "web" @("pnpm", "lint:fix") }
                "format" { Invoke-Exec "web" @("pnpm", "format") }
                "format:check" { Invoke-Exec "web" @("pnpm", "format:check") }
                "typecheck" { Invoke-Exec "web" @("pnpm", "typecheck") }
                "precheck" { Invoke-Exec "web" @("pnpm", "precheck") }
                "preview"  { Invoke-Exec "web" @("pnpm", "preview") }
                "run"    { Invoke-Exec "web" @("pnpm") + $Remaining }
                default  { Write-Error-Color "Unknown web command: $Cmd"; exit 1 }
            }
        }
        "worker" {
            switch ($Cmd) {
                "up"     { Ecosystem-Up -Services @("worker") }
                "down"   { Ecosystem-Down -Services @("worker") }
                "restart"{ Ecosystem-Restart -Services @("worker") }
                "logs"   { Ecosystem-Logs -Services @("worker") }
                "shell"  { Ecosystem-Shell "worker" }
                default  { Write-Error-Color "Worker does not support '$Cmd'. Use 'api' for dev commands."; exit 1 }
            }
        }
    }
}

# ── Database commands ─────────────────────────────────────────────────────────

function Db-Migrate {
    param([string]$Target = "all")
    switch ($Target) {
        "api" {
            Write-Running "Running fluent-api migrations..."
            Invoke-Exec "api" @("npx", "drizzle-kit", "migrate")
            Write-Success "API migrations completed"
        }
        "ai" {
            Write-Running "Running fluent-ai migrations..."
            Invoke-Exec "ai" @("uv", "run", "alembic", "upgrade", "head")
            Write-Success "AI migrations completed"
        }
        "all" {
            $confirm = Read-Host "Run migrations for all services? [y/N]"
            if ($confirm -match "^[Yy]$") {
                Db-Migrate "api"
                Db-Migrate "ai"
            } else { Write-Host "Aborted." }
        }
        default { Write-Error-Color "Unknown migrate target: $Target"; exit 1 }
    }
}

function Db-Seed {
    param([string]$Target = "all")
    switch ($Target) {
        "api" {
            Write-Running "Running fluent-api seeds..."
            Invoke-Exec "api" @("npx", "tsx", "src/db/seeds/roles.ts")
            Invoke-Exec "api" @("npx", "tsx", "src/db/seeds/rbac.ts")
            Write-Success "API seeds completed"
        }
        "ai" {
            Write-Running "Running fluent-ai seeds..."
            Invoke-Exec "ai" @("env", "PYTHONPATH=/app/src", "uv", "run", "python", "-m", "app.db.seeds")
            Write-Success "AI seeds completed"
        }
        "all" {
            $confirm = Read-Host "Run seeds for all services? [y/N]"
            if ($confirm -match "^[Yy]$") {
                Db-Seed "api"
                Db-Seed "ai"
            } else { Write-Host "Aborted." }
        }
        default { Write-Error-Color "Unknown seed target: $Target"; exit 1 }
    }
}

function Db-Init {
    Write-Running "Full database initialization (migrations + seeds)..."
    $confirm = Read-Host "This will run all migrations and seeds. Continue? [y/N]"
    if ($confirm -match "^[Yy]$") {
        Invoke-Exec "api" @("npm", "run", "db:setup")
        Invoke-Exec "ai" @("env", "PYTHONPATH=/app/src", "uv", "run", "python", "src/app/db/scripts/setup.py")
        Write-Success "Database initialization complete."
    } else {
        Write-Host "Aborted."
    }
}

function Db-Psql {
    if ($RuntimeMode -eq "podman-pod") { & $ContainerCmd exec -it fluent-db psql -U postgres -d fluent }
    else { Invoke-Compose @("exec", "db", "psql", "-U", "postgres", "-d", "fluent") }
}

function Db-Studio {
    Write-Host "Running Drizzle Studio on host (requires local Node.js)..."
    Write-Host "Connects to DB via DATABASE_URL in .env (localhost:$DbPort)"
    npx drizzle-kit studio
}

# ── Repo git sync ─────────────────────────────────────────────────────────────

function Sync-One {
    param([string]$Name, [string]$Path)
    if (-not (Test-Path "$Path/.git")) {
        Write-Error-Color "  [skip] $Name -> $Path (not a git repo)"
        return
    }
    Write-Running "Syncing $Name..."
    $dirty = git -C $Path status --porcelain
    if ($dirty) {
        Write-Error-Color "  [skip] $Name has uncommitted changes; leaving as-is"
        return
    }
    git -C $Path fetch --prune origin
    git -C $Path checkout main
    git -C $Path pull --ff-only
    if ($LASTEXITCODE -eq 0) {
        Write-Success "  [ok] $Name on main, up to date"
    } else {
        Write-Error-Color "  [warn] $Name could not fast-forward; resolve manually"
    }
}

function Sync-Repos {
    Write-Host "=== Switching all repos to main and pulling latest ==="
    Write-Host ""
    Sync-One "fluent-platform" $ScriptDir
    foreach ($repo in $Repos) {
        Sync-One $repo.Name $repo.Path
    }
    Write-Host ""
    Write-Success "Sync complete."
}

function Status-One {
    param([string]$Name, [string]$Path)
    if (-not (Test-Path "$Path/.git")) {
        Write-Host "  [skip] $Name -> $Path (not a git repo)"
        return
    }
    $branch = git -C $Path rev-parse --abbrev-ref HEAD 2>$null
    $dirty = if (git -C $Path status --porcelain) { " (dirty)" } else { "" }
    git -C $Path fetch --quiet origin 2>$null
    git -C $Path rev-parse --abbrev-ref "@{upstream}" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $counts = git -C $Path rev-list --left-right --count "@{upstream}...HEAD" 2>$null
        $parts = $counts -split "\s+"
        $state = "ahead $($parts[1]), behind $($parts[0])"
    } else {
        $state = "no upstream"
    }
    Write-Host ("  {0,-18} {1}{2} [{3}]" -f $Name, $branch, $dirty, $state)
}

function Status-Repos {
    Write-Host "=== Repo status (branch / ahead / behind vs upstream) ==="
    Write-Host ""
    Status-One "fluent-platform" $ScriptDir
    foreach ($repo in $Repos) {
        Status-One $repo.Name $repo.Path
    }
}

function Invoke-Repos {
    param([string]$Sub = "check")
    switch ($Sub) {
        "check"  { Test-Repos | Out-Null }
        "sync"   { Sync-Repos }
        "status" { Status-Repos }
        default  { Write-Error-Color "Unknown repos command: $Sub (use check, sync, or status)"; exit 1 }
    }
}

# ── Setup ─────────────────────────────────────────────────────────────────────

function Setup {
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
    Write-Host "  1. Fill in credentials in each .env file (Auth0, API keys, etc.)"
    Write-Host "  2. Run: .\fluent.ps1 up"
}

# ── Main dispatcher ───────────────────────────────────────────────────────────

Write-Host "Runtime mode: $RuntimeMode"
if ($RuntimeMode -eq "podman-pod") { Write-Host "Using native Podman pods" }
else { Write-Host "Using Docker Compose" }
Write-Host ""

$repoTargets = @("api", "ai", "web", "worker")

if ($Command -eq "repos") {
    $sub = if ($Args.Count -gt 0) { $Args[0] } else { "check" }
    Invoke-Repos -Sub $sub
} elseif ($repoTargets -contains $Command) {
    $repoCmd = if ($Args.Count -gt 0) { $Args[0] } else { "up" }
    $remaining = if ($Args.Count -gt 1) { $Args[1..($Args.Count - 1)] } else { @() }
    Invoke-RepoCmd -Repo $Command -Cmd $repoCmd -Remaining $remaining
} else {
    switch ($Command) {
        "up"        { Ecosystem-Up -Services $Args }
        "down"      { Ecosystem-Down -Services $Args }
        "restart"   { Ecosystem-Restart -Services $Args }
        "logs"      { Ecosystem-Logs -Services $Args }
        "status"    { Ecosystem-Status }
        "shell"     { $svc = if ($Args.Count -gt 0) { $Args[0] } else { "api" }; Ecosystem-Shell $svc }
        "db:migrate"{ Db-Migrate ($Args[0]) }
        "db:seed"   { Db-Seed ($Args[0]) }
        "db:init"   { Db-Init }
        "db:psql"   { Db-Psql }
        "db:studio" { Db-Studio }
        "clean"     { Ecosystem-Clean ($Args[0]) }
        "fresh"     { Ecosystem-Fresh }
        "build"     { Ecosystem-Build -Services $Args }
        "setup"     { Setup }
        "check-repos" { Test-Repos | Out-Null }  # deprecated alias for 'repos check'
        default {
            Write-Host @"
Usage: .\fluent.ps1 <command> [args]

Ecosystem commands:
  up [service...]         Start all services or specific ones
  down [service...]       Stop all or specific services
  restart [service...]    Restart services
  logs [service]          Tail logs (default: all)
  status                  Show container status
  shell <service>         Open a shell (db opens psql)

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

Repos (all sibling repos + platform):
  repos check             Verify sibling repos exist
  repos sync              Switch all repos to main and pull latest
  repos status            Show each repo's branch + ahead/behind
  check-repos             Deprecated alias for 'repos check'

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
"@
        }
    }
}
