# install-task.ps1
# Runs once from FirstLogonCommands. Registers a scheduled task that fires on
# every logon (with a delay to let wifi/DHCP settle) and executes
# wait-and-run.ps1. Exits immediately afterwards.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$logDir = Join-Path $env:ProgramData 'MAS'
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}
$log = Join-Path $logDir 'install.log'

function Log([string]$m) {
    "$(Get-Date -Format o)  $m" | Out-File -LiteralPath $log -Append -Encoding utf8
}

try {
    Log "install-task.ps1 starting."

    $waitScript = Join-Path $PSScriptRoot 'wait-and-run.ps1'
    if (-not (Test-Path -LiteralPath $waitScript -PathType Leaf)) {
        throw "wait-and-run.ps1 not found next to install-task.ps1: $waitScript"
    }

    # Task action: run the wait-and-run script hidden, as the current user.
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$waitScript`""

    # Logon trigger with a 90-second delay so wifi/DHCP/DNS can come up first.
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn
    $logonTrigger.Delay = 'PT90S'

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 5) `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    # Run as the logged-on user. This is required so the task can see the
    # user's wifi profile, mapped drives, and user-scoped state. SYSTEM would
    # not have any of those.
    $userName = "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId $userName `
        -LogonType Interactive -RunLevel Highest

    Register-ScheduledTask -TaskName 'MAS' `
        -Action $action -Trigger $logonTrigger `
        -Settings $settings -Principal $principal `
        -Force | Out-Null

    Log "Registered scheduled task 'MAS' for $userName with 90s logon delay."
    Log "install-task.ps1 completed successfully."
    exit 0
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    if ($_.ScriptStackTrace) { Log "Stack: $($_.ScriptStackTrace)" }
    exit 1
}