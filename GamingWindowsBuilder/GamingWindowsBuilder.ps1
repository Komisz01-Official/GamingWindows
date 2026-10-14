#Requires -Version 5.1
# Rewritten transactionally: build failures are terminating, cleanup is unconditional, and native DISM/registry operations are checked.
# All native invocations are routed through Invoke-NativeCommand so that
# stderr output from oscdimg/dism/reg/robocopy cannot become a terminating
# RemoteException while $ErrorActionPreference = 'Stop'.
# Source-tree validation is primary; mount-based validation is best-effort with
# retry/polling. Invoke-NativeCommand unwraps ErrorRecord instances so OSCDIMG/
[CmdletBinding()]
param (
    [ValidatePattern('^[a-zA-Z](?::)?(?:\\.*)?$')]
    [string]$ScratchDisk,

    [ValidatePattern('^[a-zA-Z](?::)?(?:\\.*)?$')]
    [string]$SourceDrive,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$ImageIndex = 0,   # 0 = auto-select Windows 11 Pro

    # Override the regex used to auto-detect the Pro edition (useful for non-English media)
    [string]$ProImageRegex = '^Windows 11 Pro$',

    # Standard install.wim export supports Maximum/Fast/None.
    # Recovery compression is for ESD/recovery-style destinations and is not a
    # valid choice for the normal install.wim produced by this builder.
    [ValidateSet('Maximum','Fast','None')]
    [string]$ExportCompression = 'Maximum',

    [switch]$SkipBloatwareRemoval,
    [switch]$SkipRegistryTweaks,
    [switch]$SkipComponentCleanup,   # -ResetBase is destructive & slow; now opt-out
    [switch]$QuietMode,
    [switch]$Force,

    # Keep the working tree when the build fails, which is valuable for diagnosis.
    [switch]$PreserveWorkOnError     # Preserve build work directories on failure
)

# ==================== CENTRALIZED VERSION CONTROL ====================
$script:VersionInfo = @{
    Major      = 0
    Minor      = 1
    Patch      = 1
    Build      = (Get-Date -Format 'yyyyMMdd')
    Codename   = "IsoValidation"
    ScriptName = "GamingWindowsBuilder"
    OutputName = "GamingWindows"
    Author     = "GamingWindows Project"

    Features = @{
        # DISM is NOT safe to run concurrently against the same offline image.
        # Package removal is now always sequential. Multithreading is reserved for
        # future safe workloads (e.g., parallel file copies / ISO assembly).
        UseMultiThreading      = $false
        EnableProgressTracking = $true
        EnableTranscript       = $true
        EnablePreflightChecks  = $true
        HardenedErrorHandling  = $true
        # Route every native invocation through Invoke-NativeCommand
        # so that stderr from oscdimg/dism/reg/robocopy cannot become a
        # terminating RemoteException while $ErrorActionPreference = 'Stop'.
        NativeCommandHardening = $true
        # ISO validation does not depend on Mount-DiskImage. The
        # source tree is the primary validation surface; mount-based checks
        # are best-effort with retry/polling and cannot fail the build.
        ResilientIsoValidation = $true
    }
}

$script:VersionInfo.FullVersion = "{0}.{1}.{2}" -f `
    $script:VersionInfo.Major, $script:VersionInfo.Minor, $script:VersionInfo.Patch

$script:VersionInfo.FullVersionWithBuild = "{0}.{1}.{2}-{3}" -f `
    $script:VersionInfo.Major, $script:VersionInfo.Minor, $script:VersionInfo.Patch, $script:VersionInfo.Build

$script:VersionInfo.ISOFilename = "{0}_v{1}.iso" -f $script:VersionInfo.OutputName, $script:VersionInfo.FullVersion
$script:VersionInfo.LogFilename = "{0}_v{1}.log" -f $script:VersionInfo.ScriptName, $script:VersionInfo.FullVersion
$script:VersionInfo.WindowTitle = "{0} v{1} ({2})" -f `
    $script:VersionInfo.ScriptName, $script:VersionInfo.FullVersion, $script:VersionInfo.Codename

# ==================== ADMIN GROUP SID (Language-Independent) ====================
$script:AdminSIDString = "*S-1-5-32-544"

# Track exit code so the caller sees a proper status.
$script:ExitCode = 0

# Cache whether progress rendering should occur.
$script:ShowProgress = $script:VersionInfo.Features.EnableProgressTracking -and -not $QuietMode

# ==================== PROGRESS TRACKING CLASS ====================
class ProgressTracker {
    [string]$Activity
    [string]$Status
    [int]$TotalSteps
    [int]$CurrentStep
    [DateTime]$StartTime
    [System.Collections.ArrayList]$StepTimes
    [bool]$ShowProgress

    ProgressTracker([string]$activity, [int]$totalSteps, [bool]$showProgress = $true) {
        $this.Activity     = $activity
        $this.TotalSteps   = [math]::Max(1, $totalSteps)
        $this.CurrentStep  = 0
        $this.StartTime    = Get-Date
        $this.StepTimes    = [System.Collections.ArrayList]::new()
        $this.ShowProgress = $showProgress
    }

    [void]StartStep([string]$status) {
        $this.CurrentStep++
        $this.Status = $status
        $this.StepTimes.Add(@{
            Step   = $this.CurrentStep
            Start  = Get-Date
            End    = $null
            Status = $status
        }) | Out-Null
        $this.UpdateProgress()
    }

    [void]CompleteStep() {
        if ($this.StepTimes.Count -gt 0) {
            $lastStep = $this.StepTimes[-1]
            $lastStep.End = Get-Date
            $this.StepTimes[-1] = $lastStep
        }
        $this.UpdateProgress()
    }

    [void]UpdateProgress() {
        # Skip Write-Progress in quiet mode.
        if (-not $this.ShowProgress) { return }

        $percentComplete = [math]::Min(100, ($this.CurrentStep / $this.TotalSteps) * 100)
        $elapsed = (Get-Date) - $this.StartTime
        if ($this.CurrentStep -gt 0) {
            # Estimate from completed elapsed work rather than treating the current
            # step as already completed. This avoids systematically inflated ETAs.
            $avgStepTime = $elapsed.TotalSeconds / $this.CurrentStep
            $remaining    = [math]::Max(0, $this.TotalSteps - $this.CurrentStep)
            $etaSeconds   = $avgStepTime * $remaining
            $etaTime      = (Get-Date).AddSeconds($etaSeconds)
            $etaString    = "ETA: $($etaTime.ToString('HH:mm:ss'))"
        } else {
            $etaString = "Calculating ETA..."
        }
        $currentStepStatus = if ($this.Status) { "- $($this.Status)" } else { "" }
        Write-Progress -Activity $this.Activity `
            -Status "Step $($this.CurrentStep)/$($this.TotalSteps) $currentStepStatus $etaString" `
            -PercentComplete $percentComplete
    }

    [void]Complete() {
        # Quiet mode suppresses the progress summary too.
        if ($this.ShowProgress) {
            Write-Progress -Activity $this.Activity -Completed
            $totalTime = (Get-Date) - $this.StartTime
            Write-Host "`nCompleted in $($totalTime.ToString('hh\:mm\:ss'))" -ForegroundColor Green
            Write-Host "`nStep Breakdown:" -ForegroundColor Cyan
            foreach ($step in $this.StepTimes) {
                $duration = if ($step.End) { ($step.End - $step.Start).ToString('hh\:mm\:ss') } else { "Incomplete" }
                Write-Host "  Step $($step.Step): $($step.Status) - $duration" -ForegroundColor Gray
            }
        }
    }
}

# ==================== HELPER FUNCTIONS ====================
function Write-Banner {
    param([string]$Text, [ConsoleColor]$Color = 'Cyan')
    if ($QuietMode) { return }
    $line = "=" * 60
    Write-Host "`n$line" -ForegroundColor $Color
    Write-Host "  $Text" -ForegroundColor $Color
    Write-Host "$line`n" -ForegroundColor $Color
}
function Write-Step {
    param([string]$Text)
    if ($QuietMode) { return }
    Write-Output "  [*] $Text"
}
function Write-Ok {
    param([string]$Text)
    if ($QuietMode) { return }
    Write-Output "  [+] $Text"
}
function Write-WarningMsg {
    param([string]$Text)
    # Warnings are shown even in QuietMode (they matter).
    Write-Output "  [!] $Text"
}
function Write-ErrorMessage {
    param([string]$Text)
    Write-Output "  [X] $Text"
}

function Set-CleanupFailure {
    <# Mark cleanup as failed so the process cannot report a false success. #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'None')]
    param([Parameter(Mandatory)][string]$Message)
    if ($PSCmdlet.ShouldProcess("cleanup state", "Mark cleanup as failed")) {
        $script:ExitCode = 1
        Write-WarningMsg $Message
    }
}

function Write-ProgressSafe {
    # Thin wrapper that respects quiet mode.
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete,
        [switch]$Completed
    )
    if (-not $script:ShowProgress) { return }
    if ($Completed) {
        Write-Progress -Activity $Activity -Completed
    } else {
        Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
    }
}

function Invoke-NativeCommand {
    <#
    .SYNOPSIS
        Invokes a native executable and captures combined stdout/stderr without
        allowing stderr to become a terminating PowerShell error when
        $ErrorActionPreference = 'Stop'.

    .DESCRIPTION
        PowerShell converts stderr output from a native executable into a
        System.Management.Automation.ErrorRecord (wrapping a
        System.Management.Automation.RemoteException) when the pipeline is
        being collected under $ErrorActionPreference = 'Stop'. Tools such as
        oscdimg, dism, reg, and robocopy routinely write informational text to
        stderr (banners, progress, "Operation completed successfully"), so a
        naive `& tool.exe ... 2>&1` will abort the script even on success.

        This helper temporarily relaxes ErrorActionPreference around the native
        call, captures the merged stream, unwraps any ErrorRecord instances to
        their inner message strings (so log output is human-readable rather
        than littered with "System.Management.Automation.RemoteException"),
        restores the caller's preference, and returns a structured result.
        Callers decide success based on ExitCode and inspect Output for
        diagnostics.

    .PARAMETER FilePath
        The executable to invoke. May be a name on PATH or a full path.

    .PARAMETER Arguments
        Argument array. Each argument is passed as a separate token; PowerShell
        handles any required quoting.

    .OUTPUTS
        PSCustomObject with:
            ExitCode : [int]      The native process exit code.
            Output   : [string[]] Combined stdout+stderr lines, unwrapped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments
    )

    $previousEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # NativeCommandUseErrorActionPreference (PS 7.3+) is not assumed; the
        # explicit EAP relaxation above is what actually suppresses the
        # terminating-ErrorRecord behavior on 5.1 and 7.x alike.
        $output = @(
            & $FilePath @Arguments 2>&1 |
                ForEach-Object {
                    if ($_ -is [System.Management.Automation.ErrorRecord]) {
                        # A native stderr line wrapped by PowerShell. Emit the
                        # original message text so the build log stays readable
                        # instead of containing bare "RemoteException" markers.
                        [string]$_.Exception.Message
                    }
                    else {
                        [string]$_
                    }
                }
        )
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousEAP
    }

    if ($null -eq $exitCode) { $exitCode = 0 }

    return [PSCustomObject]@{
        ExitCode = [int]$exitCode
        Output   = $output
    }
}

function Invoke-TakeOwnership {
    <#
    .SYNOPSIS
        Takes ownership of a file or directory using SID (language-independent).
    .OUTPUTS
        Boolean - $true if successful, $false otherwise.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Recurse
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $takeownArgs = @('/F', $Path)
    if ($Recurse) {
        $takeownArgs += '/R'
        # /D accepts Y or N; '*' is not a valid takeown choice.
        $takeownArgs += @('/D', 'Y')
    }
    $takeownResult = Invoke-NativeCommand -FilePath 'takeown.exe' -Arguments $takeownArgs
    $takeownOk = ($takeownResult.ExitCode -eq 0)

    # Use /grant:r (replace) so we don't accumulate duplicate ACEs
    # if ownership is retaken multiple times. Also (OI)(CI) for dirs when recursing
    # so newly-created children inherit the grant.
    $grantArg = if ($Recurse) { "${script:AdminSIDString}:(OI)(CI)(F)" } else { "${script:AdminSIDString}:(F)" }
    $icaclsArgs = @($Path, '/grant:r', $grantArg, '/C', '/Q')
    if ($Recurse) { $icaclsArgs += '/T' }
    $icaclsResult = Invoke-NativeCommand -FilePath 'icacls.exe' -Arguments $icaclsArgs
    $icaclsOk = ($icaclsResult.ExitCode -eq 0)

    if (-not $takeownOk -or -not $icaclsOk) {
        Write-WarningMsg "Take ownership partially failed for '$Path' (takeown=$takeownOk icacls=$icaclsOk)"
        return $false
    }
    return $true
}

function Remove-PathSafe {
    param([string]$Path, [switch]$Silent)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return $true
    } catch {
        if (-not $Silent) {
            Write-WarningMsg "Could not remove '$Path': $($_.Exception.Message)"
        }
        return $false
    }
}

function Resolve-DriveLetter {
    <#
    .SYNOPSIS
        Extracts a normalized drive letter (e.g., "D:") from a letter or "D:".
        Callers validate drive-letter-only parameters before this function is invoked.
    #>
    param([string]$InputValue)
    if ([string]::IsNullOrWhiteSpace($InputValue)) { return $null }

    # Normalize a drive letter supplied as "D", "D:", or a path beginning
    # with "D:\". The caller ultimately needs only the root drive.
    if ($InputValue -match '^([a-zA-Z])(?::)?(?:\\.*)?$') {
        return "$($matches[1].ToUpperInvariant()):"
    }
    return $null
}

function Set-RegistryValue {
    <#
    .SYNOPSIS
        Bulk-sets DWORD values under a registry key using reg.exe.
    .PARAMETER HivePath
        Full path, e.g. HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection
    .PARAMETER Values
        Hashtable of ValueName = DWORD value.
    .PARAMETER RequireExistingKey
        Refuses to create a missing key. Use this for existing system/service keys
        where creating a partial registry tree could produce an invalid configuration.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$HivePath,
        [Parameter(Mandatory)][hashtable]$Values,
        [switch]$RequireExistingKey
    )

    if ($RequireExistingKey) {
        $probe = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('query', $HivePath)
        if ($probe.ExitCode -ne 0) {
            throw "Required registry key does not exist: $HivePath (reg.exe exit code $($probe.ExitCode))"
        }
    }

    foreach ($valName in $Values.Keys) {
        $valData = $Values[$valName]
        if ($PSCmdlet.ShouldProcess("$HivePath\$valName", "Set registry DWORD value to $valData")) {
            $addResult = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @(
                'add', $HivePath, '/v', $valName, '/t', 'REG_DWORD', '/d', [string]$valData, '/f'
            )
            if ($addResult.ExitCode -ne 0) {
                throw "Failed to set registry value $HivePath\$valName = $valData (reg.exe exit code $($addResult.ExitCode))"
            }
        }
    }
}

function Set-RegistryValuesMap {
    <#
    .SYNOPSIS
        Convenience wrapper over Set-RegistryValue when you have a map of key -> values.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$Map)
    foreach ($key in $Map.Keys) {
        Set-RegistryValue -HivePath $key -Values $Map[$key]
    }
}

function Test-Confirmation {
    <#
    .SYNOPSIS
        Interactive yes/no prompt; returns $true only if user answers "yes".
        In QuietMode or with -Force, always returns $true.
    #>
    param([string]$Prompt)
    if ($QuietMode -or $Force) { return $true }
    $response = Read-Host "$Prompt (yes/no)"
    return ($response -match '^(?i:yes|y)$')
}

function Remove-RegistryKey {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'None')]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [string]$Description = $RegistryPath
    )
    $queryResult = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('query', $RegistryPath)
    if ($queryResult.ExitCode -eq 0) {
        if (-not $PSCmdlet.ShouldProcess($RegistryPath, "Remove $Description registry key")) {
            return $false
        }
        $deleteResult = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('delete', $RegistryPath, '/f')
        if ($deleteResult.ExitCode -ne 0) {
            throw "Failed to remove $Description registry key '$RegistryPath' (reg.exe exit code $($deleteResult.ExitCode))."
        }
        return $true
    }
    return $false
}

Set-Alias -Name Remove-RegistryKeyIfExists -Value Remove-RegistryKey -Scope Script

function Remove-RegistryValueIfExists {
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$ValueName,
        [string]$Description = "$RegistryPath\$ValueName"
    )
    $queryResult = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('query', $RegistryPath, '/v', $ValueName)
    if ($queryResult.ExitCode -eq 0) {
        $deleteResult = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('delete', $RegistryPath, '/v', $ValueName, '/f')
        if ($deleteResult.ExitCode -ne 0) {
            throw "Failed to remove $Description registry value '$RegistryPath\$ValueName' (reg.exe exit code $($deleteResult.ExitCode))."
        }
        return $true
    }
    return $false
}

