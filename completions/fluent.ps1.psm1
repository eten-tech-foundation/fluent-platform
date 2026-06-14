# PowerShell completion for .\fluent.ps1
#
# Load it for the current session:
#   Import-Module /path/to/fluent-platform/completions/fluent.ps1.psm1
#
# Load it for every session - add the line above to your $PROFILE:
#   notepad $PROFILE
#
# Keep the word lists below in sync with fluent.ps1's dispatcher.

$script:FluentEcosystem = @(
    'up', 'down', 'restart', 'logs', 'status', 'shell', 'clean', 'fresh', 'build',
    'setup', 'check-repos', 'db:migrate', 'db:seed', 'db:init', 'db:psql', 'db:studio',
    'repos', 'help'
)
$script:FluentTargets  = @('api', 'ai', 'web', 'worker')
$script:FluentServices = @('api', 'ai', 'web', 'worker', 'db')

$script:FluentSubcommands = @{
    'repos'      = @('check', 'sync', 'status')
    'api'        = @('up', 'down', 'restart', 'logs', 'shell', 'test', 'lint', 'lint:fix', 'format', 'format:check', 'typecheck', 'run', 'db:migrate', 'db:seed', 'db:generate')
    'ai'         = @('up', 'down', 'restart', 'logs', 'shell', 'test', 'lint', 'lint:fix', 'format', 'format:check', 'typecheck', 'run')
    'web'        = @('up', 'down', 'restart', 'logs', 'shell', 'test', 'lint', 'lint:fix', 'format', 'format:check', 'typecheck', 'precheck', 'preview', 'run')
    'worker'     = @('up', 'down', 'restart', 'logs', 'shell')
    'db:migrate' = @('api', 'ai', 'all')
    'db:seed'    = @('api', 'ai', 'all')
    'up'         = $script:FluentTargets
    'down'       = $script:FluentTargets
    'restart'    = $script:FluentTargets
    'build'      = $script:FluentTargets
    'clean'      = $script:FluentTargets
    'logs'       = $script:FluentServices
    'shell'      = $script:FluentServices
}

$fluentCompleter = {
    param($wordToComplete, $commandAst, $cursorPosition)

    # Elements after the script name itself.
    $elements = @($commandAst.CommandElements | Select-Object -Skip 1 | ForEach-Object { $_.ToString() })

    # Are we still typing the current word, or starting a new one?
    $typingNew = [string]::IsNullOrEmpty($wordToComplete)
    $position  = if ($typingNew) { $elements.Count } else { $elements.Count - 1 }

    $candidates = @()
    if ($position -le 0) {
        $candidates = $script:FluentEcosystem + $script:FluentTargets
    } elseif ($position -eq 1) {
        $first = $elements[0]
        if ($script:FluentSubcommands.ContainsKey($first)) {
            $candidates = $script:FluentSubcommands[$first]
        }
    }

    $candidates |
        Where-Object { $_ -like "$wordToComplete*" } |
        Sort-Object -Unique |
        ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
}

# Cover the common ways the script is invoked.
Register-ArgumentCompleter -CommandName 'fluent.ps1', '.\fluent.ps1', './fluent.ps1' -Native -ScriptBlock $fluentCompleter
