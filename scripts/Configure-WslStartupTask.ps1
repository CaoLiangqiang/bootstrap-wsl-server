[CmdletBinding(DefaultParameterSetName = 'Configure')]
param(
    [Parameter(ParameterSetName = 'Configure')]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$')]
    [string]$Distro = 'Ubuntu',

    [Parameter(ParameterSetName = 'Configure')]
    [ValidateRange(0, 3600)]
    [int]$DelaySeconds = 30,

    [Parameter(ParameterSetName = 'Status', Mandatory)]
    [switch]$Status,

    [Parameter(ParameterSetName = 'Remove', Mandatory)]
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$statePath = Join-Path $PSScriptRoot 'startup-task-state.json'
$stateOwner = 'bootstrap-wsl-server:startup-task'
$cmdPath = Join-Path $env:SystemRoot 'System32\cmd.exe'
$wslPath = Join-Path $env:SystemRoot 'System32\wsl.exe'

function Read-ManagedState {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    } catch {
        throw 'The managed startup-task state file is unreadable.'
    }
    $stateDistro = [string]$state.distro
    if ([string]$state.owner -ne $stateOwner -or [int]$state.schemaVersion -ne 1 -or
        $stateDistro -notmatch '^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$' -or
        [string]$state.taskName -ne "Start WSL $stateDistro services at startup" -or
        [int]$state.delaySeconds -lt 0 -or [int]$state.delaySeconds -gt 3600 -or
        [string]$state.delayIso8601 -ne "PT$([int]$state.delaySeconds)S" -or
        [string]::IsNullOrWhiteSpace([string]$state.userId) -or
        [string]::IsNullOrWhiteSpace([string]$state.userSid) -or
        [string]::IsNullOrWhiteSpace([string]$state.arguments)) {
        throw 'The managed startup-task state failed its ownership check.'
    }
    return $state
}

function Get-TaskStatus([object]$State) {
    if (-not $State) {
        return [ordered]@{ managed = $false; task = 'Unknown' }
    }
    $task = Get-ScheduledTask -TaskName $State.taskName -ErrorAction SilentlyContinue
    if (-not $task) {
        return [ordered]@{ managed = $true; taskName = $State.taskName; task = 'Absent' }
    }
    $actions = @($task.Actions)
    $triggers = @($task.Triggers)
    $exact = $actions.Count -eq 1 -and $triggers.Count -eq 1 -and
        $actions[0].Execute -eq $cmdPath -and
        $actions[0].Arguments -eq [string]$State.arguments -and
        $triggers[0].CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' -and
        $triggers[0].Enabled -eq $true -and
        [string]$triggers[0].Delay -eq [string]$State.delayIso8601 -and
        $task.Principal.UserId -eq [string]$State.userId -and
        $task.Principal.LogonType -eq 'S4U' -and
        $task.Principal.RunLevel -eq 'Limited' -and
        $task.Settings.Enabled -eq $true -and
        $task.Settings.MultipleInstances -eq 'IgnoreNew' -and
        $task.Settings.StartWhenAvailable -eq $true -and
        $task.Settings.DisallowStartIfOnBatteries -eq $false -and
        $task.Settings.StopIfGoingOnBatteries -eq $false -and
        [string]$task.Settings.ExecutionTimeLimit -eq 'PT2M' -and
        [int]$task.Settings.RestartCount -eq 3 -and
        [string]$task.Settings.RestartInterval -eq 'PT1M'
    return [ordered]@{
        managed = $true
        taskName = $State.taskName
        task = if ($exact) { 'Exact' } else { 'Drifted' }
        runtimeState = $task.State.ToString()
    }
}

$state = Read-ManagedState
if ($Status) {
    Get-TaskStatus -State $state | ConvertTo-Json
    exit 0
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated Windows PowerShell session.'
}

if ($Remove) {
    if (-not $state) {
        Write-Host 'No managed WSL startup task state was found.'
        exit 0
    }
    $current = Get-TaskStatus -State $state
    if ($current.task -eq 'Drifted') {
        throw 'Managed startup task has drifted; no task or state was removed.'
    }
    if ($current.task -eq 'Exact') {
        Unregister-ScheduledTask -TaskName $state.taskName -Confirm:$false -ErrorAction Stop
    }
    if (Get-ScheduledTask -TaskName $state.taskName -ErrorAction SilentlyContinue) {
        throw 'The managed startup task was not fully removed; state was preserved.'
    }
    Remove-Item -LiteralPath $statePath -Force
    Write-Host "Removed managed startup task '$($state.taskName)'."
    Write-Host 'Existing interactive-logon fallback tasks were not changed.'
    exit 0
}