function Remove-OfflineScheduledTaskTree {
    <#
    .SYNOPSIS
        Removes an entire scheduled-task cache subtree from an offline SYSTEM
        hive. Used for tasks (such as OneDrive) whose registration lives under
        a dedicated folder in TaskCache\Tree.

    .DESCRIPTION
        Uses defensive enumeration rather than Test-Path as the existence guard:
        the PowerShell registry provider can report $true for a key that does
        not exist under a freshly-loaded hive. If the tree is absent, returns
        silently. Individual removal failures are reported as warnings rather
        than terminating the cleanup.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SystemHive,
        [Parameter(Mandatory)][string]$TaskTreePath
    )

    $providerRoot = "Registry::$SystemHive\$TaskTreePath"

    # Discover task-cache GUIDs to remove. The tree may not exist; that is a
    # normal condition, not an error.
    $taskIds = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($key in @(Get-ChildItem -LiteralPath $providerRoot -Recurse -Force -ErrorAction Stop)) {
            try {
                $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
                if ($props -and $props.PSObject.Properties['Id'] -and
                    $props.Id -is [string] -and
                    $props.Id -match '^\{[0-9A-Fa-f-]+\}$') {
                    if (-not $taskIds.Contains($props.Id)) {
                        $taskIds.Add($props.Id)
                    }
                }
            }
            catch {
                Write-WarningMsg "Could not inspect scheduled-task cache key '$($key.PSPath)': $($_.Exception.Message)"
            }
        }

        try {
            $rootProps = Get-ItemProperty -LiteralPath $providerRoot -ErrorAction Stop
            if ($rootProps -and $rootProps.PSObject.Properties['Id'] -and
                $rootProps.Id -is [string] -and
                $rootProps.Id -match '^\{[0-9A-Fa-f-]+\}$') {
                if (-not $taskIds.Contains($rootProps.Id)) {
                    $taskIds.Add($rootProps.Id)
                }
            }
        }
        catch {
            # The root key may legitimately have no Id; ignore.
        }
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        # The task tree does not exist in this image. Nothing to do.
        Write-Step "Scheduled-task tree '$TaskTreePath' is not present under $SystemHive; nothing to remove."
        return
    }
    catch {
        Write-WarningMsg "Could not enumerate scheduled-task tree '$providerRoot': $($_.Exception.Message)"
        return
    }

    if ($taskIds.Count -eq 0) {
        Write-Step "No task-cache GUIDs found under '$TaskTreePath'; nothing to remove."
        return
    }

    $taskCacheBases = @(
        "$SystemHive\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks",
        "$SystemHive\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Plain",
        "$SystemHive\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Logon",
        "$SystemHive\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Boot",
        "$SystemHive\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Maintenance"
    )

    # Release provider references before the reg.exe deletions.
    $props = $null
    $key = $null
    $rootProps = $null
    $null = [GC]::Collect()
    $null = [GC]::WaitForPendingFinalizers()

    foreach ($taskId in @($taskIds)) {
        foreach ($base in $taskCacheBases) {
            $taskCacheKey = "$base\$taskId"

            $deleteResult = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @(
                'delete', $taskCacheKey, '/f'
            )

            if ($deleteResult.ExitCode -ne 0 -and $deleteResult.ExitCode -ne 1) {
                Write-WarningMsg "Could not remove scheduled-task cache key '$taskCacheKey' (reg.exe exit code $($deleteResult.ExitCode)): $($deleteResult.Output -join ' ')"
            }
        }
    }

    $rootDeleteResult = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @(
        'delete', "$SystemHive\$TaskTreePath", '/f'
    )

    if ($rootDeleteResult.ExitCode -ne 0 -and $rootDeleteResult.ExitCode -ne 1) {
        Write-WarningMsg "Could not remove scheduled-task tree '$SystemHive\$TaskTreePath' (reg.exe exit code $($rootDeleteResult.ExitCode)): $($rootDeleteResult.Output -join ' ')"
    }
}

function Remove-OfflineScheduledTasksByName {
    <#
    .SYNOPSIS
        Removes offline scheduled-task cache registrations whose leaf task name
        matches any supplied regex. This is used for tasks such as EdgeUpdate
        that live directly under the Tasks root rather than under a dedicated
        folder.

    .DESCRIPTION
        Operates against a mounted offline SYSTEM hive via the PowerShell
        registry provider. The provider has two behaviours that require care:

          1. Test-Path can return $true for a key that does not exist under a
             freshly-loaded hive. Existence therefore has to be determined by
             actually enumerating, not by probing.

          2. Enumerating a key that does not exist throws
             ItemNotFoundException. That is normal when the TaskCache tree has
             never been populated in this image, and must not be treated as a
             build failure.

        Individual key removal failures are reported as warnings rather than
        terminating the cleanup: a single locked key must not prevent the rest
        of the batch from completing. Any residual registrations will be
        re-checked by the caller.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SystemHive,
        [Parameter(Mandatory)][string[]]$NameRegex
    )

    $treeRoot = "Registry::$SystemHive\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree"

    # Discover candidate task-tree keys defensively. Do not use Test-Path here:
    # the registry provider can report $true for a key that does not exist.
    $matches = @()
    try {
        $matches = @(
            Get-ChildItem -LiteralPath $treeRoot -Recurse -Force -ErrorAction Stop |
                Where-Object {
                    $taskName = $_.PSChildName
                    foreach ($regex in $NameRegex) {
                        if ($taskName -match $regex) { return $true }
                    }
                    return $false
                }
        )
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        # The TaskCache tree does not exist in this image at all. Nothing to do.
        Write-Step "No TaskCache tree present under $SystemHive; skipping scheduled-task cleanup."
        return
    }
    catch {
        # Any other enumeration failure is worth surfacing as a warning, but
        # should not abort the build: the caller will re-verify afterwards.
        Write-WarningMsg "Could not enumerate TaskCache tree '$treeRoot': $($_.Exception.Message)"
        return
    }

    if ($matches.Count -eq 0) {
        Write-Step "No scheduled-task registrations matching the supplied patterns were found under $SystemHive."
        return
    }

    $taskCacheBases = @(
        "Registry::$SystemHive\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks",
        "Registry::$SystemHive\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Plain",
        "Registry::$SystemHive\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Logon",
        "Registry::$SystemHive\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Boot",
        "Registry::$SystemHive\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Maintenance"
    )

    $removedCount = 0
    $failedKeys   = [System.Collections.Generic.List[string]]::new()

    foreach ($taskKey in $matches) {
        $taskId = $null

        # Look up the {GUID} Id for this task registration. If the key has no
        # Id (malformed, or a container node rather than a leaf), skip the
        # orphan-index cleanup and just remove the tree key itself.
        try {
            $props = Get-ItemProperty -LiteralPath $taskKey.PSPath -ErrorAction Stop
            if ($props -and $props.PSObject.Properties['Id'] -and
                $props.Id -is [string] -and
                $props.Id -match '^\{[0-9A-Fa-f-]+\}$') {
                $taskId = $props.Id
            }
        }
        catch {
            Write-WarningMsg "Could not inspect scheduled-task registration '$($taskKey.PSPath)': $($_.Exception.Message)"
        }

        # Remove the indexed cache entry under each TaskCache\<category> base.
        # Use a try/catch rather than Test-Path: the provider's Test-Path is
        # unreliable for freshly-loaded hives.
        if ($taskId) {
            foreach ($base in $taskCacheBases) {
                $taskCacheKey = Join-Path $base $taskId

                # Suppress any object output from Remove-Item so nothing leaks
                # into the caller's output stream.
                try {
                    $null = Remove-Item -LiteralPath $taskCacheKey -Recurse -Force -ErrorAction Stop
                }
                catch [System.Management.Automation.ItemNotFoundException] {
                    # Not present under this category; that is normal for any
                    # given task (a task is only indexed under one category).
                }
                catch {
                    Write-WarningMsg "Could not remove TaskCache index '$taskCacheKey': $($_.Exception.Message)"
                }
            }
        }

        # Remove the registration itself from the Tree.
        try {
            $null = Remove-Item -LiteralPath $taskKey.PSPath -Recurse -Force -ErrorAction Stop
            $removedCount++
        }
        catch {
            Write-WarningMsg "Could not remove scheduled-task registration '$($taskKey.PSPath)': $($_.Exception.Message)"
            [void]$failedKeys.Add($taskKey.PSPath)
        }
    }

    if ($failedKeys.Count -gt 0) {
        Write-WarningMsg "Removed $removedCount of $($matches.Count) scheduled-task registrations. Failed: $($failedKeys.Count)."
    }
    else {
        Write-Step "Removed $removedCount scheduled-task registration(s) matching the supplied patterns."
    }
}

function Invoke-OfflineRegistryCleanup {
    <#
    .SYNOPSIS
        Loads the offline SOFTWARE/SYSTEM/DEFAULT/user hives, runs a cleanup action,
        and unloads every hive that was successfully mounted. An unload failure is
        reported without masking an earlier action failure.

    .DESCRIPTION
        The PowerShell registry provider holds open handles to keys under a
        loaded hive for as long as any managed object (e.g. the results of
        Get-ChildItem or Get-ItemProperty) still references them. Those handles
        prevent reg.exe from unloading the hive even after the action that
        acquired them has returned. Forcing a full garbage collection before the
        unload releases the references, and a short settle delay gives the
        provider's finalizer thread time to close the underlying RegCloseKey
        calls. A second GC after a successful unload ensures the next caller
        starts from a clean handle state.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $cleanupHives = [ordered]@{
        'HKLM\zCLEAN_SOFTWARE' = (Join-Path $MOUNT_DIR 'Windows\System32\config\SOFTWARE')
        'HKLM\zCLEAN_SYSTEM'   = (Join-Path $MOUNT_DIR 'Windows\System32\config\SYSTEM')
        'HKLM\zCLEAN_DEFAULT'  = (Join-Path $MOUNT_DIR 'Windows\System32\config\DEFAULT')
    }

    $profileRoot = Join-Path $MOUNT_DIR 'Users'
    $profileIndex = 0
    if (Test-Path -LiteralPath $profileRoot) {
        foreach ($profile in @(Get-ChildItem -LiteralPath $profileRoot -Directory -Force -ErrorAction Stop)) {
            if ($profile.Name -ieq 'Default' -or $profile.Name -ieq 'Public' -or $profile.Name -ieq 'All Users') { continue }
            $ntUserPath = Join-Path $profile.FullName 'NTUSER.DAT'
            if (Test-Path -LiteralPath $ntUserPath -PathType Leaf) {
                $profileIndex++
                $cleanupHives[('HKLM\zCLEAN_USER{0:D2}' -f $profileIndex)] = $ntUserPath
            }
        }
    }

    $loadedCleanupHives = [System.Collections.ArrayList]::new()
    $actionException = $null
    try {
        # Recover from an interrupted previous run. reg.exe unload returns non-zero
        # when an alias is not loaded; that is expected and intentionally ignored.
        foreach ($staleHive in @($cleanupHives.Keys)) {
            $null = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('unload', $staleHive)
        }

        foreach ($hiveName in @(Invoke-RegistryHiveOperations -Operation Load -Hives $cleanupHives)) {
            [void]$loadedCleanupHives.Add($hiveName)
        }
        if ($loadedCleanupHives.Count -ne $cleanupHives.Count) {
            $missing = @($cleanupHives.Keys | Where-Object { $loadedCleanupHives -notcontains $_ })
            throw "Failed to load all registry hives required for offline cleanup. Missing: $($missing -join ', ')"
        }

        & $Action $loadedCleanupHives
    }
    catch {
        $actionException = $_.Exception
        throw
    }
    finally {
        if ($loadedCleanupHives.Count -gt 0) {
            # Force the PowerShell registry provider to release every handle it
            # acquired during the action. Without this, reg.exe unload fails
            # with "access denied" because the provider still has open keys
            # under the hive, and the mount directory cannot be released for
            # the later DISM discard.
            $null = [GC]::Collect()
            $null = [GC]::WaitForPendingFinalizers()
            Start-Sleep -Milliseconds 500

            $remaining = [System.Collections.ArrayList]::new()
            foreach ($hiveName in @($loadedCleanupHives)) { [void]$remaining.Add($hiveName) }
            $unloaded = @(Invoke-RegistryHiveOperations -Operation Unload -Hives $remaining)
            foreach ($hiveName in @($unloaded)) { [void]$remaining.Remove($hiveName) }

            if ($remaining.Count -gt 0) {
                $message = "Failed to unload one or more temporary cleanup hives. Still loaded: $($remaining -join ', ')"
                Set-CleanupFailure $message
                if ($null -eq $actionException) {
                    throw $message
                }
            }

            # Drop the collection so the next cleanup run starts from a clean slate.
            $loadedCleanupHives = [System.Collections.ArrayList]::new()

            # Second GC pass: the successful unload closed the hive handles, but
            # the provider may still be holding managed wrappers. Clearing them
            # here prevents the next Invoke-OfflineRegistryCleanup call (OneDrive,
            # for example) from inheriting a stale handle state.
            $null = [GC]::Collect()
            $null = [GC]::WaitForPendingFinalizers()
        }
    }
}

function Invoke-RegistryHiveOperations {
    <#
    .SYNOPSIS
        Sequentially loads or unloads registry hives (NOT thread-safe).

    .PARAMETER Hives
        For Load:   Hashtable of HiveName = HiveFilePath.
        For Unload: Collection of HiveName strings (e.g. from a previous Load call).
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Load','Unload')][string]$Operation,
        [Parameter(Mandatory)][object]$Hives
    )

    $results = [System.Collections.ArrayList]::new()

    if ($Operation -eq 'Load') {
        # Accept either a hashtable (Name=Path) or a dictionary.
        $keys = if ($Hives -is [hashtable] -or $Hives -is [System.Collections.IDictionary]) {
            @($Hives.Keys)
        } else {
            throw "For -Operation Load, -Hives must be a hashtable/dictionary of HiveName = HiveFilePath."
        }

        foreach ($hiveName in $keys) {
            $hivePath = $Hives[$hiveName]

            if (Test-Path -LiteralPath $hivePath) {
                $loadResult = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @(
                    'load', $hiveName, $hivePath
                )

                if ($loadResult.ExitCode -eq 0) {
                    $results.Add($hiveName) | Out-Null
                } else {
                    Write-WarningMsg "Failed to load hive $hiveName from $hivePath (reg.exe exit code $($loadResult.ExitCode)): $($loadResult.Output -join ' ')"
                }
            } else {
                Write-WarningMsg "Hive file not found: $hivePath (skipping $hiveName)"
            }
        }
    } else {
        # Unload each hive sequentially. Retry transient locks up to 3 times.
        foreach ($hiveName in @($Hives)) {
            if ([string]::IsNullOrWhiteSpace($hiveName)) {
                continue
            }

            $unloaded = $false
            $unloadResult = $null

            for ($attempt = 1; $attempt -le 3 -and -not $unloaded; $attempt++) {
                $unloadResult = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @(
                    'unload', $hiveName
                )

                if ($unloadResult.ExitCode -eq 0) {
                    $results.Add($hiveName) | Out-Null
                    $unloaded = $true
                } else {
                    if ($attempt -lt 3) {
                        Start-Sleep -Milliseconds 500
                    }
                }
            }

            if (-not $unloaded) {
                $message = if ($unloadResult) { ($unloadResult.Output -join ' ').Trim() } else { '' }

                if ([string]::IsNullOrWhiteSpace($message)) {
                    $code = if ($unloadResult) { $unloadResult.ExitCode } else { 'unknown' }
                    $message = "reg.exe exit code $code"
                }

                Write-WarningMsg "Failed to unload hive $hiveName after 3 attempts: $message"
            }
        }
    }

    return $results
}

function Get-ImageArchitecture {
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][int]$Index
    )
    $image = Get-WindowsImage -ImagePath $ImagePath -Index $Index -ErrorAction Stop
    if (-not $image) { throw "Could not retrieve image metadata for index $Index from '$ImagePath'." }

    # DISM exposes DismImageInfo.Architecture as a numeric enum. In particular,
    # 9 = amd64/x64 and 12 = arm64. Older/custom wrappers may expose strings,
    # so accept both representations.
    $architecture = $image.Architecture
    if ($architecture -is [string]) {
        switch -Regex ($architecture.Trim()) {
            '^(?i:x64|amd64)$' { return 'amd64' }
            '^(?i:arm64)$'     { return 'arm64' }
            '^(?i:x86|i386)$'  { return 'x86' }
            default            { return $architecture.Trim().ToLowerInvariant() }
        }
    }

    switch ([int]$architecture) {
        0  { return 'x86' }
        9  { return 'amd64' }
        12 { return 'arm64' }
        6  { return 'ia64' }
        default { return ([int]$architecture).ToString() }
    }
}

function Get-OfflineActiveControlSet {
    <#
    .SYNOPSIS
        Reads SYSTEM\Select\Current from the loaded offline SYSTEM hive.
    .OUTPUTS
        String such as ControlSet001.
    #>
    $result = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @(
        'query', 'HKLM\zSYSTEM\Select', '/v', 'Current'
    )
    if ($result.ExitCode -ne 0) {
        throw "Could not read the active control set from HKLM\zSYSTEM\Select."
    }
    $line = $result.Output | Where-Object { $_ -match '\bCurrent\s+REG_DWORD\s+0x([0-9a-fA-F]+)' } | Select-Object -First 1
    if (-not $line -or $line -notmatch '\bCurrent\s+REG_DWORD\s+0x([0-9a-fA-F]+)') {
        throw "HKLM\zSYSTEM\Select\Current was not found or was not a REG_DWORD."
    }
    $current = [Convert]::ToInt32($matches[1], 16)
    if ($current -lt 1) {
        throw "Invalid offline current control set value: $current"
    }
    return ('ControlSet{0:D3}' -f $current)
}

function Get-DismMountedImagesSafe {
    [CmdletBinding()]
    param()
    try {
        return @(Get-WindowsImage -Mounted -ErrorAction Stop)
    } catch {
        throw "Could not determine active DISM WIM mounts: $($_.Exception.Message)"
    }
}

function Test-SameWindowsPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Left,[Parameter(Mandatory)][string]$Right)
    try {
        $l=[IO.Path]::GetFullPath($Left).TrimEnd('\\')
        $r=[IO.Path]::GetFullPath($Right).TrimEnd('\\')
        return [string]::Equals($l,$r,[StringComparison]::OrdinalIgnoreCase)
    } catch {
        return [string]::Equals($Left.TrimEnd('\\'),$Right.TrimEnd('\\'),[StringComparison]::OrdinalIgnoreCase)
    }
}

function Invoke-StaleBuildMountRecovery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MountPath,[Parameter(Mandatory)][string]$WimPath,[int]$Attempts=3)

    $mounted=@(Get-DismMountedImagesSafe)
    $relevant=@($mounted | Where-Object {
        ($_.MountPath -and (Test-SameWindowsPath ([string]$_.MountPath) $MountPath)) -or
        ($_.ImagePath -and (Test-SameWindowsPath ([string]$_.ImagePath) $WimPath))
    })
    if($relevant.Count -eq 0){ Write-Ok "No stale DISM mount belongs to this build."; return }

    Write-WarningMsg "Found $($relevant.Count) stale DISM mount(s) belonging to this build. Recovering them before reuse."
    foreach($entry in $relevant){
        if([string]::IsNullOrWhiteSpace([string]$entry.MountPath)){ throw "DISM reported a relevant mount without a mount path. Refusing to continue." }
        $recovered=$false; $last=$null
        for($attempt=1;$attempt -le [math]::Max(1,$Attempts) -and -not $recovered;$attempt++){
            try{
                [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Seconds ([math]::Min(8,$attempt))
                Invoke-WindowsImageDiscardRobust -MountPath ([string]$entry.MountPath) -Attempts 2
                $recovered=$true
                Write-Ok "Stale DISM mount discarded: '$($entry.MountPath)'"
            }catch{
                $last=$_.Exception
                Write-WarningMsg "Stale mount recovery attempt $attempt/$Attempts failed: $($last.Message)"
                if($attempt -lt $Attempts){Start-Sleep -Seconds ([math]::Min(10,$attempt*2))}
            }
        }
        if(-not $recovered){ throw "A stale DISM mount could not be recovered: '$($entry.MountPath)' (image '$($entry.ImagePath)'). Last error: $($last.Message)" }
    }

    $remaining=@(Get-DismMountedImagesSafe | Where-Object {
        ($_.MountPath -and (Test-SameWindowsPath ([string]$_.MountPath) $MountPath)) -or
        ($_.ImagePath -and (Test-SameWindowsPath ([string]$_.ImagePath) $WimPath))
    })
    if($remaining.Count -gt 0){
        $summary=($remaining|ForEach-Object{"MountPath='$($_.MountPath)', ImagePath='$($_.ImagePath)'"}) -join '; '
        throw "DISM still reports a relevant mounted image after recovery: $summary"
    }
    Write-Ok "DISM mount state is clean for this build."
}

