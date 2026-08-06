[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$ListenPort = 2222,
    [ValidateRange(1, 65535)]
    [int]$TargetPort = 22,
    [ValidateNotNullOrEmpty()]
    [string]$Distro = 'Ubuntu',
    [switch]$Disable,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$firewallPrefix = 'WSL SSH (LAN TCP '
$taskName = "Start WSL $Distro SSH at logon"
$statePath = Join-Path $PSScriptRoot 'server-state.json'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated Windows PowerShell session.'
}

$previousPort = $null
if (Test-Path -LiteralPath $statePath) {
    try {
        $previousState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($previousState.listenPort) { $previousPort = [int]$previousState.listenPort }
    } catch {
        Write-Warning 'Ignoring an unreadable previous state file.'
    }
}

foreach ($port in @($previousPort, $ListenPort) | Where-Object { $_ } | Select-Object -Unique) {
    & netsh.exe interface portproxy delete v4tov4 `
        listenaddress=0.0.0.0 listenport=$port 2>$null | Out-Null
}
Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object DisplayName -Like "$firewallPrefix*" |
    Remove-NetFirewallRule

if ($Disable -or $Remove) {
    if ($Remove) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        Write-Host 'Removed LAN forwarding, firewall rule, startup task, and state.'
    } else {
        [ordered]@{ enabled = $false; distro = $Distro; updatedAt = (Get-Date).ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
        Write-Host 'Disabled WSL SSH LAN forwarding and firewall access.'
    }
    exit 0
}

$distroNames = @(& wsl.exe --list --quiet) -replace "`0", '' | ForEach-Object { $_.Trim() }
if ($Distro -notin $distroNames) { throw "WSL distribution not found: $Distro" }
$existingListener = Get-NetTCPConnection -State Listen -LocalPort $ListenPort -ErrorAction SilentlyContinue
if ($existingListener) { throw "TCP port $ListenPort is already in use." }

Set-Service -Name iphlpsvc -StartupType Automatic
Start-Service -Name iphlpsvc
& netsh.exe interface portproxy add v4tov4 `
    listenaddress=0.0.0.0 listenport=$ListenPort `
    connectaddress=127.0.0.1 connectport=$TargetPort
if ($LASTEXITCODE -ne 0) { throw 'Failed to create the Windows port proxy.' }

$firewallName = "$firewallPrefix$ListenPort)"
New-NetFirewallRule -DisplayName $firewallName -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort $ListenPort -Profile Private -RemoteAddress LocalSubnet | Out-Null

$wslPath = Join-Path $env:SystemRoot 'System32\wsl.exe'
$action = New-ScheduledTaskAction -Execute $wslPath -Argument "-d `"$Distro`" --exec /bin/true"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $taskPrincipal -Force | Out-Null

[ordered]@{
    enabled = $true
    distro = $Distro
    listenPort = $ListenPort
    targetPort = $TargetPort
    firewallName = $firewallName
    taskName = $taskName
    updatedAt = (Get-Date).ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

& $wslPath -d $Distro --exec /bin/true
Write-Host "Configured LAN SSH on Windows TCP port $ListenPort."
Write-Host 'Firewall scope: Private profiles and LocalSubnet only.'
Write-Host "Rollback: & '$PSCommandPath' -Distro '$Distro' -ListenPort $ListenPort -Remove"

