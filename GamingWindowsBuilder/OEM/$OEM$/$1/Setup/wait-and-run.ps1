# wait-and-run.ps1
# Fires on every logon via the 'MAS' scheduled task. Exits immediately if
# a previous run succeeded. Waits briefly for network, then runs the friend's
# MAS_AIO.cmd with the /HWID argument. On success, writes a marker file and
# unregisters the scheduled task so it never runs again. On failure, exits
# non-zero so Task Scheduler retries on the next logon.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$logDir     = Join-Path $env:ProgramData 'NAS-Setup'
$log        = Join-Path $logDir 'setup.log'
$doneMarker = Join-Path $logDir 'done.flag'
$attemptsF  = Join-Path $logDir 'attempts.txt'

if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}

function Log([string]$m) {
    "$(Get-Date -Format o)  $m" | Out-File -LiteralPath $log -Append -Encoding utf8
}

# --- Already done? Bail out silently. ---
if (Test-Path -LiteralPath $doneMarker) {
    exit 0
}

# --- Locate script next to this one. ---
$cmdScript = Join-Path $PSScriptRoot 'MAS_AIO.cmd'
if (-not (Test-Path -LiteralPath $cmdScript -PathType Leaf)) {
    Log "ERROR: MAS_AIO.cmd not found next to wait-and-run.ps1: $cmdScript"
    exit 2   # 2 = permanent error; do not retry
}

# --- Attempt counter ---
$n = 0
if (Test-Path -LiteralPath $attemptsF) {
    $raw = (Get-Content -LiteralPath $attemptsF -Raw -ErrorAction SilentlyContinue)
    if ($raw -and [int]::TryParse($raw.Trim(), [ref]$n)) { } else { $n = 0 }
}
$n++
$n | Out-File -LiteralPath $attemptsF -Encoding ascii -Force

$maxTries = 20
Log "Attempt $n of $maxTries."

# --- Wait for usable network. Short loop: task already delayed 90s at logon,
#     so this only needs to bridge the remaining gap. ---
$online = $false
for ($i = 0; $i -lt 24; $i++) {
    try {
        if (Test-Connection -ComputerName 1.1.1.1 -Count 1 -Quiet -ErrorAction Stop) {
            $online = $true
            break
        }
    } catch { }
    Start-Sleep -Seconds 5
}
if (-not $online) {
    Log "No usable network after 2 minutes; will retry on next logon."
    exit 1   # 1 = retry
}

# --- Run the friend's script non-interactively. ---
$arg = '/HWID'
Log "Running: `"$cmdScript`" $arg"

try {
    $p = Start-Process -FilePath 'cmd.exe' `
        -ArgumentList "/c `"`"$cmdScript`" $arg`"" `
        -Wait -PassThru -NoNewWindow
    $code = [int]$p.ExitCode
}
catch {
    Log "ERROR launching setup.cmd: $($_.Exception.Message)"
    exit 1
}

Log "MAS_AIO.cmd $arg exited with code $code"

if ($code -eq 0) {
    # Success: marker + unregister the task.
    New-Item -ItemType File -Force -Path $doneMarker | Out-Null
    Remove-Item -LiteralPath $attemptsF -Force -ErrorAction SilentlyContinue

    try {
        Unregister-ScheduledTask -TaskName 'MAS' -Confirm:$false -ErrorAction Stop
        Log "Success. Task 'MAS' unregistered."
    }
    catch {
        Log "Success, but could not unregister task: $($_.Exception.Message)"
    }
    exit 0
}

# Non-zero: retry policy.
if ($n -ge $maxTries) {
    Log "Reached max attempts ($maxTries) with last exit code $code. Leaving task registered for manual review."
    # Intentionally do NOT unregister and do NOT write the done marker, so the
    # failure is visible to whoever inspects the machine.
    exit 2
}

Log "Non-zero exit; will retry on next logon."
exit 1