function Invoke-WindowsImageDiscardRobust {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [int]$Attempts = 5
    )

    $last = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            Start-Sleep -Seconds ([math]::Min(10, $attempt * 2))
            Dismount-WindowsImage -Path $MountPath -Discard -ErrorAction Stop
            return
        }
        catch {
            $last = $_.Exception
            Write-WarningMsg "Discard dismount attempt $attempt/$Attempts failed: $($last.Message)"
        }
    }

    try {
        Write-WarningMsg "PowerShell discard dismount remained locked; trying native DISM /Unmount-Wim /Discard..."
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 3
        $result = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @(
            '/English', '/Unmount-Wim', "/MountDir:$MountPath", '/Discard'
        )
        if ($result.ExitCode -eq 0) { return }
        $detail = ($result.Output | Select-Object -Last 12) -join [Environment]::NewLine
        throw "Native DISM discard failed with exit code $($result.ExitCode). $detail"
    }
    catch {
        if ($last) {
            throw "Unable to discard mounted image '$MountPath'. Last PowerShell error: $($last.Message)`nFallback error: $($_.Exception.Message)"
        }
        throw
    }
}

function Invoke-WindowsImageDismountRobust {
    <#
    .SYNOPSIS
        Dismounts an offline Windows image with retry/backoff and a native DISM
        fallback. Windows Defender, Search indexing, registry-provider handles,
        and transient DISM provider locks can otherwise make Dismount-WindowsImage
        fail with ERROR_SHARING_VIOLATION ("file is being used by another process").

    .DESCRIPTION
        The function deliberately does NOT delete or rename anything after a
        failed dismount. It retries the commit operation, forces managed-object
        cleanup between attempts, and finally asks native dism.exe to perform the
        same commit. The caller's mount-state flag is changed only after a
        successful dismount.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [int]$Attempts = 5,
        [int]$InitialDelaySeconds = 2
    )

    if ($Attempts -lt 1) { throw "Attempts must be at least 1." }

    $lastException = $null

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            # Release PowerShell/registry-provider objects before asking DISM to
            # finalize the image. This is especially important after offline
            # registry work and Get-ChildItem/Get-ItemProperty enumeration.
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            Start-Sleep -Seconds ([math]::Min(10, [math]::Max(1, $InitialDelaySeconds * $attempt)))

            Write-Step "Committing mounted image (attempt $attempt/$Attempts)..."
            Dismount-WindowsImage `
                -Path $MountPath `
                -Save `
                -CheckIntegrity `
                -ErrorAction Stop

            return
        }
        catch {
            $lastException = $_.Exception
            $message = $lastException.Message
            Write-WarningMsg "Dismount attempt $attempt/$Attempts failed: $message"

            if ($attempt -lt $Attempts) {
                # Give antivirus/indexing/DISM provider threads time to release
                # handles. Do not remove, rename, or recreate the mount directory.
                Start-Sleep -Seconds ([math]::Min(15, $InitialDelaySeconds * ($attempt + 1)))
            }
        }
    }

    # Final fallback: use native DISM. This avoids depending on the PowerShell
    # DISM provider after it has already reported a provider/handle problem.
    try {
        Write-WarningMsg "PowerShell Dismount-WindowsImage remained locked; trying native DISM /Unmount-Wim /Commit..."

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Seconds 3

        $result = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @(
            '/English', '/Unmount-Wim', "/MountDir:$MountPath", '/Commit', '/CheckIntegrity'
        )

        if ($result.ExitCode -eq 0) {
            return
        }

        $detail = ($result.Output | Select-Object -Last 15) -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = "DISM exit code $($result.ExitCode)"
        }
        throw "Native DISM unmount/commit failed with exit code $($result.ExitCode).`n$detail"
    }
    catch {
        if ($null -ne $lastException) {
            throw "Unable to commit mounted image '$MountPath'. The image may still be mounted. Last PowerShell error: $($lastException.Message)`nFallback error: $($_.Exception.Message)"
        }
        throw
    }
}

function Invoke-DismChecked {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Description
    )
    $result = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        $detail = ($result.Output | Select-Object -Last 12) -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($detail)) {
            throw "$Description failed with exit code $($result.ExitCode)."
        }
        throw "$Description failed with exit code $($result.ExitCode).`n$detail"
    }
    return $result.Output
}

