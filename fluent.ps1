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

# ── Runtime detection (prefer Podman) ──────────────────────────────────────────

function Get-ComposeCommand {
    if ((Get-Command podman -ErrorAction SilentlyContinue) -and (Get-Command podman-compose -ErrorAction SilentlyContinue)) {
        return "podman-compose"
    }
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $v2 = & docker compose version 2>&1
        if ($LASTEXITCODE -eq 0) { return "docker compose" }
        if (Get-Command docker-compose -ErrorAction SilentlyContinue) { return "docker-compose" }
    }
    Write-Error @"
No container runtime found. Install one of:
  - Podman + podman-compose
  - Docker Desktop (includes docker compose V2)
  - Docker Engine + docker-compose
"@
    exit 1
}

$Compose = Get-ComposeCommand

function Invoke-Compose {
    param([string[]]$ComposeArgs)
    if ($Compose -eq "docker compose") {
        & docker compose @ComposeArgs
    } else {
        & $Compose @ComposeArgs
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
        Invoke-Compose @("up", "-d", "--build") + $Args
    }
    "down" {
        Invoke-Compose @("down") + $Args
    }
    "restart" {
        Invoke-Compose @("restart") + $Args
    }
    "logs" {
        Invoke-Compose @("logs", "-f") + $Args
    }
    "status" {
        Invoke-Compose @("ps") + $Args
    }
    "shell" {
        $service = if ($Args.Count -gt 0) { $Args[0] } else { "api" }
        if ($service -eq "db") {
            Invoke-Compose @("exec", "db", "psql", "-U", "postgres", "-d", "fluent")
        } else {
            Invoke-Compose @("exec", $service, "sh")
        }
    }
    "run" {
        if ($Args.Count -lt 2) { Write-Error "Usage: fluent.ps1 run <service> <script>"; exit 1 }
        $service = $Args[0]
        $remaining = $Args[1..($Args.Count - 1)]
        Invoke-Compose @("exec", $service, "npm", "run") + $remaining
    }
    "test" {
        if ($Args.Count -lt 1) { Write-Error "Usage: fluent.ps1 test <service>"; exit 1 }
        $service = $Args[0]
        $remaining = if ($Args.Count -gt 1) { $Args[1..($Args.Count - 1)] } else { @() }
        Invoke-Compose @("exec", $service, "npm", "run", "test") + $remaining
    }

    # ── Database commands ──────────────────────────────────────────────────────

    "db:migrate" {
        $target = if ($Args.Count -gt 0) { $Args[0] } else { "all" }
        switch ($target) {
            "api" {
                Write-Host "Running fluent-api migrations..."
                Invoke-Compose @("exec", "api", "npx", "drizzle-kit", "migrate")
            }
            "ai" {
                Write-Host "Running fluent-ai migrations..."
                Invoke-Compose @("exec", "ai", "npm", "run", "db:migrate")
            }
            "all" {
                Write-Host "Running fluent-api migrations..."
                Invoke-Compose @("exec", "api", "npx", "drizzle-kit", "migrate")
                Write-Host "Running fluent-ai migrations..."
                Invoke-Compose @("exec", "ai", "npm", "run", "db:migrate")
            }
            default {
                Write-Error "Unknown migrate target: $target (use api, ai, or all)"
            }
        }
    }
    "db:seed" {
        $target = if ($Args.Count -gt 0) { $Args[0] } else { "all" }
        switch ($target) {
            "api" {
                Write-Host "Running fluent-api seeds..."
                Invoke-Compose @("exec", "api", "npx", "tsx", "src/db/seeds/roles.ts")
                Invoke-Compose @("exec", "api", "npx", "tsx", "src/db/seeds/rbac.ts")
                Invoke-Compose @("exec", "api", "npx", "tsx", "src/db/seeds/users.ts")
            }
            "ai" {
                Write-Host "Running fluent-ai seeds..."
                Invoke-Compose @("exec", "ai", "npm", "run", "db:seed")
            }
            "all" {
                Write-Host "Running fluent-api seeds..."
                Invoke-Compose @("exec", "api", "npx", "tsx", "src/db/seeds/roles.ts")
                Invoke-Compose @("exec", "api", "npx", "tsx", "src/db/seeds/rbac.ts")
                Invoke-Compose @("exec", "api", "npx", "tsx", "src/db/seeds/users.ts")
                Write-Host "Running fluent-ai seeds..."
                Invoke-Compose @("exec", "ai", "npm", "run", "db:seed")
            }
            default {
                Write-Error "Unknown seed target: $target (use api, ai, or all)"
            }
        }
    }
    "db:init" {
        Write-Host "Full database initialization (migrations + seeds)..."
        & $MyInvocation.MyCommand.Path "db:migrate" "all"
        & $MyInvocation.MyCommand.Path "db:seed" "all"
        Write-Host "Database initialization complete."
    }
    "db:studio" {
        $port = if ($env:DB_PORT) { $env:DB_PORT } else { "5432" }
        Write-Host "Running Drizzle Studio on host (requires local Node.js)..."
        Write-Host "Connects to DB via DATABASE_URL in .env (localhost:$port)"
        npx drizzle-kit studio
    }
    "db:psql" {
        Invoke-Compose @("exec", "db", "psql", "-U", "postgres", "-d", "fluent")
    }

    # ── Lifecycle commands ─────────────────────────────────────────────────────

    "clean" {
        $target = if ($Args.Count -gt 0) { $Args[0] } else { "all" }
        Write-Host "This will remove containers AND volumes (full DB reset)."
        $confirm = Read-Host "Continue? [y/N]"
        if ($confirm -match "^[Yy]$") {
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
        } else {
            Write-Host "Aborted."
        }
    }
    "build" {
        Invoke-Compose @("build", "--no-cache") + $Args
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
  build [service...]     Rebuild containers without cache
  check-repos            Verify sibling repos exist
  setup                  Clone repos, copy .env files, first-time setup
"@
    }
}