$distroNames = @(& $wslPath --list --quiet) -replace "`0", '' |
    ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($LASTEXITCODE -ne 0) { throw 'Failed to enumerate WSL distributions.' }
if ($Distro -notin $distroNames) { throw "WSL distribution not found: $Distro" }

$taskName = "Start WSL $Distro services at startup"
$logDirectory = Join-Path $PSScriptRoot 'logs'
$logPath = Join-Path $logDirectory 'startup-task.log'
$delayIso8601 = "PT${DelaySeconds}S"
$arguments = "/d /s /c `"`"$wslPath`" -d `"$Distro`" --exec /bin/true > `"$logPath`" 2>&1`""
$userId = $identity.Name
$userSid = $identity.User.Value

if ($state) {
    if ($state.taskName -ne $taskName -or $state.distro -ne $Distro -or
        [int]$state.delaySeconds -ne $DelaySeconds -or
        $state.userSid -ne $userSid -or
        $state.arguments -ne $arguments) {
        throw 'Startup-task parameters differ from managed state. Run -Remove before changing them.'
    }
    $current = Get-TaskStatus -State $state
    if ($current.task -eq 'Exact') {
        Write-Host "WSL startup task '$taskName' is already configured."
        exit 0
    }
    throw 'Managed startup task is absent or drifted; no state was changed. Run -Remove first.'
}

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    throw "Scheduled task '$taskName' already exists without managed ownership state."
}

$logDirectoryCreated = $false
$taskCreated = $false
$temporaryState = "$statePath.tmp"
try {
    if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $logDirectory | Out-Null
        $logDirectoryCreated = $true
    }

    $action = New-ScheduledTaskAction -Execute $cmdPath -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = $delayIso8601
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -StartWhenAvailable -MultipleInstances IgnoreNew
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId $userId `
        -LogonType S4U -RunLevel Limited

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $taskPrincipal -Force | Out-Null
    $taskCreated = $true
    $registeredTask = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $registeredUserId = [string]$registeredTask.Principal.UserId

    $prospectiveState = [pscustomobject]@{
        taskName = $taskName
        arguments = $arguments
        delayIso8601 = $delayIso8601
        userId = $registeredUserId
    }
    if ((Get-TaskStatus -State $prospectiveState).task -ne 'Exact') {
        throw 'The startup task did not pass post-install ownership verification.'
    }

    [ordered]@{
        owner = $stateOwner
        schemaVersion = 1
        taskName = $taskName
        distro = $Distro
        delaySeconds = $DelaySeconds
        delayIso8601 = $delayIso8601
        userId = $registeredUserId
        userSid = $userSid
        arguments = $arguments
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $temporaryState -Encoding UTF8
    Move-Item -LiteralPath $temporaryState -Destination $statePath -Force
} catch {
    $originalError = $_
    $rollbackWarnings = @()
    if ($taskCreated) {
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false `
                -ErrorAction Stop
        } catch {
            $rollbackWarnings += 'failed to remove the created startup task'
        }
    }
    try {
        Remove-Item -LiteralPath $temporaryState -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
    } catch {
        $rollbackWarnings += 'failed to remove the temporary state file'
    }
    if ($logDirectoryCreated) {
        try {
            Remove-Item -LiteralPath $logDirectory -ErrorAction Stop
        } catch {
            $rollbackWarnings += 'failed to remove the created log directory'
        }
    }

    $remainingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($remainingTask) {
        try {
            [ordered]@{
                owner = $stateOwner
                schemaVersion = 1
                taskName = $taskName
                distro = $Distro
                delaySeconds = $DelaySeconds
                delayIso8601 = $delayIso8601
                userId = [string]$remainingTask.Principal.UserId
                userSid = $userSid
                arguments = $arguments
                recovery = $true
                updatedAt = (Get-Date).ToString('o')
            } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
        } catch {
            $rollbackWarnings += 'failed to preserve recovery ownership state'
        }
        $rollbackWarnings += 'the created startup task remains registered'
    }
    foreach ($warning in $rollbackWarnings) {
        Write-Warning $warning
    }
    if ($remainingTask) {
        throw [InvalidOperationException]::new(
            "Startup-task installation failed and rollback was incomplete. $($originalError.Exception.Message)",
            $originalError.Exception)
    }
    throw $originalError
}

Write-Host "Configured startup task '$taskName' with a $DelaySeconds-second delay."
Write-Host 'The task uses AtStartup, S4U, Limited, and a cmd.exe wrapper.'
Write-Host 'Existing interactive-logon fallback tasks were not changed.'