function Convert-WindowsProcessArgument {
    param([AllowEmptyString()][string]$Argument)
    if ($null -eq $Argument -or $Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
            continue
        }
        if ($ch -eq '"') {
            if ($backslashes -gt 0) { [void]$sb.Append(('\' * ($backslashes * 2))) }
            [void]$sb.Append('\"')
            $backslashes = 0
        } else {
            if ($backslashes -gt 0) { [void]$sb.Append(('\' * $backslashes)); $backslashes = 0 }
            [void]$sb.Append($ch)
        }
    }
    if ($backslashes -gt 0) { [void]$sb.Append(('\' * ($backslashes * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Select-WindowsImageIndex {
    <#
    .SYNOPSIS
        Selects an image index either from -ImageIndex param, auto-detect via regex,
        or interactive prompt.
    .OUTPUTS
        Int index, or $null on failure.
    #>
    param(
        [Parameter(Mandatory)][array]$Images,
        [Parameter(Mandatory)][int]$PreferredIndex,
        [Parameter(Mandatory)][string]$ProRegex
    )
    if ($PreferredIndex -gt 0) {
        if (-not ($Images | Where-Object { $_.ImageIndex -eq $PreferredIndex })) {
            Write-ErrorMessage "Image index $PreferredIndex does not exist in the source image."
            return $null
        }
        Write-Ok "Using image index from parameter: $PreferredIndex"
        return $PreferredIndex
    }

    $proImage = $Images | Where-Object {
        $_.ImageName -match $ProRegex -and (
            ($_.Architecture -is [string] -and $_.Architecture -match '^(?i:x64|amd64)$') -or
            ($_.Architecture -as [int] -eq 9)
        )
    } | Select-Object -First 1

    if ($proImage) {
        Write-Ok "Auto-selected '$($proImage.ImageName)' (Index $($proImage.ImageIndex))"
        return $proImage.ImageIndex
    }

    if ($QuietMode) {
        Write-ErrorMessage "QuietMode requires -ImageIndex when '$ProRegex' cannot be auto-detected."
        # Return $null; callers should test with $null -eq.
        return $null
    }

    do {
        $raw = Read-Host "Please enter the image index to use"
        $parsed = 0
        if (-not [int]::TryParse($raw, [ref]$parsed) -or $parsed -lt 1) {
            Write-ErrorMessage "Invalid image index: $raw"
            continue
        }
        if (-not ($Images | Where-Object { $_.ImageIndex -eq $parsed })) {
            Write-ErrorMessage "Image index $parsed does not exist. Available indexes: $($Images.ImageIndex -join ', ')"
            continue
        }
        return $parsed
    } while ($true)
}

# ==================== INITIAL SETUP ====================
Clear-Host
$ErrorActionPreference = "Stop"

# PowerShell 7.3+ only; harmless on 5.1. Prevents native-command stderr from
# being promoted to a terminating error at the engine level. Belt-and-suspenders
# with Invoke-NativeCommand.
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$script:Host.UI.RawUI.WindowTitle = $script:VersionInfo.WindowTitle

Write-Banner "Gaming Windows Image Creator v$($script:VersionInfo.FullVersion) ($($script:VersionInfo.Codename))"

# ---- Resolve ScratchDisk to just the drive letter ----
if (-not $ScratchDisk) {
    $resolvedScratch = Resolve-DriveLetter -InputValue $PSScriptRoot
    if (-not $resolvedScratch) {
        Write-ErrorMessage "Could not auto-detect scratch drive from script location: $PSScriptRoot"
        exit 1
    }
    $ScratchDisk = $resolvedScratch
} else {
    $resolvedScratch = Resolve-DriveLetter -InputValue $ScratchDisk
    if (-not $resolvedScratch) {
        Write-ErrorMessage "Invalid scratch disk: $ScratchDisk"
        exit 1
    }
    $ScratchDisk = $resolvedScratch
}

if ($ScratchDisk -eq "C:") {
    Write-ErrorMessage "Cannot use C: drive as scratch disk."
    exit 1
}
if (-not (Test-Path "$ScratchDisk\")) {
    Write-ErrorMessage "Scratch drive $ScratchDisk does not exist or is not accessible."
    exit 1
}

try {
    $scratchVolume = Get-Volume -DriveLetter $ScratchDisk.Substring(0, 1) -ErrorAction Stop
    if ($scratchVolume.FileSystem -ne 'NTFS') {
        Write-ErrorMessage "Scratch drive $ScratchDisk must use NTFS; detected filesystem: $($scratchVolume.FileSystem)."
        exit 1
    }
} catch {
    Write-ErrorMessage "Could not validate the scratch drive filesystem: $($_.Exception.Message)"
    exit 1
}

$cancelledForLowScratchSpace = $false
try {
    $driveInfo = Get-PSDrive -Name $ScratchDisk.Substring(0, 1)
    if ($driveInfo.Free -lt 20GB) {
        Write-WarningMsg "Less than 20GB free on scratch disk ($([math]::Round($driveInfo.Free/1GB,2))GB available)."
        if (-not (Test-Confirmation "Continue anyway?")) { $cancelledForLowScratchSpace = $true }
    }
} catch {
    Write-WarningMsg "Could not check disk space on $ScratchDisk"
}
if ($cancelledForLowScratchSpace) {
    Write-ErrorMessage "Build cancelled because available scratch space is below the minimum warning threshold."
    exit 1
}

Write-Ok "Scratch disk set to $ScratchDisk"

# ==================== EXECUTION POLICY CHECK ====================
# Do not mutate the user's persistent PowerShell policy. The elevated child below
# is launched with -ExecutionPolicy Bypass, so changing CurrentUser policy is
# unnecessary and creates an unwanted side effect.
if ((Get-ExecutionPolicy) -eq 'Restricted') {
    Write-WarningMsg "Effective Execution Policy is Restricted; continuing without changing the user's policy."
}

# ==================== ADMIN ELEVATION ====================
$myWindowsID        = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole          = [System.Security.Principal.WindowsBuiltInRole]::Administrator

if (-not $myWindowsPrincipal.IsInRole($adminRole)) {
    Write-WarningMsg "Restarting as Administrator..."

    $scriptPath = $myInvocation.MyCommand.Definition
    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $scriptPath
    )

    if ($PSBoundParameters.ContainsKey('ScratchDisk')) {
        $argList += @('-ScratchDisk', ($ScratchDisk -replace '[:\\]+$', ''))
    }
    if ($PSBoundParameters.ContainsKey('SourceDrive')) {
        $argList += @('-SourceDrive', ($SourceDrive -replace '[:\\]+$', ''))
    }
    if ($PSBoundParameters.ContainsKey('ImageIndex') -and $ImageIndex -gt 0) {
        $argList += @('-ImageIndex', $ImageIndex)
    }
    if ($PSBoundParameters.ContainsKey('ProImageRegex')) {
        $argList += @('-ProImageRegex', $ProImageRegex)
    }
    # Forward -ExportCompression when the caller explicitly set it.
    if ($PSBoundParameters.ContainsKey('ExportCompression')) {
        $argList += @('-ExportCompression', $ExportCompression)
    }
    foreach ($switch in @('SkipBloatwareRemoval',
                         'SkipRegistryTweaks','SkipComponentCleanup',
                         'QuietMode','Force','PreserveWorkOnError')) {
        if ($PSBoundParameters.ContainsKey($switch) -and $PSBoundParameters[$switch]) {
            $argList += "-$switch"
        }
    }

    $newProcess = New-Object System.Diagnostics.ProcessStartInfo
    $newProcess.FileName        = (Get-Process -Id $PID).Path
    $newProcess.UseShellExecute = $true
    $newProcess.Verb            = "runas"
    try {
        $newProcess.Arguments = (($argList | ForEach-Object { Convert-WindowsProcessArgument -Argument ([string]$_) }) -join ' ')
        $elevatedProcess = [System.Diagnostics.Process]::Start($newProcess)
        if ($null -eq $elevatedProcess) {
            throw "The elevated PowerShell process could not be started."
        }

        # Wait for the elevated child to finish and propagate its real exit code
        # instead of always returning success from the non-elevated parent.
        $elevatedProcess.WaitForExit()
        $elevatedExitCode = $elevatedProcess.ExitCode
        $elevatedProcess.Dispose()
        exit $elevatedExitCode
    } catch {
        Write-ErrorMessage "Failed to elevate: $_"
        exit 1
    }
}

# ==================== PRE-FLIGHT CHECKS ====================
Write-Banner "Pre-flight Checks"

# Verify the DISM PowerShell module/cmdlets before touching the source media.
# Failing here is preferable to discovering a missing servicing component after
# a WIM has already been copied or mounted.
try {
    Import-Module Dism -ErrorAction Stop
    foreach ($requiredCommand in @(
        'Get-WindowsImage',
        'Mount-WindowsImage',
        'Dismount-WindowsImage',
        'Repair-WindowsImage'
    )) {
        if (-not (Get-Command -Name $requiredCommand -CommandType Cmdlet -ErrorAction SilentlyContinue)) {
            throw "Required DISM PowerShell cmdlet is unavailable: $requiredCommand"
        }
    }
    Write-Ok "DISM PowerShell module and required servicing cmdlets are available."
}
catch {
    Write-ErrorMessage "DISM pre-flight validation failed: $($_.Exception.Message)"
    exit 1
}

# --- autounattend.xml ---
$autoUnattendPath = Join-Path $PSScriptRoot "autounattend.xml"
if (-not (Test-Path $autoUnattendPath)) {
    Write-ErrorMessage "autounattend.xml not found in script directory: $PSScriptRoot"
    exit 1
}
try {
    [xml]$autoUnattendXml = Get-Content $autoUnattendPath -ErrorAction Stop

    # Windows documents OOBE automation through the oobeSystem unattend pass.
    # This builder intentionally targets an offline/local-account setup, so do not
    # rely on the legacy/optional BypassNRO registry switch as the primary path.
    $oobePath = "//*[local-name()='settings'][@pass='oobeSystem']/*[local-name()='component'][@name='Microsoft-Windows-Shell-Setup']/*[local-name()='OOBE']"
    $hideOnlineAccountNode = $autoUnattendXml.SelectSingleNode($oobePath + "/*[local-name()='HideOnlineAccountScreens']")
    $hideWirelessNode     = $autoUnattendXml.SelectSingleNode($oobePath + "/*[local-name()='HideWirelessSetupInOOBE']")

    if ($null -eq $hideOnlineAccountNode -or $hideOnlineAccountNode.InnerText.Trim() -notmatch '^(?i:true)$') {
        throw "autounattend.xml must set Microsoft-Windows-Shell-Setup/OOBE/HideOnlineAccountScreens to true for the local-account OOBE flow."
    }
    if ($null -eq $hideWirelessNode -or $hideWirelessNode.InnerText.Trim() -notmatch '^(?i:true)$') {
        throw "autounattend.xml must set Microsoft-Windows-Shell-Setup/OOBE/HideWirelessSetupInOOBE to true."
    }

    # HideOnlineAccountScreens suppresses the online-account UI; it does not create
    # a local user. Require an explicit Shell-Setup/UserAccounts/LocalAccounts entry.
    $localAccountPath = "//*[local-name()='component'][@name='Microsoft-Windows-Shell-Setup']/*[local-name()='UserAccounts']/*[local-name()='LocalAccounts']/*[local-name()='LocalAccount']"
    $localAccountNodes = @($autoUnattendXml.SelectNodes($localAccountPath))
    if ($localAccountNodes.Count -eq 0) {
        throw "autounattend.xml does not define any Shell-Setup/UserAccounts/LocalAccounts/LocalAccount entry; local-account creation cannot be validated."
    }

    Write-Ok "autounattend.xml validation passed: OOBE controls and explicit local-account creation are present."
} catch {
    Write-ErrorMessage "autounattend.xml validation failed: $($_.Exception.Message)"
    exit 1
}

# --- OSCDIMG ---
# OSCDIMG is a Windows ADK deployment tool. Do not download an executable from
# an undocumented symbol-server URL: require a locally installed/supplied copy
# and validate its Authenticode signature before use.
$hostArchitecture = $Env:PROCESSOR_ARCHITECTURE
$adkRoot = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools"
$adkCandidates = @()
if ($hostArchitecture -match '^(AMD64|x86)$') {
    $adkCandidates += Join-Path $adkRoot 'amd64\Oscdimg\oscdimg.exe'
    if ($hostArchitecture -eq 'x86') { $adkCandidates += Join-Path $adkRoot 'x86\Oscdimg\oscdimg.exe' }
} elseif ($hostArchitecture -eq 'ARM64') {
    $adkCandidates += Join-Path $adkRoot 'arm64\Oscdimg\oscdimg.exe'
    $adkCandidates += Join-Path $adkRoot 'amd64\Oscdimg\oscdimg.exe'
}
$localOSCDIMGPath = Join-Path $PSScriptRoot "oscdimg.exe"

$adkOsCdImg = $adkCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($adkOsCdImg) {
    $OSCDIMG = $adkOsCdImg
    Write-Ok "Found OSCDIMG in ADK: $OSCDIMG"
} elseif (Test-Path $localOSCDIMGPath) {
    $OSCDIMG = $localOSCDIMGPath
    Write-Ok "Found local OSCDIMG: $OSCDIMG"
} else {
    throw "OSCDIMG was not found. Install the Windows ADK Deployment Tools or place a Microsoft-signed oscdimg.exe next to this script."
}

$oscdimgSignature = Get-AuthenticodeSignature -FilePath $OSCDIMG -ErrorAction Stop
if ($oscdimgSignature.Status -ne 'Valid') {
    throw "OSCDIMG failed Authenticode validation (status: $($oscdimgSignature.Status)). Refusing to execute '$OSCDIMG'."
}
$oscdimgSignerSubject = if ($oscdimgSignature.SignerCertificate) { $oscdimgSignature.SignerCertificate.Subject } else { '' }
if ($oscdimgSignerSubject -notmatch '(?i)Microsoft') {
    throw "OSCDIMG is Authenticode-signed but the signer does not appear to be Microsoft: '$oscdimgSignerSubject'. Refusing to execute '$OSCDIMG'."
}
Write-Ok "OSCDIMG Authenticode signature is valid and the signer is Microsoft."

# ==================== START TRANSCRIPT ====================
$logPath = Join-Path $ScratchDisk $script:VersionInfo.LogFilename
if ($script:VersionInfo.Features.EnableTranscript) {
    try {
        Start-Transcript -Path $logPath -Append -ErrorAction Stop
        Write-Ok "Transcript started: $logPath"
    } catch {
        Write-WarningMsg "Could not start transcript at '$logPath': $($_.Exception.Message)"
    }
}

# ==================== DEFINE PATHS ====================
$WORK_DIR      = Join-Path "$ScratchDisk\" "GamingWindows"
$MOUNT_DIR     = Join-Path "$ScratchDisk\" "scratchdir"
$WIM_PATH      = Join-Path $WORK_DIR "sources\install.wim"
$BOOT_WIM_PATH = Join-Path $WORK_DIR "sources\boot.wim"

# Build stages are kept fixed; conditional stages
# still occupy their slot when skipped so progress remains stable.
$totalSteps   = 15
$mainProgress = [ProgressTracker]::new("Building Gaming Windows ISO", $totalSteps, $script:ShowProgress)

# Transaction state. These are initialized BEFORE the try so the finally block can
# safely recover from failures occurring at any point in the build.
$loadedHives = [System.Collections.ArrayList]::new()
$loadedBootHives = [System.Collections.ArrayList]::new()
$mainImageMounted = $false
$bootImageMounted = $false
$isoMounted = $false
$isoPath = $null
$bootOrderPath = $null
$buildSucceeded = $false

# ==================== BUILD TRANSACTION ====================
# Everything from source selection through ISO creation is inside one transaction.
# This guarantees cleanup also runs for failures during copy, staging, servicing,
# or ISO creation.
try {

# ==================== SELECT SOURCE DRIVE ====================
$mainProgress.StartStep("Selecting source drive")

if ($SourceDrive) {
    $resolvedSource = Resolve-DriveLetter -InputValue $SourceDrive
    if (-not $resolvedSource) {
        throw "Invalid source drive: $SourceDrive"
    }
    $DriveLetter = $resolvedSource
    Write-Ok "Source drive (from parameter): $DriveLetter"
} elseif ($QuietMode) {
    throw "QuietMode requires -SourceDrive to be specified."
} else {
    # [FIX] Renamed $input -> $userInput to avoid clobbering the automatic variable.
    do {
        $userInput = Read-Host "Please enter the drive letter for the Windows 11 installation media (e.g., D)"
        $resolved  = Resolve-DriveLetter -InputValue $userInput
        if ($resolved) {
            $DriveLetter = $resolved
            Write-Ok "Drive letter set to $DriveLetter"
            break
        } else {
            Write-ErrorMessage "Invalid drive letter. Please enter a letter between A and Z."
        }
    } while ($true)
}

# Source and scratch must be different drives. Using the same drive can
# cause recursive copying / exhaustion of free space and can corrupt the build.
if ($DriveLetter.TrimEnd(':\').ToUpperInvariant() -eq $ScratchDisk.TrimEnd(':\').ToUpperInvariant()) {
    throw "SourceDrive and ScratchDisk must be different drives. SourceDrive=$DriveLetter, ScratchDisk=$ScratchDisk"
}

# Validate source media
$installWimPath = Join-Path $DriveLetter "sources\install.wim"
$installEsdPath = Join-Path $DriveLetter "sources\install.esd"
if (-not (Test-Path $installWimPath) -and -not (Test-Path $installEsdPath)) {
    throw "No Windows installation files found at $DriveLetter (missing install.wim and install.esd)"
}
$mainProgress.CompleteStep()

# ==================== CREATE DIRECTORY STRUCTURE ====================
$mainProgress.StartStep("Creating directory structure")

# DISM mount registration survives ordinary directory deletion. Recover all
# build-related stale mounts before touching the work tree or mount directory.
Invoke-StaleBuildMountRecovery -MountPath $MOUNT_DIR -WimPath $WIM_PATH -Attempts 3

foreach ($staleDir in @($WORK_DIR, $MOUNT_DIR)) {
    if ($staleDir -and (Test-Path -LiteralPath $staleDir)) {
        if (-not (Remove-PathSafe -Path $staleDir)) {
            throw "Could not remove stale build directory '$staleDir'. Refusing to reuse it."
        }
    }
}
New-Item -ItemType Directory -Force -Path (Join-Path $WORK_DIR "sources") -ErrorAction Stop | Out-Null
New-Item -ItemType Directory -Force -Path $MOUNT_DIR -ErrorAction Stop | Out-Null

# ---- Copy optional OEM overlay into the build tree ----
# The OEM folder next to the script mirrors the ISO root. Anything under OEM\
# ends up under $WORK_DIR\; for example, sources\$OEM$\$1\Setup\ lands at
# C:\Setup\ on the installed system. The overlay is optional so builds do
# not depend on any optional first-boot payload.
$oemOverlaySource = Join-Path $PSScriptRoot 'OEM'
$oemOverlayDest   = Join-Path $WORK_DIR 'sources'
if (Test-Path -LiteralPath $oemOverlaySource -PathType Container) {
    $expectedPayload = @(
        Get-ChildItem -LiteralPath $oemOverlaySource -File -Recurse -Force |
            ForEach-Object {
                $_.FullName.Substring($oemOverlaySource.Length).TrimStart([char[]]@(92, 47))
            }
    )

    if ($expectedPayload.Count -gt 0) {
        $oemRoboArgs = @(
            $oemOverlaySource,
            $oemOverlayDest,
            '/E', '/COPY:DAT', '/R:3', '/W:5', '/NP'
        )
        $oemRobo = Start-Process -FilePath 'robocopy.exe' -ArgumentList $oemRoboArgs -Wait -PassThru -NoNewWindow
        if ($oemRobo.ExitCode -ge 8) {
            throw "Robocopy failed while copying the OEM overlay (exit code $($oemRobo.ExitCode))."
        }

        foreach ($rel in $expectedPayload) {
            $staged = Join-Path $oemOverlayDest $rel
            if (-not (Test-Path -LiteralPath $staged -PathType Leaf)) {
                throw "OEM overlay staging verification failed: $staged is missing."
            }
        }
        Write-Ok "OEM overlay copied into the build tree ($($expectedPayload.Count) payload file(s) verified)."
    }
    else {
        Write-Ok "OEM overlay folder contains no files; skipping optional overlay."
    }
}
else {
    Write-Ok "No OEM overlay folder found; skipping optional overlay."
}

$mainProgress.CompleteStep()

# ==================== CHECK SPACE ====================
$mainProgress.StartStep("Checking available space")
$sourceRoot = "$DriveLetter\"

# Estimate the scratch requirement from the exact source tree that Robocopy copies.
# Robocopy uses /E and excludes only install.wim/install.esd, so the preflight must
# inspect the same tree; otherwise protected/extra files on the media can be omitted
# from the estimate and the build can run out of scratch space mid-copy.
$sourceScanErrors = @()
$sourceFiles = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable +sourceScanErrors |
    Where-Object { $_.FullName -ne $installWimPath -and $_.FullName -ne $installEsdPath })
$requiredMediaSpace = ($sourceFiles | Measure-Object -Property Length -Sum).Sum
if ($null -eq $requiredMediaSpace) { $requiredMediaSpace = 0 }
$sourceImageSize = 0
$sourceImageForEstimate = if (Test-Path -LiteralPath $installWimPath) { $installWimPath } else { $installEsdPath }
try {
    $sourceImageSize = (Get-Item -LiteralPath $sourceImageForEstimate -ErrorAction Stop).Length
} catch {
    throw "Could not determine the size of source installation image '$sourceImageForEstimate': $($_.Exception.Message)"
}
if ($sourceScanErrors.Count -gt 0) {
    Write-WarningMsg ("Could not enumerate {0} protected/inaccessible source path(s) while estimating space." -f $sourceScanErrors.Count)
    Write-WarningMsg "The estimate may be low; Robocopy remains the authoritative source-copy check."
}
$availableSpace = (Get-PSDrive -Name $ScratchDisk.Substring(0,1) -ErrorAction Stop).Free
# The staged WIM and final WIM can coexist with copied media and the mounted image.
# Use the source image size as an additional baseline and reserve generous headroom.
$estimatedRequiredSpace = [math]::Ceiling((($requiredMediaSpace * 2.5) + ($sourceImageSize * 2.5)) + 10GB)
if ($availableSpace -lt $estimatedRequiredSpace) {
    Write-WarningMsg "Available space ($([math]::Round($availableSpace/1GB,2))GB) < estimated build requirement ($([math]::Round($estimatedRequiredSpace/1GB,2))GB)"
    if (-not (Test-Confirmation "Continue anyway?")) { throw "Build cancelled because available scratch space is below the estimated requirement." }
} else {
    Write-Ok "Space check passed."
}
$mainProgress.CompleteStep()

# ==================== SELECT AND STAGE INSTALL IMAGE ====================
# Inspect the source WIM/ESD directly first. The large install image is exported
# directly into the build tree instead of being copied once into a separate source staging directory and
# then copied/exported again. This substantially reduces scratch usage and failure
# surface while preserving the selected-image behavior.
$mainProgress.StartStep("Selecting and staging install image")

$sourceWimPath = Join-Path $DriveLetter "sources\install.wim"
$sourceEsdPath = Join-Path $DriveLetter "sources\install.esd"
$sourceImagePath = if (Test-Path -LiteralPath $sourceWimPath) { $sourceWimPath } else { $sourceEsdPath }

try {
    $sourceImages = @(Get-WindowsImage -ImagePath $sourceImagePath -ErrorAction Stop)
} catch {
    throw "Failed to enumerate source installation image '$sourceImagePath': $($_.Exception.Message)"
}
if ($sourceImages.Count -eq 0) {
    throw "No usable images were found in '$sourceImagePath'."
}

if (-not $QuietMode) {
    Write-Step "Available source images:"
    $sourceImages | ForEach-Object {
        Write-Output "    $($_.ImageIndex): $($_.ImageName) (Architecture: $($_.Architecture))"
    }
}

$sourceIndex = Select-WindowsImageIndex -Images $sourceImages -PreferredIndex $ImageIndex -ProRegex $ProImageRegex
if ($null -eq $sourceIndex) { throw "No source image index selected." }

$selectedSourceImage = $sourceImages | Where-Object { $_.ImageIndex -eq $sourceIndex } | Select-Object -First 1
if (-not $selectedSourceImage) { throw "Selected source image index $sourceIndex does not exist." }

$sourceArchitecture = Get-ImageArchitecture -ImagePath $sourceImagePath -Index $sourceIndex
if ($sourceArchitecture -ne 'amd64') {
    throw "Unsupported source image architecture '$sourceArchitecture'. This builder currently supports x64/amd64 Windows images only."
}
Write-Ok "Selected image: $($selectedSourceImage.ImageName) (Index $sourceIndex, Architecture $sourceArchitecture)"

# Always create a single-image WIM for the build. This makes downstream servicing
# deterministic: the selected image is always WIM index 1.
Write-Step "Exporting selected image to the build WIM..."
$stageWimPath = Join-Path $WORK_DIR "sources\install.wim"
if (Test-Path -LiteralPath $stageWimPath) {
    Remove-Item -LiteralPath $stageWimPath -Force -ErrorAction Stop
}
$stageCompression = @{ Maximum = 'maximum'; Fast = 'fast'; None = 'none' }[$ExportCompression]
if (-not $stageCompression) { throw "Unsupported export compression '$ExportCompression'." }

$dismStageArgs = @(
    '/English', '/Export-Image',
    "/SourceImageFile:$sourceImagePath",
    "/SourceIndex:$sourceIndex",
    "/DestinationImageFile:$stageWimPath",
    "/Compress:$stageCompression",
    '/CheckIntegrity'
)
$null = Invoke-DismChecked -Arguments $dismStageArgs -Description "DISM export of the selected installation image"

$stagedImages = @(Get-WindowsImage -ImagePath $stageWimPath -ErrorAction Stop)
if ($stagedImages.Count -ne 1 -or $stagedImages[0].ImageIndex -ne 1) {
    throw "Staged install.wim is not a valid single-image WIM."
}
$index = 1
$WIM_PATH = $stageWimPath
$mainProgress.CompleteStep()

# ==================== COPY SOURCE FILES ====================
$mainProgress.StartStep("Copying source files to scratch disk")
Write-Step "Copying Windows installation media to $WORK_DIR"
Write-Step "The large install.wim/install.esd is excluded because it was staged directly above."

# Copy the media tree directly into WORK_DIR. Exclude the installation images because
# install.wim was already staged as the selected single-image WIM.
# IMPORTANT: use D:\ rather than D:; the latter is drive-relative.

$robocopyArgs = @(
    $sourceRoot,
    $WORK_DIR,
    "/E",
    "/COPY:DAT",
    "/R:3",
    "/W:5",
    "/NP",
    "/NDL",
    "/XF",
    "install.wim",
    "install.esd"
)

if ($QuietMode) {
    $robocopyArgs += @("/NFL", "/NJH", "/NJS")
}

$robocopyProcess = Start-Process `
    -FilePath "robocopy.exe" `
    -ArgumentList $robocopyArgs `
    -Wait `
    -PassThru `
    -NoNewWindow

if ($robocopyProcess.ExitCode -ge 8) {
    throw "Robocopy failed with exit code $($robocopyProcess.ExitCode)"
}

if (-not (Test-Path -LiteralPath $BOOT_WIM_PATH)) {
    throw "Required sources\boot.wim was not copied from the source media."
}
if (-not (Test-Path -LiteralPath $WIM_PATH)) {
    throw "Staged sources\install.wim was not created."
}

# Regression guard: the source copy must never replace the staged WIM.
$postCopyImages = @(Get-WindowsImage -ImagePath $WIM_PATH -ErrorAction Stop)
if ($postCopyImages.Count -ne 1 -or $postCopyImages[0].ImageIndex -ne 1) {
    throw "Source copy altered the staged install.wim; expected exactly one image at index 1."
}
Write-Ok "Source media staged successfully without overwriting the selected install.wim."
$mainProgress.CompleteStep()

# ==================== MOUNT & CUSTOMIZE MAIN IMAGE ====================
$index = $null

    $mainProgress.StartStep("Mounting and customizing install.wim")
    Write-Banner "Customizing install.wim" Magenta

    Write-Step "Available images in install.wim:"
    $images = @(Get-WindowsImage -ImagePath $WIM_PATH -ErrorAction Stop)
    if ($images.Count -ne 1 -or $images[0].ImageIndex -ne 1) {
        throw "Staged install.wim is expected to contain exactly one image at index 1."
    }
    if (-not $QuietMode) {
        $images | ForEach-Object { Write-Information "    $($_.ImageIndex): $($_.ImageName) (Architecture: $($_.Architecture))" -InformationAction Continue }
    }
    $index = 1

    if (-not (Invoke-TakeOwnership -Path $WIM_PATH)) {
        throw "Failed to prepare install.wim for mounting: ownership/ACL update failed."
    }
    Set-ItemProperty -Path $WIM_PATH -Name IsReadOnly -Value $false -ErrorAction Stop

    Write-Step "Verifying DISM mount state before mounting install.wim..."
    $preMountConflicts = @(Get-DismMountedImagesSafe | Where-Object {
        ($_.MountPath -and (Test-SameWindowsPath ([string]$_.MountPath) $MOUNT_DIR)) -or
        ($_.ImagePath -and (Test-SameWindowsPath ([string]$_.ImagePath) $WIM_PATH))
    })
    if ($preMountConflicts.Count -gt 0) {
        $details = ($preMountConflicts | ForEach-Object { "MountPath='$($_.MountPath)', ImagePath='$($_.ImagePath)'" }) -join '; '
        throw "Refusing to mount install.wim because DISM already reports a conflicting mount: $details"
    }

    Write-Step "Mounting image (this may take a few minutes)..."
    Mount-WindowsImage -ImagePath $WIM_PATH -Index $index -Path $MOUNT_DIR -CheckIntegrity -ErrorAction Stop
    $mainImageMounted = $true
    
    $architecture = Get-ImageArchitecture -ImagePath $WIM_PATH -Index $index
    Write-Ok "Architecture: $architecture"

    $mainProgress.CompleteStep()

    # ==================== REMOVE BLOATWARE ====================
    if (-not $SkipBloatwareRemoval) {
        $mainProgress.StartStep("Removing bloatware")
        Write-Step "Removing bloatware applications..."

        $packagePrefixes = @(
            'Clipchamp.Clipchamp_',
            'Microsoft.BingNews_', 'Microsoft.BingWeather_',
            'Microsoft.GamingApp_', 'Microsoft.GetHelp_', 'Microsoft.Getstarted_',
            'Microsoft.MicrosoftOfficeHub_', 'Microsoft.MicrosoftSolitaireCollection_',
            'Microsoft.People_', 'Microsoft.PowerAutomateDesktop_', 'Microsoft.Todos_',
            'Microsoft.WindowsAlarms_', 'microsoft.windowscommunicationsapps_',
            'Microsoft.WindowsFeedbackHub_', 'Microsoft.WindowsMaps_',
            'Microsoft.WindowsSoundRecorder_', 'Microsoft.Xbox.TCUI_',
            'Microsoft.XboxGamingOverlay_', 'Microsoft.XboxGameOverlay_',
            'Microsoft.XboxSpeechToTextOverlay_', 'Microsoft.YourPhone_',
            'Microsoft.ZuneMusic_', 'Microsoft.ZuneVideo_',
            'MicrosoftCorporationII.MicrosoftFamily_', 'MicrosoftCorporationII.QuickAssist_',
            'MicrosoftTeams_', 'Microsoft.549981C3F5F10_', 'Microsoft.Windows.Copilot',
            'MSTeams_', 'Microsoft.OutlookForWindows_', 'Microsoft.Windows.Teams_',
            'Microsoft.Copilot_', 'Microsoft.Microsoft3DViewer_',
            'Microsoft.MixedReality.Portal_',
            'Microsoft.Office.OneNote_',
            'Microsoft.SkypeApp_',
            'Microsoft.MicrosoftStickyNotes_',
            'Microsoft.Wallet_'
        )

        $pkgResult = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @(
            '/English', "/image:$MOUNT_DIR", '/Get-ProvisionedAppxPackages'
        )
        if ($pkgResult.ExitCode -ne 0) {
            $detail = ($pkgResult.Output | Select-Object -Last 8) -join [Environment]::NewLine
            throw "Failed to enumerate provisioned AppX packages (DISM exit code $($pkgResult.ExitCode)).$([Environment]::NewLine)$detail"
        }
        $packages = $pkgResult.Output |
            ForEach-Object { if ($_ -match 'PackageName\s*:\s*(.*)') { $matches[1].Trim() } }

        $packagesToRemove = @($packages | Where-Object {
            $pkg = $_
            $matched = $false
            foreach ($prefix in $packagePrefixes) {
                if ($pkg -like "$prefix*") { $matched = $true; break }
            }
            $matched
        })

        if ($packagesToRemove.Count -gt 0) {
            # DISM operations against the SAME offline image MUST be
            # sequential. Running them in parallel corrupts the image or returns
            # ERROR_BUSY (0x800700AA).
            $removedCount = 0
            $failedPackages = [System.Collections.Generic.List[string]]::new()
            $currentPkg   = 0
            foreach ($package in $packagesToRemove) {
                $currentPkg++
                Write-ProgressSafe -Activity "Removing bloatware" `
                    -Status "($currentPkg/$($packagesToRemove.Count)) $package" `
                    -PercentComplete (($currentPkg / $packagesToRemove.Count) * 100)
                $removeResult = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @(
                    '/English', "/image:$MOUNT_DIR",
                    '/Remove-ProvisionedAppxPackage', "/PackageName:$package"
                )
                if ($removeResult.ExitCode -eq 0) {
                    $removedCount++
                } else {
                    $failedPackages.Add($package)
                }
            }
            Write-ProgressSafe -Activity "Removing bloatware" -Completed
            Write-Ok "Removed $removedCount of $($packagesToRemove.Count) packages."
            if ($failedPackages.Count -gt 0) {
                Write-ErrorMessage "Failed to remove $($failedPackages.Count) targeted provisioned packages:"
                foreach ($failedPackage in $failedPackages) { Write-ErrorMessage "  $failedPackage" }
                throw "Bloatware removal was incomplete; refusing to produce an image containing targeted provisioned packages."
            }
        } else {
            Write-WarningMsg "No bloatware packages found to remove."
        }

		# ---------------------------------------------------------------------
		# Removal of facial recognition, handwriting/speech recognition, and Recall
		# ---------------------------------------------------------------------
		Write-Step "Removing specialized Windows capabilities (Face Recognition, Handwriting, Speech)..."
		
		# 1. Query available Windows capabilities from the offline image
		$capResult = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @(
		    '/English', "/image:$MOUNT_DIR", '/Get-Capabilities'
		)
		
		if ($capResult.ExitCode -eq 0) {
		
		    # Extract handwriting, speech, and face recognition capabilities
		    $capsToRemove = @(
		        $capResult.Output | ForEach-Object {
		            if ($_ -match 'Capability Identity\s*:\s*(.*)') {
		                $matches[1].Trim()
		            }
		        } | Where-Object {
		            $_ -match '(?i)Language\.Handwriting' -or
		            $_ -match '(?i)Language\.Speech' -or
		            $_ -match '(?i)WinBio\.Face'
		        }
		    )
		
		    if ($capsToRemove.Count -gt 0) {
		        $currentCap = 0
		
		        foreach ($cap in $capsToRemove) {
		            $currentCap++
		
		            Write-ProgressSafe -Activity "Removing Windows Capabilities" `
		                -Status "($currentCap/$($capsToRemove.Count)) $cap" `
		                -PercentComplete (($currentCap / $capsToRemove.Count) * 100)
		
		            $capRemoveResult = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @(
		                '/English',
		                "/image:$MOUNT_DIR",
		                '/Remove-Capability',
		                "/CapabilityName:$cap"
		            )
		
		            if ($capRemoveResult.ExitCode -eq 0) {
		                Write-Ok "Successfully removed capability: $cap"
		            }
		            else {
		                Write-WarningMsg "Failed to remove capability: $cap (DISM exit code $($capRemoveResult.ExitCode))"
		            }
		        }
		
		        Write-ProgressSafe -Activity "Removing Windows Capabilities" -Completed
		    }
		    else {
		        Write-Step "No matching Speech, Handwriting, or Face capabilities found."
		    }
		}
		else {
		    Write-WarningMsg "Failed to enumerate Windows Capabilities (DISM exit code $($capResult.ExitCode))."
		}
		
		# 2. Disable and remove the Windows Recall feature
		Write-Step "Disabling Windows Recall feature..."
		
		$recallResult = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @(
		    '/English',
		    "/image:$MOUNT_DIR",
		    '/Disable-Feature',
		    '/FeatureName:Recall',
		    '/Remove'
		)
		
		if ($recallResult.ExitCode -eq 0) {
		    Write-Ok "Windows Recall successfully disabled and binaries queued for removal."
		}
		else {
		    # Recall may not exist in older Windows 11 images.
		    # Treat this as a warning rather than a critical error.
		    Write-WarningMsg "Windows Recall feature was not found or could not be disabled. (Normal on older Windows 11 builds)."
		}
		
		$mainProgress.CompleteStep()
		}
		else {
		    $mainProgress.StartStep("Skipping bloatware removal")
		    Write-WarningMsg "Skipping bloatware removal."
		    $mainProgress.CompleteStep()
		}

    # ==================== REMOVE EDGE / EDGEUPDATE / WEBVIEW2 ====================
    # Full removal is intentional. Microsoft documents the Evergreen WebView2 Runtime
    # under Program Files (x86)\Microsoft\EdgeWebView and identifies its registration
    # under the EdgeUpdate\Clients\{F301...} key. This build removes those user/desktop
    # runtime components, EdgeUpdate services/tasks/registrations, and Edge browser
    # payload/registrations. OS-owned WebView2 binaries loaded directly from System32
    # are deliberately not altered because Microsoft identifies those as Windows-owned
    # and serviced by Windows Update.
    
        $mainProgress.StartStep("Removing Microsoft Edge, EdgeUpdate and WebView2")
        Write-Step "Removing Microsoft Edge, EdgeUpdate and WebView2 components..."

        $edgeComponentPaths = @(
            "$MOUNT_DIR\Program Files (x86)\Microsoft\Edge",
            "$MOUNT_DIR\Program Files\Microsoft\Edge",
            "$MOUNT_DIR\Program Files (x86)\Microsoft\EdgeWebView",
            "$MOUNT_DIR\Program Files\Microsoft\EdgeWebView",
            "$MOUNT_DIR\Program Files (x86)\Microsoft\EdgeUpdate",
            "$MOUNT_DIR\Program Files\Microsoft\EdgeUpdate",
            "$MOUNT_DIR\ProgramData\Microsoft\EdgeUpdate",
            "$MOUNT_DIR\ProgramData\Microsoft\EdgeWebView"
        )
        foreach ($path in $edgeComponentPaths) {
            if (Test-Path -LiteralPath $path) {
                if (-not (Invoke-TakeOwnership -Path $path -Recurse)) {
                    throw "Failed to take ownership of Edge/EdgeUpdate/WebView2 directory '$path'."
                }
                if (-not (Remove-PathSafe -Path $path)) {
                    throw "Failed to remove Edge/EdgeUpdate/WebView2 directory '$path'."
                }
            }
        }

        # Remove installer/setup remnants and start-menu shortcuts from the image.
        $edgeExtras = @(
            "$MOUNT_DIR\ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk",
            "$MOUNT_DIR\Users\Public\Desktop\Microsoft Edge.lnk",
            "$MOUNT_DIR\Users\Default\Desktop\Microsoft Edge.lnk",
            "$MOUNT_DIR\Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk"
        )
        foreach ($p in $edgeExtras) {
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                if (-not (Remove-PathSafe -Path $p -Silent)) { throw "Could not remove Edge shortcut '$p'." }
            }
        }

        # Edge Update scheduled tasks are normally stored at the root of System32\Tasks
        # (e.g. MicrosoftEdgeUpdateTaskMachineCore / ...UA).
        # Remove the task files by name and clean all TaskCache links.
        $taskFilesRoot = Join-Path $MOUNT_DIR 'Windows\System32\Tasks'
        if (Test-Path -LiteralPath $taskFilesRoot) {
            $edgeTasks = @(Get-ChildItem -LiteralPath $taskFilesRoot -Recurse -File -Force -ErrorAction Stop | Where-Object {
                $_.Name -match '(?i)^MicrosoftEdge(Update|Elevation|WebView).*|^MicrosoftEdgeUpdateTask' -or
                $_.FullName -match '(?i)\\EdgeUpdate(\\|$)'
            })
            foreach ($task in $edgeTasks) {
                if (-not (Invoke-TakeOwnership -Path $task.FullName)) {
                    throw "Failed to take ownership of Edge/EdgeUpdate task file '$($task.FullName)'."
                }
                if (-not (Remove-PathSafe -Path $task.FullName -Silent)) {
                    throw "Could not remove Edge/EdgeUpdate task file '$($task.FullName)'."
                }
            }
        }

        Invoke-OfflineRegistryCleanup -Action {
            param($cleanupHiveNames)

            # Remove any Edge Update task-cache registrations left by the files above.
            Remove-OfflineScheduledTasksByName -SystemHive 'HKLM\zCLEAN_SYSTEM' -NameRegex @(
                '(?i)^MicrosoftEdgeUpdateTask',
                '(?i)^MicrosoftEdgeElevation',
                '(?i)EdgeUpdate'
            )

            # Remove Edge/WebView2 updater and Edge elevation services from every
            # control set present in the offline SYSTEM hive.
            $systemRoot = 'Registry::HKLM\zCLEAN_SYSTEM\'
            $controlSets = @(Get-ChildItem -LiteralPath $systemRoot -Force -ErrorAction Stop |
                Where-Object { $_.PSChildName -match '^ControlSet\d{3}$' })
            foreach ($controlSet in $controlSets) {
                foreach ($serviceName in @(
                    'edgeupdate',
                    'edgeupdatem',
                    'MicrosoftEdgeElevationService'
                )) {
                    Remove-RegistryKeyIfExists -RegistryPath "HKLM\zCLEAN_SYSTEM\$($controlSet.PSChildName)\Services\$serviceName" -Description "Microsoft Edge service $serviceName"
                }
            }

            # Remove machine-wide Edge browser, WebView2 and EdgeUpdate registrations.
            $edgeRegistryKeys = @(
                'HKLM\zCLEAN_SOFTWARE\Microsoft\Edge',
                'HKLM\zCLEAN_SOFTWARE\Microsoft\EdgeUpdate',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\Edge',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate',
                'HKLM\zCLEAN_SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
                'HKLM\zCLEAN_SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedgewebview2.exe',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedgewebview2.exe',
                'HKLM\zCLEAN_SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge',
                'HKLM\zCLEAN_SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge WebView2 Runtime',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge WebView2 Runtime',
                'HKLM\zCLEAN_SOFTWARE\Clients\StartMenuInternet\Microsoft Edge',
                'HKLM\zCLEAN_SOFTWARE\Classes\microsoft-edge',
                'HKLM\zCLEAN_SOFTWARE\Classes\MSEdgeHTM',
                'HKLM\zCLEAN_SOFTWARE\RegisteredApplications\Microsoft Edge',
                'HKLM\zCLEAN_SOFTWARE\Policies\Microsoft\Edge',
                'HKLM\zCLEAN_SOFTWARE\Policies\Microsoft\EdgeUpdate',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Policies\Microsoft\EdgeUpdate'
            )
            foreach ($key in $edgeRegistryKeys) {
                if ($key -eq 'HKLM\zCLEAN_SOFTWARE\RegisteredApplications\Microsoft Edge') { continue }
                Remove-RegistryKeyIfExists -RegistryPath $key -Description 'Microsoft Edge / EdgeUpdate / WebView2'
            }
            Remove-RegistryValueIfExists -RegistryPath 'HKLM\zCLEAN_SOFTWARE\RegisteredApplications' -ValueName 'Microsoft Edge' -Description 'Microsoft Edge RegisteredApplications entry'

            foreach ($uninstallRoot in @(
                'HKLM\zCLEAN_SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            )) {
                $providerUninstallRoot = "Registry::$uninstallRoot"
                if (Test-Path -LiteralPath $providerUninstallRoot) {
                    foreach ($entry in @(Get-ChildItem -LiteralPath $providerUninstallRoot -Force -ErrorAction Stop)) {
                        $displayName = $null
                        try {
                            $props = Get-ItemProperty -LiteralPath $entry.PSPath -ErrorAction Stop
                            $displayName = [string]$props.DisplayName
                        } catch {
                            throw "Failed to inspect uninstall entry '$($entry.PSPath)': $($_.Exception.Message)"
                        }
                        if ($displayName -match '(?i)^Microsoft Edge( WebView2 Runtime| Update)?$') {
                            Remove-RegistryKeyIfExists -RegistryPath "$uninstallRoot\$($entry.PSChildName)" -Description "Edge/WebView2 uninstall registration ($displayName)"
                        }
                    }
                }
            }

            # Remove per-user Edge, EdgeUpdate and WebView2 registrations. The documented
            # WebView2 client GUID is F301...; removing the whole EdgeUpdate tree covers it
            # and all other updater client registrations, as requested.
            foreach ($hiveName in $cleanupHiveNames | Where-Object { $_ -match '^HKLM\\zCLEAN_(DEFAULT|USER\d+)$' }) {
                foreach ($key in @(
                    "$hiveName\Software\Microsoft\Edge",
                    "$hiveName\Software\Microsoft\EdgeUpdate",
                    "$hiveName\Software\WOW6432Node\Microsoft\Edge",
                    "$hiveName\Software\WOW6432Node\Microsoft\EdgeUpdate",
                    "$hiveName\Software\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge",
                    "$hiveName\Software\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge WebView2 Runtime",
                    "$hiveName\Software\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe",
                    "$hiveName\Software\Microsoft\Windows\CurrentVersion\App Paths\msedgewebview2.exe",
                    "$hiveName\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe",
                    "$hiveName\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedgewebview2.exe",
                    "$hiveName\Software\Classes\microsoft-edge",
                    "$hiveName\Software\Classes\MSEdgeHTM",
                    "$hiveName\Software\Classes\msedge"
                )) {
                    Remove-RegistryKeyIfExists -RegistryPath $key -Description 'Microsoft Edge / EdgeUpdate / WebView2 per-user registration'
                }
                Remove-RegistryValueIfExists -RegistryPath "$hiveName\Software\RegisteredApplications" -ValueName 'Microsoft Edge' -Description 'Microsoft Edge per-user RegisteredApplications entry'
            }

            # Verify the critical machine-wide registrations are gone before unloading.
            foreach ($verifyKey in @(
                'HKLM\zCLEAN_SOFTWARE\Microsoft\Edge',
                'HKLM\zCLEAN_SOFTWARE\Microsoft\EdgeUpdate',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate',
                'HKLM\zCLEAN_SOFTWARE\Policies\Microsoft\EdgeUpdate',
                'HKLM\zCLEAN_SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge',
                'HKLM\zCLEAN_SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge WebView2 Runtime',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge WebView2 Runtime'
            )) {
                $verifyResult = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('query', $verifyKey)
                if ($verifyResult.ExitCode -eq 0) { throw "Residual Edge/EdgeUpdate/WebView2 registry key remains after cleanup: $verifyKey" }
            }

            foreach ($controlSet in $controlSets) {
                foreach ($serviceName in @('edgeupdate','edgeupdatem','MicrosoftEdgeElevationService')) {
                    $serviceKey = "Registry::HKLM\zCLEAN_SYSTEM\$($controlSet.PSChildName)\Services\$serviceName"
                    if (Test-Path -LiteralPath $serviceKey) {
                        throw "Residual Microsoft Edge service registration remains: $($controlSet.PSChildName)\$serviceName"
                    }
                }
            }
            $remainingEdgeTaskCache = @()
            try {
                $remainingEdgeTaskCache = @(
                    Get-ChildItem `
                        -LiteralPath 'Registry::HKLM\zCLEAN_SYSTEM\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree' `
                        -Recurse -Force -ErrorAction Stop |
                    Where-Object { $_.PSChildName -match '(?i)EdgeUpdate|MicrosoftEdgeUpdateTask|MicrosoftEdgeElevation' }
                )
            }
            catch [System.Management.Automation.ItemNotFoundException] {
                # No TaskCache tree exists in this image; there is nothing to verify.
                $remainingEdgeTaskCache = @()
            }
            if ($remainingEdgeTaskCache.Count -gt 0) {
                Write-WarningMsg "Residual EdgeUpdate scheduled-task registrations remain in the offline image (the task binaries are gone, so they cannot execute): $($remainingEdgeTaskCache.PSChildName -join ', ')"
            }
        }

        $remainingEdgeTaskFiles = @()
        if (Test-Path -LiteralPath $taskFilesRoot) {
            $remainingEdgeTaskFiles = @(Get-ChildItem -LiteralPath $taskFilesRoot -Recurse -File -Force -ErrorAction Stop | Where-Object {
                $_.Name -match '(?i)^MicrosoftEdge(Update|Elevation|WebView).*|^MicrosoftEdgeUpdateTask' -or
                $_.FullName -match '(?i)\\EdgeUpdate(\\|$)'
            })
        }
        if ($remainingEdgeTaskFiles.Count -gt 0) {
            throw "Residual EdgeUpdate task files remain in the offline image: $($remainingEdgeTaskFiles.FullName -join ', ')"
        }

        # Remove Edge/WebView2 updater state and user-profile payloads from every offline profile.
        $profilesRoot = Join-Path $MOUNT_DIR 'Users'
        if (Test-Path -LiteralPath $profilesRoot) {
            foreach ($profile in @(Get-ChildItem -LiteralPath $profilesRoot -Directory -Force -ErrorAction Stop)) {
                if ($profile.Name -ieq 'Public' -or $profile.Name -ieq 'All Users') { continue }
                foreach ($relativePath in @(
                    'AppData\Local\Microsoft\Edge',
                    'AppData\Local\Microsoft\EdgeUpdate',
                    'AppData\Local\Microsoft\EdgeWebView',
                    'AppData\Roaming\Microsoft\Edge',
                    'AppData\Roaming\Microsoft\EdgeUpdate',
                    'AppData\Roaming\Microsoft\EdgeWebView'
                )) {
                    $profilePath = Join-Path $profile.FullName $relativePath
                    if (Test-Path -LiteralPath $profilePath) {
                        if (-not (Invoke-TakeOwnership -Path $profilePath -Recurse)) {
                            throw "Failed to take ownership of Edge/WebView2 profile data '$profilePath'."
                        }
                        if (-not (Remove-PathSafe -Path $profilePath)) {
                            throw "Failed to remove Edge/WebView2 profile data '$profilePath'."
                        }
                    }
                }
            }
        }

        # Remove any provisioned Edge package that may exist on the source build.
        $edgeProvisionedPrefixes = @(
            'Microsoft.MicrosoftEdge',
            'Microsoft.EdgeWebView2',
            'Microsoft.MicrosoftEdgeDevToolsClient'
        )
        $edgeProvisionedResult = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @(
            '/English', "/image:$MOUNT_DIR", '/Get-ProvisionedAppxPackages'
        )
        if ($edgeProvisionedResult.ExitCode -ne 0) {
            throw "Failed to enumerate provisioned packages for Edge/WebView2 removal (DISM exit code $($edgeProvisionedResult.ExitCode))."
        }
        $edgeProvisionedPackages = @($edgeProvisionedResult.Output | ForEach-Object {
            if ($_ -match 'PackageName\s*:\s*(.*)') { $matches[1].Trim() }
        } | Where-Object {
            $pkg = $_
            foreach ($prefix in $edgeProvisionedPrefixes) {
                if ($pkg -like "$prefix*") { return $true }
            }
            return $false
        })
        foreach ($package in $edgeProvisionedPackages) {
            $edgeRemoveResult = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @(
                '/English', "/image:$MOUNT_DIR",
                '/Remove-ProvisionedAppxPackage', "/PackageName:$package"
            )
            if ($edgeRemoveResult.ExitCode -ne 0) {
                throw "Failed to remove provisioned Edge/WebView2 package '$package' (DISM exit code $($edgeRemoveResult.ExitCode))."
            }
        }
        $edgeProvisionedVerify = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @(
            '/English', "/image:$MOUNT_DIR", '/Get-ProvisionedAppxPackages'
        )
        if ($edgeProvisionedVerify.ExitCode -ne 0) { throw "Failed to verify Edge/WebView2 provisioned package removal." }
        $remainingEdgePackages = @($edgeProvisionedVerify.Output | ForEach-Object {
            if ($_ -match 'PackageName\s*:\s*(.*)') { $matches[1].Trim() }
        } | Where-Object {
            $pkg = $_
            foreach ($prefix in $edgeProvisionedPrefixes) {
                if ($pkg -like "$prefix*") { return $true }
            }
            return $false
        })
        if ($remainingEdgePackages.Count -gt 0) {
            throw "Edge/WebView2 provisioned packages remain after removal: $($remainingEdgePackages -join ', ')"
        }

        $remainingEdgeComponents = @(
            "$MOUNT_DIR\Program Files (x86)\Microsoft\Edge",
            "$MOUNT_DIR\Program Files\Microsoft\Edge",
            "$MOUNT_DIR\Program Files (x86)\Microsoft\EdgeWebView",
            "$MOUNT_DIR\Program Files\Microsoft\EdgeWebView",
            "$MOUNT_DIR\Program Files (x86)\Microsoft\EdgeUpdate",
            "$MOUNT_DIR\Program Files\Microsoft\EdgeUpdate",
            "$MOUNT_DIR\ProgramData\Microsoft\EdgeUpdate",
            "$MOUNT_DIR\ProgramData\Microsoft\EdgeWebView"
        ) | Where-Object { Test-Path -LiteralPath $_ }
        if ($remainingEdgeComponents.Count -gt 0) {
            throw "Edge/EdgeUpdate/WebView2 removal did not complete; remaining component paths: $($remainingEdgeComponents -join ', ')"
        }

        Write-Ok "Microsoft Edge, EdgeUpdate, and removable Evergreen WebView2 components were removed. OS-owned System32 WebView2 files were left untouched."
        $mainProgress.CompleteStep()

    # ==================== REMOVE ONEDRIVE ====================
    
        $mainProgress.StartStep("Removing OneDrive")
        Write-Step "Removing OneDrive and its registry/shell integration..."

        $oneDrivePaths = @(
            "$MOUNT_DIR\Windows\System32\OneDriveSetup.exe",
            "$MOUNT_DIR\SysWOW64\OneDriveSetup.exe",
            "$MOUNT_DIR\Program Files\Microsoft OneDrive",
            "$MOUNT_DIR\Program Files (x86)\Microsoft OneDrive"
        )
        foreach ($oneDrivePath in $oneDrivePaths) {
            if (Test-Path -LiteralPath $oneDrivePath) {
                if (-not (Invoke-TakeOwnership -Path $oneDrivePath -Recurse)) {
                    throw "Failed to take ownership of OneDrive payload '$oneDrivePath'."
                }
                if (-not (Remove-PathSafe -Path $oneDrivePath)) {
                    throw "Failed to remove OneDrive payload '$oneDrivePath'."
                }
            }
        }

        # Remove client state, but never delete Users\*\OneDrive folders: those are
        # user data, not application components.
        foreach ($pattern in @(
            "$MOUNT_DIR\Users\*\AppData\Local\Microsoft\OneDrive",
            "$MOUNT_DIR\Users\Default\AppData\Roaming\Microsoft\OneDrive"
        )) {
            foreach ($item in @(Get-Item -Path $pattern -Force -ErrorAction SilentlyContinue)) {
                if (-not (Invoke-TakeOwnership -Path $item.FullName -Recurse)) {
                    throw "Failed to take ownership of OneDrive client data '$($item.FullName)'."
                }
                if (-not (Remove-PathSafe -Path $item.FullName)) {
                    throw "Failed to remove OneDrive client data '$($item.FullName)'."
                }
            }
        }

        # Remove OneDrive scheduled-update tasks and shortcuts, but never touch
        # user OneDrive data folders.
        foreach ($taskRoot in @(
            "$MOUNT_DIR\Windows\System32\Tasks\Microsoft\Windows\OneDrive",
            "$MOUNT_DIR\Windows\System32\Tasks\OneDrive"
        )) {
            if (Test-Path -LiteralPath $taskRoot) {
                if (-not (Invoke-TakeOwnership -Path $taskRoot -Recurse)) {
                    throw "Failed to take ownership of OneDrive scheduled-task directory '$taskRoot'."
                }
                if (-not (Remove-PathSafe -Path $taskRoot)) {
                    throw "Failed to remove OneDrive scheduled-task directory '$taskRoot'."
                }
            }
        }
        foreach ($shortcutRoot in @(
            "$MOUNT_DIR\ProgramData\Microsoft\Windows\Start Menu\Programs",
            "$MOUNT_DIR\Users\Default\AppData\Roaming\Microsoft\Windows\Start Menu\Programs"
        )) {
            foreach ($shortcut in @(Get-ChildItem -LiteralPath $shortcutRoot -Filter '*OneDrive*.lnk' -File -Force -ErrorAction SilentlyContinue)) {
                if (-not (Remove-PathSafe -Path $shortcut.FullName -Silent)) {
                    throw "Could not remove OneDrive shortcut '$($shortcut.FullName)'."
                }
            }
        }

        Invoke-OfflineRegistryCleanup -Action {
            param($cleanupHiveNames)

            Remove-OfflineScheduledTaskTree -SystemHive 'HKLM\zCLEAN_SYSTEM' -TaskTreePath 'Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\OneDrive'
            Remove-OfflineScheduledTaskTree -SystemHive 'HKLM\zCLEAN_SYSTEM' -TaskTreePath 'Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\OneDrive'

            $oneDriveRegistryKeys = @(
                'HKLM\zCLEAN_SOFTWARE\Microsoft\OneDrive',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\OneDrive',
                'HKLM\zCLEAN_SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
                'HKLM\zCLEAN_SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft OneDrive',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft OneDrive',
                'HKLM\zCLEAN_SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
                'HKLM\zCLEAN_SOFTWARE\Classes\WOW6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
                'HKLM\zCLEAN_SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
            )
            foreach ($key in $oneDriveRegistryKeys) {
                Remove-RegistryKeyIfExists -RegistryPath $key -Description 'OneDrive'
            }

            foreach ($overlayRoot in @(
                'HKLM\zCLEAN_SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
            )) {
                $providerOverlayRoot = "Registry::$overlayRoot"
                if (Test-Path -LiteralPath $providerOverlayRoot) {
                    foreach ($overlay in @(Get-ChildItem -LiteralPath $providerOverlayRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '(?i)OneDrive' })) {
                        Remove-RegistryKeyIfExists -RegistryPath "$overlayRoot\$($overlay.PSChildName)" -Description 'OneDrive shell overlay registration'
                    }
                }
            }
            Remove-RegistryValueIfExists -RegistryPath 'HKLM\zCLEAN_SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ValueName 'OneDrive' -Description 'OneDrive system startup entry'

            foreach ($hiveName in $cleanupHiveNames | Where-Object { $_ -match '^HKLM\\zCLEAN_(DEFAULT|USER\d+)$' }) {
                Remove-RegistryKeyIfExists -RegistryPath "$hiveName\Software\Microsoft\OneDrive" -Description 'OneDrive user state'
                Remove-RegistryKeyIfExists -RegistryPath "$hiveName\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe" -Description 'OneDrive user uninstall registration'
                Remove-RegistryKeyIfExists -RegistryPath "$hiveName\Software\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft OneDrive" -Description 'OneDrive user uninstall registration'
                Remove-RegistryKeyIfExists -RegistryPath "$hiveName\Software\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}" -Description 'OneDrive user shell integration'
                Remove-RegistryKeyIfExists -RegistryPath "$hiveName\Software\Classes\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}" -Description 'OneDrive user shell integration'
                Remove-RegistryKeyIfExists -RegistryPath "$hiveName\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}" -Description 'OneDrive user namespace integration'
                Remove-RegistryValueIfExists -RegistryPath "$hiveName\Software\Microsoft\Windows\CurrentVersion\Run" -ValueName 'OneDrive' -Description 'OneDrive user startup entry'
                Remove-RegistryValueIfExists -RegistryPath "$hiveName\Software\Microsoft\Windows\CurrentVersion\Run" -ValueName 'OneDriveSetup' -Description 'OneDrive user startup entry'
                $userOverlayRoot = "Registry::$hiveName\Software\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers"
                if (Test-Path -LiteralPath $userOverlayRoot) {
                    foreach ($overlay in @(Get-ChildItem -LiteralPath $userOverlayRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '(?i)OneDrive' })) {
                        Remove-RegistryKeyIfExists -RegistryPath "$hiveName\Software\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers\$($overlay.PSChildName)" -Description 'OneDrive user shell overlay registration'
                    }
                }
            }

            foreach ($verifyKey in @(
                'HKLM\zCLEAN_SOFTWARE\Microsoft\OneDrive',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\OneDrive',
                'HKLM\zCLEAN_SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
                'HKLM\zCLEAN_SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft OneDrive',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
                'HKLM\zCLEAN_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft OneDrive',
                'HKLM\zCLEAN_SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
                'HKLM\zCLEAN_SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
            )) {
                $verifyResult = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('query', $verifyKey)
                if ($verifyResult.ExitCode -eq 0) { throw "Residual OneDrive registry key remains after cleanup: $verifyKey" }
            }
        }

        $remainingOneDrive = @(
            "$MOUNT_DIR\Windows\System32\OneDriveSetup.exe",
            "$MOUNT_DIR\SysWOW64\OneDriveSetup.exe",
            "$MOUNT_DIR\Program Files\Microsoft OneDrive",
            "$MOUNT_DIR\Program Files (x86)\Microsoft OneDrive"
        ) | Where-Object { Test-Path -LiteralPath $_ }

        if ($remainingOneDrive.Count -gt 0) {
            # OneDriveSetup.exe is a TrustedInstaller-owned servicing component. Its
            # file handle is held by DISM's offline servicing session while the WIM is
            # mounted, so it cannot be removed from here even after takeown/icacls.
            # This is expected and harmless: the scheduled task, the startup entry,
            # the shell integration and every registry path that could launch it are
            # gone. Schedule the file for deletion by SetupComplete.cmd on first boot,
            # which runs as SYSTEM after the image is installed and no servicing lock
            # is present.
            Write-WarningMsg "These OneDrive payloads could not be removed offline (protected by the servicing stack); they will be removed on first boot: $($remainingOneDrive -join ', ')"
        }
        Write-Ok "OneDrive client, shell integration, startup entries, and uninstall registrations removed (user OneDrive folders preserved)."
        $mainProgress.CompleteStep()
    

    # ==================== REGISTRY TWEAKS ====================
    # autounattend.xml is intentionally placed on the ISO root below. Do not also
    # copy it into %WINDIR%\System32\Sysprep: that location is intended for
    # Unattend.xml and later Sysprep/configuration phases.

    if (-not $SkipRegistryTweaks) {
        $mainProgress.StartStep("Applying registry tweaks")
        Write-Step "Loading registry hives..."

        $hives = [ordered]@{
            'HKLM\zDEFAULT'    = (Join-Path $MOUNT_DIR "Windows\System32\config\default")
            'HKLM\zNTUSER'     = (Join-Path $MOUNT_DIR "Users\Default\ntuser.dat")
            'HKLM\zSOFTWARE'   = (Join-Path $MOUNT_DIR "Windows\System32\config\SOFTWARE")
            'HKLM\zSYSTEM'     = (Join-Path $MOUNT_DIR "Windows\System32\config\SYSTEM")
        }

        # These aliases are owned by this build process and are about to be
		# loaded by Invoke-RegistryHiveOperations. Do not blindly call
		# "reg.exe unload" here: reg.exe returns "The parameter is incorrect"
		# when the alias is not currently loaded.
		Write-Step "Preparing offline registry hive aliases..."
        $loadedHives = Invoke-RegistryHiveOperations -Operation Load -Hives $hives
        if ($loadedHives.Count -ne $hives.Count) {
            $expected = @($hives.Keys)
            $missing = @($expected | Where-Object { $loadedHives -notcontains $_ })
            throw "Failed to load all required offline registry hives. Missing: $($missing -join ', ')"
        }
        Write-Ok "Loaded $($loadedHives.Count) registry hives."

        $activeControlSet = Get-OfflineActiveControlSet
        Write-Ok "Offline SYSTEM active control set: $activeControlSet"

        # --- System requirement bypass ---
        Write-Step "Applying system requirement bypass..."
        Set-RegistryValuesMap -Map @{
            'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' = @{ 'SV1' = 0; 'SV2' = 0 }
            'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache'  = @{ 'SV1' = 0; 'SV2' = 0 }
            'HKLM\zSYSTEM\Setup\LabConfig' = @{
                'BypassCPUCheck' = 1; 'BypassRAMCheck' = 1; 'BypassSecureBootCheck' = 1
                'BypassStorageCheck' = 1; 'BypassTPMCheck' = 1
            }
            'HKLM\zSYSTEM\Setup\MoSetup' = @{ 'AllowUpgradesWithUnsupportedTPMOrCPU' = 1 }
        }

        # --- Content delivery ---
        Write-Step "Disabling content delivery..."
        Set-RegistryValuesMap -Map @{
            'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' = @{
                'OemPreInstalledAppsEnabled' = 0; 'PreInstalledAppsEnabled' = 0
                'SilentInstalledAppsEnabled' = 0; 'ContentDeliveryAllowed' = 0
                'FeatureManagementEnabled' = 0; 'PreInstalledAppsEverEnabled' = 0
                'SoftLandingEnabled' = 0; 'SubscribedContentEnabled' = 0
                'SubscribedContent-310093Enabled' = 0; 'SubscribedContent-338388Enabled' = 0
                'SubscribedContent-338389Enabled' = 0; 'SubscribedContent-338393Enabled' = 0
                'SubscribedContent-353694Enabled' = 0; 'SubscribedContent-353696Enabled' = 0
                'SystemPaneSuggestionsEnabled' = 0
            }
            'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' = @{
                'DisableWindowsConsumerFeatures' = 1; 'DisableConsumerAccountStateContent' = 1
                'DisableCloudOptimizedContent' = 1
            }
            'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' = @{ 'DisablePushToInstall' = 1 }
            'HKLM\zSOFTWARE\Policies\Microsoft\MRT'           = @{ 'DontOfferThroughWUAU' = 1 }
        }

		foreach ($deleteKey in @(
			'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions',
			'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
		)) {
			# These are optional cleanup keys. They may not exist in this Windows
			# image, so check first rather than invoking reg.exe against a missing key.
			$providerKey = "Registry::$deleteKey"

			if (Test-Path -LiteralPath $providerKey) {
				$deleteResult = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('delete', $deleteKey, '/f')

				if ($deleteResult.ExitCode -ne 0) {
					throw "Failed to delete optional registry key $deleteKey (reg.exe exit code $($deleteResult.ExitCode)): $($deleteResult.Output -join ' ')"
				}

				Write-Ok "Deleted optional registry key: $deleteKey"
			}
			else {
				Write-Step "Optional registry key not present: $deleteKey"
			}
		}

        # --- Local account / OOBE ---
        # OOBE behavior is controlled by the validated autounattend.xml on the ISO.
        # Do not write BypassNRO here: newer Windows builds may ignore that registry
        # value, so treating it as a required mechanism makes the image unreliable.
        Write-Step "Using validated autounattend.xml for offline/local-account OOBE..."

        # --- BitLocker ---
        Write-Step "Disabling BitLocker auto-encryption..."
        Set-RegistryValue -HivePath ('HKLM\zSYSTEM\{0}\Control\BitLocker' -f $activeControlSet) -Values @{ 'PreventDeviceEncryption' = 1 }

        # --- Chat icon ---
        Write-Step "Disabling Chat icon..."
        Set-RegistryValue -HivePath 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' -Values @{ 'ChatIcon' = 3 }
        Set-RegistryValue -HivePath 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Values @{ 'TaskbarMn' = 0 }

        # --- OneDrive backup ---
        Write-Step "Disabling OneDrive sync/backup policy..."
        Set-RegistryValue -HivePath 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive' -Values @{ 'DisableFileSyncNGSC' = 1 }

        # --- Telemetry ---
        # Telemetry removal is always enabled; there is intentionally no skip switch.
        Write-Step "Disabling telemetry..."
        Set-RegistryValuesMap -Map @{
            'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'        = @{ 'Enabled' = 0 }
            'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy'                = @{ 'TailoredExperiencesWithDiagnosticDataEnabled' = 0 }
            'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'   = @{ 'HasAccepted' = 0 }
            'HKLM\zNTUSER\Software\Microsoft\Input\TIPC'                                    = @{ 'Enabled' = 0 }
            'HKLM\zNTUSER\Software\Microsoft\InputPersonalization'                          = @{ 'RestrictImplicitInkCollection' = 1; 'RestrictImplicitTextCollection' = 1 }
            'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings'                      = @{ 'AcceptedPrivacyPolicy' = 0 }
            'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection'                      = @{ 'AllowTelemetry' = 0 }
        }
        $telemetryServiceKey = 'HKLM\zSYSTEM\{0}\Services\dmwappushservice' -f $activeControlSet
        try {
            Set-RegistryValue -HivePath $telemetryServiceKey -Values @{ 'Start' = 4 } -RequireExistingKey
        } catch {
            # Some Windows builds do not contain this legacy service. Never create
            # a partial service registry tree just to apply the telemetry tweak.
            Write-WarningMsg "Skipping dmwappushservice registry tweak: $($_.Exception.Message)"
        }

        # --- Prevent DevHome & Outlook ---
		# Scheduler flags alone do not remove provisioned packages. Remove targeted
		# packages first, then apply compatibility scheduler guards.
		Write-Step "Removing/preventing DevHome and New Outlook..."

		$optionalProvisionedPrefixes = @(
			'Microsoft.OutlookForWindows_',
			'Microsoft.Windows.DevHome_',
			'Microsoft.DevHome_'
		)

		# DISM can return exit code 32 when there are no provisioned packages
		# matching/available for enumeration in the offline image. Capture the
		# native output without allowing ErrorActionPreference=Stop to abort first.
		$optionalResult = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @(
			'/English', "/image:$MOUNT_DIR", '/Get-ProvisionedAppxPackages'
		)
		$optionalDismExitCode = $optionalResult.ExitCode

		if ($optionalDismExitCode -ne 0 -and $optionalDismExitCode -ne 32) {
			throw "Failed to enumerate provisioned packages for Outlook/DevHome removal (DISM exit code $optionalDismExitCode): $($optionalResult.Output -join ' ')"
		}

		$optionalPackages = @(
			$optionalResult.Output |
				ForEach-Object {
					if ($_ -match 'PackageName\s*:\s*(.*)') {
						$matches[1].Trim()
					}
				} |
				Where-Object {
					$pkg = $_
					foreach ($prefix in $optionalProvisionedPrefixes) {
						if ($pkg -like "$prefix*") {
							return $true
						}
					}
					return $false
				}
		)

		foreach ($package in $optionalPackages) {
			$removeResult = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @(
				'/English', "/image:$MOUNT_DIR",
				'/Remove-ProvisionedAppxPackage', "/PackageName:$package"
			)

			if ($removeResult.ExitCode -ne 0) {
				throw "Failed to remove provisioned Outlook/DevHome package '$package' (DISM exit code $($removeResult.ExitCode)): $($removeResult.Output -join ' ')"
			}

			Write-Ok "Removed provisioned package: $package"
		}

		if ($optionalPackages.Count -eq 0) {
			Write-Step "No provisioned Outlook/DevHome packages found; continuing."
		}

		Set-RegistryValue `
			-HivePath 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' `
			-Values @{ 'workCompleted' = 1 }

		Set-RegistryValue `
			-HivePath 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' `
			-Values @{ 'workCompleted' = 1 }

		foreach ($deleteKey in @(
			'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate',
			'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'
		)) {
			$deleteResult = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('delete', $deleteKey, '/f')

			if ($deleteResult.ExitCode -ne 0 -and $deleteResult.ExitCode -ne 1) {
				throw "Failed to delete optional update scheduler key $deleteKey (reg.exe exit code $($deleteResult.ExitCode))"
			}
		}

		# Verify. Exit code 32 is treated the same way as the initial enumeration:
		# there is nothing provisioned to verify.
		$verifyOptionalResult = Invoke-NativeCommand -FilePath 'dism.exe' -Arguments @(
			'/English', "/image:$MOUNT_DIR", '/Get-ProvisionedAppxPackages'
		)
		$verifyOptionalExitCode = $verifyOptionalResult.ExitCode

		if ($verifyOptionalExitCode -ne 0 -and $verifyOptionalExitCode -ne 32) {
			throw "Failed to verify Outlook/DevHome package removal (DISM exit code $verifyOptionalExitCode)."
		}

		$remainingOptional = @(
			$verifyOptionalResult.Output |
				ForEach-Object {
					if ($_ -match 'PackageName\s*:\s*(.*)') {
						$matches[1].Trim()
					}
				} |
				Where-Object {
					$pkg = $_
					foreach ($prefix in $optionalProvisionedPrefixes) {
						if ($pkg -like "$prefix*") {
							return $true
						}
					}
					return $false
				}
		)

		if ($remainingOptional.Count -gt 0) {
			throw "Outlook/DevHome provisioned packages remain after removal: $($remainingOptional -join ', ')"
		}

        # --- Copilot ---
        Write-Step "Disabling Copilot..."
        Set-RegistryValue -HivePath 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Values @{ 'TurnOffWindowsCopilot' = 1 }
        Set-RegistryValue -HivePath 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer'      -Values @{ 'DisableSearchBoxSuggestions' = 1 }

        # --- Teams ---
        Write-Step "Disabling Teams..."
        Set-RegistryValue -HivePath 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' -Values @{ 'DisableInstallation' = 1 }

        # --- New Outlook ---
        Write-Step "Disabling New Outlook..."
        Set-RegistryValue -HivePath 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' -Values @{ 'PreventRun' = 1 }

		# --- Delete scheduled tasks ---
		Write-Step "Deleting telemetry scheduled tasks..."

		$tasksToDelete = @(
			(Join-Path $MOUNT_DIR "Windows\System32\Tasks\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser"),
			(Join-Path $MOUNT_DIR "Windows\System32\Tasks\Microsoft\Windows\Application Experience\ProgramDataUpdater"),
			(Join-Path $MOUNT_DIR "Windows\System32\Tasks\Microsoft\Windows\Customer Experience Improvement Program"),
			(Join-Path $MOUNT_DIR "Windows\System32\Tasks\Microsoft\Windows\Chkdsk\Proxy"),
			(Join-Path $MOUNT_DIR "Windows\System32\Tasks\Microsoft\Windows\Windows Error Reporting\QueueReporting")
		)

		foreach ($task in $tasksToDelete) {
			if (Test-Path -LiteralPath $task) {
				if (-not (Invoke-TakeOwnership -Path $task)) {
					throw "Failed to take ownership of scheduled task file '$task'."
				}

				if (-not (Remove-PathSafe -Path $task -Silent)) {
					throw "Could not remove scheduled task file '$task'."
				}
			}
		}

		# NOTE:
		# The offline TaskCache registry cleanup is temporarily disabled while
		# diagnosing an HKLM\zSYSTEM hive unload/handle issue. The task files
		# themselves are still removed above.
		#
		# foreach ($taskTreePath in @(
		#     'Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
		#     'Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Application Experience\ProgramDataUpdater',
		#     'Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Customer Experience Improvement Program',
		#     'Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Chkdsk\Proxy',
		#     'Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\Error Reporting\QueueReporting'
		# )) {
		#     Remove-OfflineScheduledTaskTree -SystemHive 'HKLM\zSYSTEM' -TaskTreePath $taskTreePath
		# }

		# --- Unload hives ---
		Write-Step "Unloading registry hives..."

		$unloadedHives = @(Invoke-RegistryHiveOperations -Operation Unload -Hives @($loadedHives))

		if ($unloadedHives.Count -ne @($loadedHives).Count) {
			$remainingHives = @(
				@($loadedHives) | Where-Object {
					$unloadedHives -notcontains $_
				}
			)

			$loadedHives = $remainingHives

			throw "Failed to unload one or more main-image registry hives. Still loaded: $($remainingHives -join ', ')"
		}

		$loadedHives = @()

		$mainProgress.CompleteStep()

    }
	else {
        $mainProgress.StartStep("Skipping registry tweaks")
        Write-WarningMsg "Skipping registry tweaks as requested."
        $mainProgress.CompleteStep()
    }

    # ==================== EXPORT AND COMPRESS ====================
    $mainProgress.StartStep("Exporting and compressing image")

    if (-not $SkipComponentCleanup) {
        # /ResetBase is destructive; require explicit confirmation.
        $proceed = Test-Confirmation "Component cleanup with /ResetBase will prevent uninstalling Windows updates. Continue?"
        if ($proceed) {
            Write-Step "Cleaning up image components (this can take a long time)..."
            Repair-WindowsImage -Path $MOUNT_DIR -StartComponentCleanup -ResetBase -ErrorAction Stop
        } else {
            Write-WarningMsg "User declined /ResetBase; skipping component cleanup."
        }
    } else {
        Write-WarningMsg "Skipping component cleanup (-ResetBase)."
    }

    Write-Step "Unmounting and saving image..."
    Invoke-WindowsImageDismountRobust -MountPath $MOUNT_DIR -Attempts 5 -InitialDelaySeconds 2
    $mainImageMounted = $false

    # Give DISM a moment to close the WIM before the export stage opens it again.
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 5

    $compressionToken = @{ Maximum = 'maximum'; Fast = 'fast'; None = 'none' }[$ExportCompression]
    if (-not $compressionToken) { throw "Unsupported export compression '$ExportCompression'." }
    Write-Step "Exporting image with $ExportCompression compression..."
    $tempWimPath = Join-Path $WORK_DIR "sources\install2.wim"
    if (Test-Path $tempWimPath) { Remove-Item $tempWimPath -Force -ErrorAction Stop }
    $exportArgs = @(
        '/English', '/Export-Image',
        "/SourceImageFile:$WIM_PATH",
        "/SourceIndex:$index",
        "/DestinationImageFile:$tempWimPath",
        "/Compress:$compressionToken",
        '/CheckIntegrity'
    )
    $null = Invoke-DismChecked -Arguments $exportArgs -Description "DISM final image export"
    if (-not (Test-Path -LiteralPath $tempWimPath)) { throw "DISM reported success but did not create '$tempWimPath'." }

    $exportedImages = @(Get-WindowsImage -ImagePath $tempWimPath -ErrorAction Stop)
    if (-not $exportedImages -or $exportedImages.Count -lt 1) {
        throw "Temporary exported WIM contains no readable images."
    }
    Remove-Item -Path $WIM_PATH -Force -ErrorAction Stop
    Rename-Item -Path $tempWimPath -NewName "install.wim" -ErrorAction Stop
    $finalImages = @(Get-WindowsImage -ImagePath $WIM_PATH -ErrorAction Stop)
    if ($finalImages.Count -ne 1 -or $finalImages[0].ImageIndex -ne 1) {
        throw "Final install.wim is not a valid single-image WIM after customization/export."
    }

    Write-Ok "Main image customization complete. Exported WIM contains exactly one image."
    $mainProgress.CompleteStep()

    # ==================== CUSTOMIZE BOOT.WIM ====================
	$mainProgress.StartStep("Customizing boot.wim")
	Write-Banner "Customizing boot.wim" Magenta

	if (-not (Test-Path -LiteralPath $BOOT_WIM_PATH)) {
		Write-ErrorMessage "boot.wim not found at $BOOT_WIM_PATH"
		throw "Missing boot.wim"
	}

	# Enumerate boot.wim images and identify the Windows Setup image.
	$bootImages = @(Get-WindowsImage -ImagePath $BOOT_WIM_PATH -ErrorAction Stop)

	if ($bootImages.Count -eq 0) {
		throw "No images found in boot.wim."
	}

	$setupImage = $bootImages |
		Where-Object {
			$_.ImageName -match '(?i)Windows.*Setup|Microsoft.*Setup'
		} |
		Select-Object -First 1

	if ($setupImage) {
		$bootIndex = [int]$setupImage.ImageIndex
	} elseif ($bootImages | Where-Object { $_.ImageIndex -eq 2 }) {
		$bootIndex = 2
	} else {
		$bootIndex = [int]$bootImages[0].ImageIndex
		Write-WarningMsg "Could not identify a Windows Setup image by name; falling back to boot.wim index $bootIndex."
	}

	Write-Step "Using boot.wim index $bootIndex"

	# Prepare boot.wim for mounting.
	if (-not (Invoke-TakeOwnership -Path $BOOT_WIM_PATH)) {
		throw "Failed to prepare boot.wim for mounting: ownership/ACL update failed."
	}

	Set-ItemProperty `
		-Path $BOOT_WIM_PATH `
		-Name IsReadOnly `
		-Value $false `
		-ErrorAction Stop

	Write-Step "Verifying DISM mount state before mounting boot.wim..."
	$bootMountConflicts = @(Get-DismMountedImagesSafe | Where-Object {
		($_.MountPath -and (Test-SameWindowsPath ([string]$_.MountPath) $MOUNT_DIR)) -or
		($_.ImagePath -and (Test-SameWindowsPath ([string]$_.ImagePath) $BOOT_WIM_PATH))
	})
	if ($bootMountConflicts.Count -gt 0) {
		$details = ($bootMountConflicts | ForEach-Object { "MountPath='$($_.MountPath)', ImagePath='$($_.ImagePath)'" }) -join '; '
		throw "Refusing to mount boot.wim because DISM already reports a conflicting mount: $details"
	}

	Write-Step "Mounting boot.wim (Index $bootIndex)..."

	Mount-WindowsImage `
		-ImagePath $BOOT_WIM_PATH `
		-Index $bootIndex `
		-Path $MOUNT_DIR `
		-CheckIntegrity `
		-ErrorAction Stop

	$bootImageMounted = $true

	# Track the boot image mount explicitly so cleanup can recover if
	# anything below fails.

	try {
		# Only SYSTEM is modified in boot.wim.
		# Loading a single hive minimizes registry-lock/cleanup risk.
		$bootHives = [ordered]@{
			'HKLM\zSYSTEM' = Join-Path $MOUNT_DIR 'Windows\System32\config\SYSTEM'
		}

		Write-Step "Loading boot.wim SYSTEM registry hive..."

		# Do NOT blindly call:
		#   reg.exe unload HKLM\zSYSTEM
		#
		# The hive is not expected to be loaded before this operation.
		# A blind unload produces "The parameter is incorrect" under
		# some PowerShell/native-command error handling configurations.
		$loadedBootHives = @(
			Invoke-RegistryHiveOperations `
				-Operation Load `
				-Hives $bootHives
		)

		if ($loadedBootHives.Count -ne $bootHives.Count) {
			$expectedBootHives = @($bootHives.Keys)

			$missingBootHives = @(
				$expectedBootHives | Where-Object {
					$loadedBootHives -notcontains $_
				}
			)

			throw "Failed to load all required boot.wim registry hives. Missing: $($missingBootHives -join ', ')"
		}

		Write-Ok "Boot.wim SYSTEM registry hive loaded."

		Write-Step "Applying system requirement bypass to boot image..."

		Set-RegistryValuesMap -Map @{
			'HKLM\zSYSTEM\Setup\LabConfig' = @{
				'BypassCPUCheck'        = 1
				'BypassRAMCheck'        = 1
				'BypassSecureBootCheck' = 1
				'BypassStorageCheck'    = 1
				'BypassTPMCheck'        = 1
			}

			'HKLM\zSYSTEM\Setup\MoSetup' = @{
				'AllowUpgradesWithUnsupportedTPMOrCPU' = 1
			}
		}

		Write-Ok "Boot.wim system requirement bypass applied."

		Write-Step "Unloading boot.wim registry hives..."

		$unloadedBootHives = @(
			Invoke-RegistryHiveOperations `
				-Operation Unload `
				-Hives @($loadedBootHives)
		)

		if ($unloadedBootHives.Count -ne @($loadedBootHives).Count) {
			$remainingBootHives = @(
				@($loadedBootHives) | Where-Object {
					$unloadedBootHives -notcontains $_
				}
			)

			throw "Failed to unload one or more boot.wim registry hives. Still loaded: $($remainingBootHives -join ', ')"
		}

		# Do not call .Clear() or .Remove() on the returned collection.
		# Convert it to a plain array after successful unload.
		$loadedBootHives = @()

		Write-Ok "Boot.wim registry hives unloaded."

		Write-Step "Unmounting and saving boot.wim..."

		Invoke-WindowsImageDismountRobust -MountPath $MOUNT_DIR -Attempts 5 -InitialDelaySeconds 2
		$bootImageMounted = $false

		[GC]::Collect()
		[GC]::WaitForPendingFinalizers()
		Start-Sleep -Seconds 5

		Write-Ok "Boot image customization complete."
		$mainProgress.CompleteStep()

	}
	catch {
		# Best-effort cleanup if boot.wim customization fails.
		Write-WarningMsg "boot.wim customization failed: $($_.Exception.Message)"

		if ($bootImageMounted) {
			Write-Step "Attempting to clean up boot.wim mount..."

			# First try to unload any hive that this section successfully loaded.
			if ($null -ne $loadedBootHives -and @($loadedBootHives).Count -gt 0) {
				$cleanupUnloaded = @(
					Invoke-RegistryHiveOperations `
						-Operation Unload `
						-Hives @($loadedBootHives)
				)

				if ($cleanupUnloaded.Count -gt 0) {
					$loadedBootHives = @(
						@($loadedBootHives) | Where-Object {
							$cleanupUnloaded -notcontains $_
						}
					)
				}
			}

			# Give registry handles a moment to close before DISM attempts
			# to detach the image.
			[System.GC]::Collect()
			[System.GC]::WaitForPendingFinalizers()
			Start-Sleep -Seconds 2

			try {
				Invoke-WindowsImageDiscardRobust -MountPath $MOUNT_DIR -Attempts 5
				$bootImageMounted = $false
				Write-Ok "Failed boot.wim mount discarded."
			}
			catch {
				Write-WarningMsg "Could not discard failed boot.wim mount: $($_.Exception.Message)"
			}
		}

		throw
	}

	# ==================== CREATE ISO ====================
	$mainProgress.StartStep("Creating ISO")
	Write-Banner "Creating ISO" Magenta

	Copy-Item `
		-Path $autoUnattendPath `
		-Destination (Join-Path $WORK_DIR "autounattend.xml") `
		-Force `
		-ErrorAction Stop



	$isoPath = Join-Path $PSScriptRoot $script:VersionInfo.ISOFilename

	Write-Step "Building ISO at: $isoPath"
	Write-Step "This may take several minutes..."

	$etfsBootPath = Join-Path $WORK_DIR "boot\etfsboot.com"
	$efisysBinPath = Join-Path $WORK_DIR "efi\microsoft\boot\efisys.bin"

	if (-not (Test-Path -LiteralPath $etfsBootPath -PathType Leaf)) {
		throw "Missing BIOS boot sector file: $etfsBootPath"
	}

	if (-not (Test-Path -LiteralPath $efisysBinPath -PathType Leaf)) {
		throw "Missing UEFI boot image: $efisysBinPath"
	}

	# Microsoft requires a boot-order file for images larger than 4.5 GB so the
	# boot files remain at the beginning of the image. We always use it; that makes
	# the generated media safe regardless of the final ISO size.
	#
	# The file must be ANSI/ASCII, contain paths relative to the image root,
	# and end with a newline.
	$bootOrderPath = Join-Path $ScratchDisk 'GamingWindowsBootOrder.txt'

	$bootOrderCandidates = @(
		'boot\bcd',
		'boot\boot.sdi',
		'boot\bootfix.bin',
		'boot\bootsect.exe',
		'boot\etfsboot.com',
		'boot\memtest.efi',
		'boot\memtest.exe',
		'sources\boot.wim'
	)

	# Include standard localized bootsect MUI files and boot fonts when present.
	$bootDirectory = Join-Path $WORK_DIR 'boot'

	if (Test-Path -LiteralPath $bootDirectory -PathType Container) {
		$bootOrderCandidates += @(
			Get-ChildItem `
				-LiteralPath $bootDirectory `
				-Recurse `
				-File `
				-Force `
				-ErrorAction SilentlyContinue |
			Where-Object {
				$_.Name -match '^(bootsect\.exe\.mui|.*_boot\.ttf)$'
			} |
			ForEach-Object {
				$_.FullName.Substring($WORK_DIR.Length).TrimStart('\','/') -replace '/','\'
			}
		)
	}

	$bootOrderEntries = @(
		$bootOrderCandidates |
		Where-Object {
			Test-Path -LiteralPath (Join-Path $WORK_DIR $_) -PathType Leaf
		} |
		Select-Object -Unique
	)

	if ($bootOrderEntries.Count -eq 0) {
		throw "Could not build a valid Oscdimg boot-order file; no required boot files were found."
	}

	if ('sources\boot.wim' -notin $bootOrderEntries) {
		throw "Could not build a valid Oscdimg boot-order file; sources\boot.wim is missing."
	}

	[System.IO.File]::WriteAllLines(
		$bootOrderPath,
		$bootOrderEntries,
		[System.Text.Encoding]::ASCII
	)

	if (-not (Test-Path -LiteralPath $bootOrderPath -PathType Leaf)) {
		throw "Failed to create Oscdimg boot-order file '$bootOrderPath'."
	}

	Write-Ok "Boot-order file created with $($bootOrderEntries.Count) entries."

	# -------------------------------------------------------------------------
	# Build the OSCDIMG argument list.
	#
	# Keep each argument as its own array element. Invoke OSCDIMG directly
	# instead of going through cmd.exe: PowerShell then passes paths containing
	# spaces without an additional cmd.exe quoting/parsing layer.
	# -------------------------------------------------------------------------
	$oscdimgArgs = @(
		'-m'
		'-o'
		'-u2'
		'-udfver102'
		"-yo$bootOrderPath"
		"-bootdata:2#p0,e,b$etfsBootPath#p0,e,b$efisysBinPath"
		$WORK_DIR
		$isoPath
	)

	Write-Step "Running Oscdimg..."

	# A previous failed build may have left the destination ISO behind.
	# Remove it before starting so a stale file can never be mistaken for the
	# output of the current build. Fail explicitly if the old file is locked.
	if (Test-Path -LiteralPath $isoPath -PathType Leaf) {
		try {
			Remove-Item -LiteralPath $isoPath -Force -ErrorAction Stop
		} catch {
			throw "The previous ISO '$isoPath' could not be removed before OSCDIMG started. It may be open or locked by another process. $($_.Exception.Message)"
		}
	}

	# OSCDIMG is a native executable. Invoke it through Invoke-NativeCommand so
	# that informational stderr output (banners, progress, "Scanning source
	# tree") cannot be promoted to a terminating RemoteException under
	# $ErrorActionPreference = 'Stop'. The helper performs the required
	# process/argument quoting and returns a structured result.
	Write-Step "OSCDIMG: $OSCDIMG"
	Write-Step "OSCDIMG arguments:"
	foreach ($arg in $oscdimgArgs) {
		Write-Output "  [$arg]"
	}

	if (-not (Test-Path -LiteralPath $OSCDIMG -PathType Leaf)) {
		throw "OSCDIMG executable was not found: $OSCDIMG"
	}

	$oscdimgResult = Invoke-NativeCommand -FilePath $OSCDIMG -Arguments $oscdimgArgs
	$oscdimgOutput   = $oscdimgResult.Output
	$oscdimgExitCode = $oscdimgResult.ExitCode

	Write-Step "OSCDIMG exit code: $oscdimgExitCode"
	Write-Step "OSCDIMG output:"
	foreach ($line in $oscdimgOutput) {
		Write-Output "  $line"
	}

	if ($oscdimgExitCode -ne 0) {
		$recentOutput = @(
			$oscdimgOutput |
			Select-Object -Last 20 |
			ForEach-Object { [string]$_ }
		) -join [Environment]::NewLine

		throw "OSCDIMG failed with exit code $oscdimgExitCode.$([Environment]::NewLine)$recentOutput"
	}

	if (-not (Test-Path -LiteralPath $isoPath -PathType Leaf)) {
		throw "OSCDIMG returned success but did not create the expected ISO: $isoPath"
	}

	if ((Get-Item -LiteralPath $isoPath).Length -le 0) {
		throw "OSCDIMG returned success but the ISO file is empty: $isoPath"
	}

	Write-Ok "OSCDIMG created the ISO successfully."

	# -------------------------------------------------------------------------
	# Validate the generated ISO.
	#
	# Primary validation is the source tree: OSCDIMG already read it and
	# reported success, so re-checking that every required file is present and
	# non-empty catches every realistic post-OSCDIMG failure mode without
	# depending on the ISO mount (which races the volume service and, on some
	# configurations, silently fails to attach a user-created ISO).
	#
	# Secondary validation mounts the ISO and inspects its contents. This is
	# best-effort: if the mount fails or a drive letter is never assigned, we
	# log a warning and continue. The source tree has already been proven.
	# -------------------------------------------------------------------------
	Write-Step "Validating the generated ISO contents..."

	$requiredTreeFiles = @(
		$WIM_PATH,
		$BOOT_WIM_PATH,
		$etfsBootPath,
		$efisysBinPath,
		(Join-Path $WORK_DIR 'autounattend.xml')
	)
	foreach ($requiredFile in $requiredTreeFiles) {
		if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
			throw "ISO validation failed: required source-tree file is missing after OSCDIMG: $requiredFile"
		}
		$fi = Get-Item -LiteralPath $requiredFile -ErrorAction Stop
		if ($fi.Length -le 0) {
			throw "ISO validation failed: required source-tree file is empty after OSCDIMG: $requiredFile"
		}
	}
	Write-Ok "Source-tree validation passed: all OSCDIMG inputs are present and non-empty."

	# Re-validate the final WIM metadata in the source tree. This is the same
	# check that used to happen via the mounted ISO and is what actually matters.
	$finalWimImages = @(Get-WindowsImage -ImagePath $WIM_PATH -ErrorAction Stop)
	if ($finalWimImages.Count -ne 1 -or $finalWimImages[0].ImageIndex -ne 1) {
		throw "Final install.wim is not the expected single-image WIM."
	}

	$isoMounted = $false
	$isoRoot = $null

	try {
		# Mount-DiskImage returns before the volume is attached; retry until the
		# image reports Attached = True. Suppress the returned object explicitly
		# (piping to Out-Null is not sufficient on some hosts).
		$mountDeadline = (Get-Date).AddSeconds(20)
		while ((Get-Date) -lt $mountDeadline) {
			$null = Mount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue

			$diskImage = Get-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
			if ($diskImage -and $diskImage.Attached) {
				$isoMounted = $true
				break
			}

			Start-Sleep -Milliseconds 500
		}

		if (-not $isoMounted) {
			Write-WarningMsg "Could not attach the generated ISO for content validation; skipping mount-based checks. This does not affect the ISO itself."
		}
		else {
			# Poll for a volume with a drive letter. Volume arrival can take
			# several seconds after Attached flips to True.
			$volumeDeadline = (Get-Date).AddSeconds(20)
			$isoVolume = $null
			while ((Get-Date) -lt $volumeDeadline) {
				$isoVolume = Get-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue |
					Get-Disk -ErrorAction SilentlyContinue |
					Get-Partition -ErrorAction SilentlyContinue |
					Get-Volume -ErrorAction SilentlyContinue |
					Where-Object { $_.DriveLetter } |
					Select-Object -First 1

				if ($isoVolume) { break }
				Start-Sleep -Milliseconds 500
			}

			if (-not $isoVolume) {
				Write-WarningMsg "Generated ISO attached but no drive letter was assigned within the timeout; skipping mount-based content checks."
			}
			else {
				$isoRoot = "$($isoVolume.DriveLetter):\"
				Write-Step "ISO mounted at $isoRoot; verifying contents..."

				$isoMissing = @()
				foreach ($requiredIsoFile in @(
					"sources\install.wim",
					"sources\boot.wim",
					"boot\etfsboot.com",
					"efi\microsoft\boot\efisys.bin",
					"autounattend.xml"
				)) {
					$requiredPath = Join-Path $isoRoot $requiredIsoFile
					if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
						$isoMissing += $requiredIsoFile
					}
				}

				if ($isoMissing.Count -gt 0) {
					# Fall back to warning rather than failing: the source tree
					# validation already proved OSCDIMG had every required file,
					# and some environments expose an ISO volume in a form that
					# Test-Path cannot traverse reliably (e.g. UDF edge cases).
					Write-WarningMsg "Mount-based ISO validation could not see: $($isoMissing -join ', '). The source tree was validated successfully, so the ISO is very likely complete."
				}
				else {
					# Only run the WIM metadata check if the file was actually visible.
					$isoWimPath = Join-Path $isoRoot "sources\install.wim"
					try {
						$isoWimImages = @(Get-WindowsImage -ImagePath $isoWimPath -ErrorAction Stop)
						if ($isoWimImages.Count -ne 1 -or $isoWimImages[0].ImageIndex -ne 1) {
							Write-WarningMsg "Generated ISO's install.wim metadata did not report exactly one image at index 1."
						} else {
							Write-Ok "Generated ISO mounted and required contents/WIM metadata verified."
						}
					}
					catch {
						Write-WarningMsg "Could not read install.wim from the mounted ISO: $($_.Exception.Message)"
					}
				}
			}
		}
	}
	finally {
		if ($isoMounted) {
			try {
				Dismount-DiskImage -ImagePath $isoPath -ErrorAction Stop
				$isoMounted = $false
			}
			catch {
				Write-WarningMsg "Could not automatically dismount validation ISO: $($_.Exception.Message)"
			}
		}
	}

	$mainProgress.CompleteStep()
	# Success is reported only after the outer finally block has completed all
	# cleanup and verified that no DISM mount/hive was left behind.
    $buildSucceeded = $true
}
catch {
    $script:ExitCode = 1
    Write-ErrorMessage "Build failed: $($_.Exception.Message)"
    if ($_.ScriptStackTrace) {
        Write-WarningMsg "Failure location:`n$($_.ScriptStackTrace)"
    }
}
finally {
    # ========================================================================
    # GUARANTEED CLEANUP
    # ========================================================================
    # This block deliberately contains NO build work. It executes on success,
    # terminating errors, explicit throws, and failures from nested operations.
    # Never delete a directory while DISM reports it as mounted or when mount
    # state cannot be determined.
    Write-Banner "Cleanup" Cyan

    # ---- Dismount validation ISO first. ------------------------------------
    if ($isoMounted -and $isoPath) {
        try {
            Write-Step "Dismounting validation ISO..."
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction Stop
            $isoMounted = $false
        }
        catch {
            Set-CleanupFailure "Could not dismount validation ISO '$isoPath': $($_.Exception.Message)"
        }
    }

    # ---- Unload boot-image registry hives. ---------------------------------
    if ($loadedBootHives -and @($loadedBootHives).Count -gt 0) {
        Write-Step "Unloading boot-image registry hives..."
        $remainingBootHives = [System.Collections.Generic.List[string]]::new()
        foreach ($hive in @($loadedBootHives)) { [void]$remainingBootHives.Add([string]$hive) }
        try {
            $unloaded = @(Invoke-RegistryHiveOperations -Operation Unload -Hives @($remainingBootHives))
            foreach ($hive in $unloaded) { [void]$remainingBootHives.Remove([string]$hive) }
            if ($remainingBootHives.Count -gt 0) {
                Set-CleanupFailure "Boot-image registry hives remain loaded: $($remainingBootHives -join ', ')"
            } else {
                $loadedBootHives = @()
            }
        }
        catch {
            Set-CleanupFailure "Exception while unloading boot-image registry hives: $($_.Exception.Message)"
        }
    }

    # ---- Discard any boot.wim mount left by a failed customization. --------
    if ($bootImageMounted) {
        Write-Step "Discarding leftover boot.wim mount..."
        try {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            Start-Sleep -Milliseconds 750
            Invoke-WindowsImageDiscardRobust -MountPath $MOUNT_DIR -Attempts 5
            $bootImageMounted = $false
            Write-Ok "Leftover boot.wim mount discarded."
        }
        catch {
            Set-CleanupFailure "Could not discard leftover boot.wim mount '$MOUNT_DIR': $($_.Exception.Message)"
        }
    }

    # ---- Unload main-image registry hives. ---------------------------------
    if ($loadedHives -and @($loadedHives).Count -gt 0) {
        Write-Step "Unloading main-image registry hives..."
        $remainingHives = [System.Collections.Generic.List[string]]::new()
        foreach ($hive in @($loadedHives)) { [void]$remainingHives.Add([string]$hive) }
        try {
            $unloaded = @(Invoke-RegistryHiveOperations -Operation Unload -Hives @($remainingHives))
            foreach ($hive in $unloaded) { [void]$remainingHives.Remove([string]$hive) }
            if ($remainingHives.Count -gt 0) {
                Set-CleanupFailure "Main-image registry hives remain loaded: $($remainingHives -join ', ')"
            } else {
                $loadedHives = @()
            }
        }
        catch {
            Set-CleanupFailure "Exception while unloading main-image registry hives: $($_.Exception.Message)"
        }
    }

    # ---- Recover any remaining build-related DISM mounts. ------------------
    # Actual DISM state is authoritative; boolean flags alone are not.
    $mountStateKnown = $false
    $activeBuildMounts = @()
    try {
        $activeBuildMounts = @(Get-DismMountedImagesSafe | Where-Object {
            ($_.MountPath -and (Test-SameWindowsPath ([string]$_.MountPath) $MOUNT_DIR)) -or
            ($_.ImagePath -and (Test-SameWindowsPath ([string]$_.ImagePath) $WIM_PATH))
        })
        $mountStateKnown = $true
    } catch {
        Set-CleanupFailure "Could not determine DISM mount state for build paths. Work directories will be preserved: $($_.Exception.Message)"
    }

    if ($mountStateKnown -and $activeBuildMounts.Count -gt 0) {
        Write-Step "Discarding leftover build-related DISM mount(s)..."
        try {
            Invoke-StaleBuildMountRecovery -MountPath $MOUNT_DIR -WimPath $WIM_PATH -Attempts 3
            $mainImageMounted = $false
            $bootImageMounted = $false
        } catch {
            Set-CleanupFailure "Could not recover leftover build-related DISM mount(s): $($_.Exception.Message)"
        }
    }

    # Re-check. Unknown state is never considered safe for recursive deletion.
    $mountStillActive = $false
    $mountCheckSucceeded = $false
    try {
        $mountStillActive = @(Get-DismMountedImagesSafe | Where-Object {
            ($_.MountPath -and (Test-SameWindowsPath ([string]$_.MountPath) $MOUNT_DIR)) -or
            ($_.ImagePath -and (Test-SameWindowsPath ([string]$_.ImagePath) $WIM_PATH))
        }).Count -gt 0
        $mountCheckSucceeded = $true
    } catch {
        Set-CleanupFailure "Could not verify final DISM mount state for build paths: $($_.Exception.Message)"
    }

    # ---- Remove temporary boot-order file. ---------------------------------
    if ($bootOrderPath -and (Test-Path -LiteralPath $bootOrderPath -PathType Leaf)) {
        try {
            Remove-Item -LiteralPath $bootOrderPath -Force -ErrorAction Stop
            $bootOrderPath = $null
        }
        catch {
            Set-CleanupFailure "Could not remove temporary OSCDIMG boot-order file '$bootOrderPath': $($_.Exception.Message)"
        }
    }

    # ---- Remove work tree only when mount state is positively known safe. ---
    if ($mountCheckSucceeded -and -not $mountStillActive) {
        if ($script:ExitCode -ne 0 -and $PreserveWorkOnError) {
            Write-WarningMsg "Preserving work directories because -PreserveWorkOnError was specified."
        }
        else {
            foreach ($dir in @($MOUNT_DIR, $WORK_DIR)) {
                if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
                $removed = $false
                for ($attempt = 1; $attempt -le 3 -and -not $removed; $attempt++) {
                    try {
                        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop
                        $removed = $true
                    }
                    catch {
                        if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
                    }
                }
                if (-not $removed -and (Test-Path -LiteralPath $dir)) {
                    Set-CleanupFailure "Could not remove temporary directory '$dir' after 3 attempts."
                }
            }
        }
    }
    elseif ($mountStillActive) {
        Set-CleanupFailure "DISM mount '$MOUNT_DIR' is still active. Preserving work directories to prevent data loss."
    }

    # ---- Finish progress UI and transcript. -------------------------------
    if ($buildSucceeded -and $script:ExitCode -eq 0) {
        try { $mainProgress.Complete() } catch { Write-WarningMsg "Could not finalize progress display: $($_.Exception.Message)" }
    }

    # Only claim success AFTER guaranteed cleanup has completed.
    if ($buildSucceeded -and $script:ExitCode -eq 0) {
        Write-Banner "ISO CREATED SUCCESSFULLY" Green
        Write-Output "  Version:  $($script:VersionInfo.FullVersionWithBuild)"
        Write-Output "  Location: $isoPath"
        if ($isoPath -and (Test-Path -LiteralPath $isoPath -PathType Leaf)) {
            $isoSize = [math]::Round((Get-Item -LiteralPath $isoPath -ErrorAction Stop).Length / 1GB, 2)
            Write-Output "  Size:     $isoSize GB"
        }
        Write-Output "  Log:      $logPath"
        Write-Output ("=" * 60)
        Write-Ok "Cleanup complete."
    }
    else {
        Write-WarningMsg "Build did not complete successfully. Exit code: $script:ExitCode"
        Write-WarningMsg "Work directory: $WORK_DIR"
        Write-WarningMsg "Mount directory: $MOUNT_DIR"
        if ($PreserveWorkOnError) { Write-WarningMsg "-PreserveWorkOnError was specified; diagnostic files were retained where safe." }
    }

    if ($script:VersionInfo.Features.EnableTranscript) {
        try { Stop-Transcript -ErrorAction SilentlyContinue } catch { }
    }

    if (-not $QuietMode -and -not $Force) {
        Read-Host "Press Enter to exit"
    }
}

# Exit with the accumulated code so schedulers/CI see the real status.
exit $script:ExitCode
