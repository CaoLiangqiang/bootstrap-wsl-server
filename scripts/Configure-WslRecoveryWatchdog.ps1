[CmdletBinding(DefaultParameterSetName = 'Configure')]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._ -]{0,63}$')]
    [string]$Distro = 'Ubuntu',

    [Parameter(ParameterSetName = 'Configure')]
    [ValidateRange(1, 1440)]
    [int]$IntervalMinutes = 12,

    [Parameter(ParameterSetName = 'Configure')]
    [ValidateNotNullOrEmpty()]
    [string]$ListenPorts = '2222,443,8080',

    [Parameter(ParameterSetName = 'Configure')]
    [ValidateNotNullOrEmpty()]
    [string]$UserServices = 'can-e2e-verifier.service,webui-gateway.service,wsl-server-workbench.service',

    [Parameter(ParameterSetName = 'Status', Mandatory)]
    [switch]$Status,

    [Parameter(ParameterSetName = 'Remove', Mandatory)]
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$taskName = "WSL $Distro recovery watchdog"
$statePath = Join-Path $PSScriptRoot 'recovery-watchdog-state.json'
$stateOwner = 'bootstrap-wsl-server:recovery-watchdog'
$psPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$wslPath = Join-Path $env:SystemRoot 'System32\wsl.exe'

function Read-State {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
    catch { throw 'The recovery watchdog state file is unreadable.' }
    if ([string]$state.owner -ne $stateOwner -or [int]$state.schemaVersion -ne 1 -or
        [string]$state.taskName -ne $taskName -or [int]$state.intervalMinutes -lt 1 -or
        [string]::IsNullOrWhiteSpace([string]$state.ports) -or
        [string]::IsNullOrWhiteSpace([string]$state.userServices) -or
        [string]::IsNullOrWhiteSpace([string]$state.userId)) {
        throw 'The recovery watchdog state failed its ownership check.'
    }
    return $state
}

function Get-Status([object]$State) {
    if (-not $State) { return [ordered]@{ managed = $false; task = 'Unknown' } }
    $task = Get-ScheduledTask -TaskName $State.taskName -ErrorAction SilentlyContinue
    if (-not $task) { return [ordered]@{ managed = $true; taskName = $State.taskName; task = 'Absent' } }
    [ordered]@{
        managed = $true
        taskName = $State.taskName
        task = $task.State.ToString()
        enabled = $task.Settings.Enabled
        trigger = ($task.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ','
        intervalMinutes = $State.intervalMinutes
        registeredInterval = [string]$task.Triggers[0].Repetition.Interval
        ports = $State.ports
        userServices = $State.userServices
        lastResult = (Get-ScheduledTaskInfo -TaskName $State.taskName).LastTaskResult
    }
}

$state = Read-State
if ($Status) { Get-Status $state | ConvertTo-Json; exit 0 }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated Windows PowerShell session.'
}

if ($Remove) {
    if (-not $state) { Write-Host 'No managed recovery watchdog was found.'; exit 0 }
    $task = Get-ScheduledTask -TaskName $state.taskName -ErrorAction SilentlyContinue
    if ($task) { Unregister-ScheduledTask -TaskName $state.taskName -Confirm:$false -ErrorAction Stop }
    if (Get-ScheduledTask -TaskName $state.taskName -ErrorAction SilentlyContinue) {
        throw 'The recovery watchdog task was not removed; state was preserved.'
    }
    Remove-Item -LiteralPath $statePath -Force
    Write-Host "Removed recovery watchdog '$($state.taskName)'."
    exit 0
}

$ports = @($ListenPorts -split ',' | ForEach-Object {
    $value = 0
    if (-not [int]::TryParse($_.Trim(), [ref]$value) -or $value -lt 1 -or $value -gt 65535) {
        throw "Invalid recovery watchdog port: $_"
    }
    $value
})
if ($ports.Count -eq 0 -or $ports.Count -gt 8 -or $ports -contains 4173) {
    throw 'Recovery watchdog ports must be 1-8 valid ports and cannot include 4173.'
}
$portText = ($ports | Sort-Object -Unique) -join ','
$services = @($UserServices -split ',' | ForEach-Object {
    $value = $_.Trim()
    if ($value -notmatch '^[A-Za-z0-9][A-Za-z0-9_.@-]{0,127}\.service$') {
        throw "Invalid systemd user service: $_"
    }
    $value
})
if ($services.Count -eq 0 -or $services.Count -gt 16) {
    throw 'Recovery watchdog user services must contain 1-16 valid .service unit names.'
}
$serviceText = ($services | Sort-Object -Unique) -join ','
$userId = $identity.Name
$checkScript = @"
`$ports = @('$portText' -split ',')
`$services = @('$serviceText' -split ',')
# Touch the distro on every run. A Windows portproxy can keep its listener
# open after the WSL backend stops, so a TCP-only probe is not sufficient to
# wake the distro reliably.
& '$wslPath' -d '$Distro' --exec /bin/true | Out-Null
`$failed = (`$LASTEXITCODE -ne 0)
if (-not `$failed) {
  & '$wslPath' -d '$Distro' --exec systemctl --user start `$services | Out-Null
  `$failed = (`$LASTEXITCODE -ne 0)
}
foreach (`$port in `$ports) {
  `$c = `$null
  try { `$c = [Net.Sockets.TcpClient]::new(); `$c.Connect('127.0.0.1', [int]`$port) }
  catch { `$failed = `$true }
  finally { if (`$c) { `$c.Dispose() } }
}
if (`$failed) { & '$wslPath' -d '$Distro' --exec /bin/true | Out-Null }
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($checkScript))

if ($state) {
    if ([int]$state.intervalMinutes -ne $IntervalMinutes -or [string]$state.ports -ne $portText -or
        [string]$state.userServices -ne $serviceText) {
        throw 'Recovery watchdog parameters differ from managed state. Run -Remove first.'
    }
    $current = Get-Status $state
    $expectedInterval = "PT$($state.intervalMinutes)M"
    if ($current.task -in @('Ready', 'Running') -and $current.enabled -eq $true -and
        $current.registeredInterval -eq $expectedInterval) {
        Write-Host "Recovery watchdog '$taskName' is already configured."
        exit 0
    }
    throw 'Managed recovery watchdog is absent or drifted; run -Remove first.'
}
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    throw "Scheduled task '$taskName' already exists without managed ownership state."
}

$action = New-ScheduledTaskAction -Execute $psPath -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $taskPrincipal | Out-Null
try {
    $registered = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if ($registered.Principal.LogonType -ne 'S4U' -or $registered.Principal.RunLevel -ne 'Limited' -or
        $registered.Settings.Enabled -ne $true -or $registered.Triggers.Count -ne 1 -or
        [string]$registered.Triggers[0].Repetition.Interval -ne "PT${IntervalMinutes}M") {
        throw 'Recovery watchdog failed post-install verification.'
    }
    [ordered]@{
        owner = $stateOwner
        schemaVersion = 1
        taskName = $taskName
        distro = $Distro
        intervalMinutes = $IntervalMinutes
        ports = $portText
        userServices = $serviceText
        userId = [string]$registered.Principal.UserId
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath "$statePath.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$statePath.tmp" -Destination $statePath -Force
} catch {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$statePath.tmp" -Force -ErrorAction SilentlyContinue
    throw
}
Write-Host "Configured '$taskName' to check every $IntervalMinutes minutes."
