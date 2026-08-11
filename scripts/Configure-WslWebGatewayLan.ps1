[CmdletBinding(DefaultParameterSetName = 'Configure')]
param(
    [Parameter(ParameterSetName = 'Configure')]
    [ValidateRange(1, 65535)]
    [int]$ListenPort = 443,

    [Parameter(ParameterSetName = 'Configure')]
    [ValidateRange(1, 65535)]
    [int]$TargetPort = 8443,

    [Parameter(ParameterSetName = 'Configure')]
    [ValidateNotNullOrEmpty()]
    [string]$AllowedRemoteAddress = 'LocalSubnet',

    [Parameter(ParameterSetName = 'Status', Mandatory)]
    [switch]$Status,

    [Parameter(ParameterSetName = 'Remove', Mandatory)]
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$statePath = Join-Path $PSScriptRoot 'web-gateway-state.json'
$stateOwner = 'bootstrap-wsl-server:web-gateway'
$forbiddenPorts = @(2222, 4173)

function Get-PortProxyEntries([int]$Port) {
    $lines = @(& netsh.exe interface portproxy show v4tov4)
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to inspect Windows port proxy state.'
    }
    foreach ($line in (($lines | Out-String) -split "`r?`n")) {
        if ($line -match '^\s*(\S+)\s+(\d+)\s+(\S+)\s+(\d+)\s*$' -and
            [int]$Matches[2] -eq $Port) {
            [pscustomobject]@{
                ListenAddress = $Matches[1]
                ListenPort = [int]$Matches[2]
                ConnectAddress = $Matches[3]
                ConnectPort = [int]$Matches[4]
            }
        }
    }
}

function Get-ProxyStatus([int]$Port, [int]$ConnectPort) {
    $entries = @(Get-PortProxyEntries -Port $Port)
    if ($entries.Count -eq 0) { return 'Absent' }
    if ($entries.Count -eq 1 -and
        $entries[0].ListenAddress -eq '0.0.0.0' -and
        $entries[0].ConnectAddress -eq '127.0.0.1' -and
        $entries[0].ConnectPort -eq $ConnectPort) {
        return 'Exact'
    }
    return 'Drifted'
}

function Get-FirewallStatus([string]$Name, [int]$Port, [string]$RemoteAddress) {
    $rules = @(Get-NetFirewallRule -ErrorAction Stop |
        Where-Object DisplayName -eq $Name)
    if ($rules.Count -eq 0) { return 'Absent' }
    if ($rules.Count -ne 1) { return 'Drifted' }

    $addresses = @($rules | Get-NetFirewallAddressFilter -ErrorAction Stop)
    $ports = @($rules | Get-NetFirewallPortFilter -ErrorAction Stop)
    $applications = @($rules | Get-NetFirewallApplicationFilter -ErrorAction Stop)
    $services = @($rules | Get-NetFirewallServiceFilter -ErrorAction Stop)
    $interfaces = @($rules | Get-NetFirewallInterfaceFilter -ErrorAction Stop)
    $interfaceTypes = @($rules | Get-NetFirewallInterfaceTypeFilter -ErrorAction Stop)
    if ($addresses.Count -eq 1 -and $ports.Count -eq 1 -and
        $applications.Count -eq 1 -and $services.Count -eq 1 -and
        $interfaces.Count -eq 1 -and $interfaceTypes.Count -eq 1 -and
        $rules[0].Enabled -eq 'True' -and
        $rules[0].Direction -eq 'Inbound' -and
        $rules[0].Action -eq 'Allow' -and
        $rules[0].Profile -eq 'Private' -and
        $rules[0].EdgeTraversalPolicy -eq 'Block' -and
        @($addresses[0].LocalAddress).Count -eq 1 -and
        $addresses[0].LocalAddress -eq 'Any' -and
        @($addresses[0].RemoteAddress).Count -eq 1 -and
        $addresses[0].RemoteAddress -eq $RemoteAddress -and
        $ports[0].Protocol -eq 'TCP' -and
        @($ports[0].LocalPort).Count -eq 1 -and
        $ports[0].LocalPort -eq [string]$Port -and
        @($ports[0].RemotePort).Count -eq 1 -and
        $ports[0].RemotePort -eq 'Any' -and
        $applications[0].Program -eq 'Any' -and
        $services[0].Service -eq 'Any' -and
        @($interfaces[0].InterfaceAlias).Count -eq 1 -and
        $interfaces[0].InterfaceAlias -eq 'Any' -and
        $interfaceTypes[0].InterfaceType -in @('Any', 0)) {
        return 'Exact'
    }
    return 'Drifted'
}

function Test-PortFilterCovers([object]$Filter, [int]$Port) {
    if ($Filter.Protocol -notin @('TCP', '6', 'Any', '256')) { return $false }
    foreach ($value in @($Filter.LocalPort)) {
        if ($value -eq 'Any' -or $value -eq [string]$Port) { return $true }
        if ($value -match '^(\d+)-(\d+)$' -and
            $Port -ge [int]$Matches[1] -and $Port -le [int]$Matches[2]) {
            return $true
        }
    }
    return $false
}

function Test-ProgramMayCoverPortProxy([string]$Program) {
    if ($Program -in @('Any', 'System')) { return $true }
    $expanded = [Environment]::ExpandEnvironmentVariables($Program)
    return [IO.Path]::GetFileName($expanded) -ieq 'svchost.exe'
}

function Get-ConflictingFirewallRules([string]$ManagedName, [int]$Port) {
    $portById = @{}
    $applicationById = @{}
    $serviceById = @{}
    foreach ($filter in @(Get-NetFirewallPortFilter -ErrorAction Stop)) {
        $portById[$filter.InstanceID] = $filter
    }
    foreach ($filter in @(Get-NetFirewallApplicationFilter -ErrorAction Stop)) {
        $applicationById[$filter.InstanceID] = $filter
    }
    foreach ($filter in @(Get-NetFirewallServiceFilter -ErrorAction Stop)) {
        $serviceById[$filter.InstanceID] = $filter
    }
    foreach ($rule in @(Get-NetFirewallRule -Enabled True -Direction Inbound `
        -Action Allow -ErrorAction Stop)) {
        if ($rule.DisplayName -eq $ManagedName) { continue }
        $applicationFilter = $applicationById[$rule.InstanceID]
        $serviceFilter = $serviceById[$rule.InstanceID]
        $portFilter = $portById[$rule.InstanceID]
        if (-not $applicationFilter -or -not $serviceFilter -or -not $portFilter) {
            throw "Cannot resolve firewall filters for enabled rule '$($rule.DisplayName)'."
        }
        if (-not (Test-ProgramMayCoverPortProxy -Program ([string]$applicationFilter.Program)) -or
            $serviceFilter.Service -notin @('Any', 'iphlpsvc')) {
            continue
        }
        if (Test-PortFilterCovers -Filter $portFilter -Port $Port) { $rule }
    }
}

function Test-AllowedRemoteAddress([string]$Address) {
    if ($Address -eq 'LocalSubnet') { return $true }
    if ($Address -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$') { return $false }

    $parsed = [System.Net.IPAddress]::None
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed) -or
        $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }
    $bytes = $parsed.GetAddressBytes()
    if (($bytes | Where-Object { $_ -gt 255 }).Count -ne 0 -or
        $bytes[0] -eq 0 -or $bytes[0] -eq 127 -or $bytes[0] -ge 224) {
        return $false
    }
    return $true
}

function Read-ManagedState {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    } catch {
        throw 'The managed gateway state file is unreadable.'
    }
    if ([string]$state.owner -ne $stateOwner -or [int]$state.schemaVersion -ne 1 -or
        [int]$state.listenPort -lt 1 -or [int]$state.listenPort -gt 65535 -or
        [int]$state.targetPort -lt 1 -or [int]$state.targetPort -gt 65535 -or
        $forbiddenPorts -contains [int]$state.listenPort -or
        $forbiddenPorts -contains [int]$state.targetPort -or
        [string]$state.firewallName -ne
        "WSL WebUI Gateway (HTTPS TCP $([int]$state.listenPort))" -or
        -not (Test-AllowedRemoteAddress -Address ([string]$state.allowedRemoteAddress))) {
        throw 'The managed gateway state failed its ownership check.'
    }
    return $state
}

function Get-ManagedStatus([object]$State) {
    if (-not $State) {
        return [ordered]@{ managed = $false; proxy = 'Unknown'; firewall = 'Unknown' }
    }
    $managedPort = [int]$State.listenPort
    $managedTarget = [int]$State.targetPort
    $managedRemote = [string]$State.allowedRemoteAddress
    $managedFirewallName = [string]$State.firewallName
    return [ordered]@{
        managed = $true
        listenPort = $managedPort
        targetPort = $managedTarget
        allowedRemoteAddress = $managedRemote
        proxy = Get-ProxyStatus -Port $managedPort -ConnectPort $managedTarget
        firewall = Get-FirewallStatus -Name $managedFirewallName -Port $managedPort `
            -RemoteAddress $managedRemote
    }
}

$state = Read-ManagedState
if ($Status) {
    Get-ManagedStatus -State $state | ConvertTo-Json
    exit 0
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated Windows PowerShell session.'
}

if ($Remove) {
    if (-not $state) {
        Write-Host 'No managed WSL WebUI gateway LAN state was found.'
        exit 0
    }
    $current = Get-ManagedStatus -State $state
    if ('Drifted' -in @($current.proxy, $current.firewall)) {
        throw 'Managed gateway state has drifted; no state was removed.'
    }
    if ($current.proxy -eq 'Exact') {
        & netsh.exe interface portproxy delete v4tov4 `
            listenaddress=0.0.0.0 listenport=$current.listenPort | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Failed to remove the gateway port proxy.' }
    }
    if ($current.firewall -eq 'Exact') {
        Get-NetFirewallRule -DisplayName $state.firewallName -ErrorAction Stop |
            Remove-NetFirewallRule -ErrorAction Stop
    }
    $after = Get-ManagedStatus -State $state
    if ($after.proxy -ne 'Absent' -or $after.firewall -ne 'Absent') {
        throw 'Gateway LAN objects were not fully removed; state was preserved.'
    }
    Remove-Item -LiteralPath $statePath -Force
    Write-Host "Removed managed HTTPS gateway access on TCP $($current.listenPort)."
    exit 0
}

if ($forbiddenPorts -contains $ListenPort -or $forbiddenPorts -contains $TargetPort) {
    throw 'Ports 2222 and 4173 are reserved and cannot be gateway listen or target ports.'
}
if ($ListenPort -eq $TargetPort) {
    throw 'ListenPort and TargetPort must be different.'
}
if (-not (Test-AllowedRemoteAddress -Address $AllowedRemoteAddress)) {
    throw 'AllowedRemoteAddress must be LocalSubnet or one non-loopback IPv4 unicast address.'
}

$firewallName = "WSL WebUI Gateway (HTTPS TCP $ListenPort)"
if ($state) {
    if ($ListenPort -ne [int]$state.listenPort -or
        $TargetPort -ne [int]$state.targetPort -or
        $AllowedRemoteAddress -ne [string]$state.allowedRemoteAddress) {
        throw 'Gateway parameters differ from managed state. Run -Remove before changing them.'
    }
    $current = Get-ManagedStatus -State $state
    if ($current.proxy -eq 'Exact' -and $current.firewall -eq 'Exact') {
        Write-Host "WSL WebUI HTTPS gateway is already configured on TCP $ListenPort."
        exit 0
    }
    throw 'Managed gateway objects are incomplete or drifted; no state was changed.'
}

$privateProfiles = @(Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Private')
if ($privateProfiles.Count -eq 0) {
    throw 'No active Private network profile was found.'
}

$client = [Net.Sockets.TcpClient]::new()
try {
    $client.Connect('127.0.0.1', $TargetPort)
} finally {
    $client.Dispose()
}

$listeners = @(Get-NetTCPConnection -State Listen -LocalPort $ListenPort `
    -ErrorAction SilentlyContinue)
if (@(Get-PortProxyEntries -Port $ListenPort).Count -ne 0 -or
    $listeners.Count -ne 0 -or
    @(Get-NetFirewallRule -DisplayName $firewallName -ErrorAction SilentlyContinue).Count -ne 0) {
    throw "TCP $ListenPort or its managed firewall name is already in use."
}
$conflictingRules = @(Get-ConflictingFirewallRules -ManagedName $firewallName `
    -Port $ListenPort)
if ($conflictingRules.Count -ne 0) {
    throw "Another enabled inbound firewall rule can allow TCP $ListenPort."
}

$helperService = Get-CimInstance Win32_Service -Filter "Name='iphlpsvc'"
$helperWasRunning = $helperService.State -eq 'Running'
$proxyCreated = $false
$firewallCreated = $false
$temporaryState = "$statePath.tmp"
try {
    Set-Service -Name iphlpsvc -StartupType Automatic
    Start-Service -Name iphlpsvc
    & netsh.exe interface portproxy add v4tov4 `
        listenaddress=0.0.0.0 listenport=$ListenPort `
        connectaddress=127.0.0.1 connectport=$TargetPort
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create the gateway port proxy.' }
    $proxyCreated = $true

    New-NetFirewallRule -DisplayName $firewallName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $ListenPort -Profile Private `
        -RemoteAddress $AllowedRemoteAddress | Out-Null
    $firewallCreated = $true

    if ((Get-ProxyStatus -Port $ListenPort -ConnectPort $TargetPort) -ne 'Exact' -or
        (Get-FirewallStatus -Name $firewallName -Port $ListenPort `
            -RemoteAddress $AllowedRemoteAddress) -ne 'Exact' -or
        @(Get-NetTCPConnection -State Listen -LocalPort $ListenPort `
            -ErrorAction SilentlyContinue).Count -eq 0) {
        throw 'Gateway network objects did not pass post-install verification.'
    }

    [ordered]@{
        owner = $stateOwner
        schemaVersion = 1
        listenPort = $ListenPort
        targetPort = $TargetPort
        allowedRemoteAddress = $AllowedRemoteAddress
        firewallName = $firewallName
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $temporaryState -Encoding UTF8
    Move-Item -LiteralPath $temporaryState -Destination $statePath -Force
} catch {
    $originalError = $_
    $rollbackWarnings = @()
    if ($firewallCreated) {
        try {
            Get-NetFirewallRule -DisplayName $firewallName -ErrorAction SilentlyContinue |
                Remove-NetFirewallRule -ErrorAction Stop
        } catch {
            $rollbackWarnings += 'failed to remove the created firewall rule'
        }
    }
    if ($proxyCreated) {
        & netsh.exe interface portproxy delete v4tov4 `
            listenaddress=0.0.0.0 listenport=$ListenPort 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $rollbackWarnings += 'failed to remove the created port proxy'
        }
    }
    try {
        Remove-Item -LiteralPath $temporaryState -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
    } catch {
        $rollbackWarnings += 'failed to remove the temporary state file'
    }
    if (-not $helperWasRunning) {
        try {
            Stop-Service -Name iphlpsvc -ErrorAction Stop
        } catch {
            $rollbackWarnings += 'failed to restore the stopped IP Helper state'
        }
    }
    try {
        switch ($helperService.StartMode) {
            'Auto' { Set-Service -Name iphlpsvc -StartupType Automatic }
            'Manual' { Set-Service -Name iphlpsvc -StartupType Manual }
            'Disabled' { Set-Service -Name iphlpsvc -StartupType Disabled }
        }
    } catch {
        $rollbackWarnings += 'failed to restore the original IP Helper startup type'
    }

    $proxyAfter = Get-ProxyStatus -Port $ListenPort -ConnectPort $TargetPort
    $firewallAfter = Get-FirewallStatus -Name $firewallName -Port $ListenPort `
        -RemoteAddress $AllowedRemoteAddress
    if ($proxyAfter -ne 'Absent' -or $firewallAfter -ne 'Absent') {
        try {
            [ordered]@{
                owner = $stateOwner
                schemaVersion = 1
                listenPort = $ListenPort
                targetPort = $TargetPort
                allowedRemoteAddress = $AllowedRemoteAddress
                firewallName = $firewallName
                recovery = $true
                updatedAt = (Get-Date).ToString('o')
            } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
        } catch {
            $rollbackWarnings += 'failed to preserve recovery ownership state'
        }
        $rollbackWarnings += "rollback remains proxy=$proxyAfter firewall=$firewallAfter"
    }
    foreach ($warning in $rollbackWarnings) {
        Write-Warning $warning
    }
    if ($proxyAfter -ne 'Absent' -or $firewallAfter -ne 'Absent') {
        throw [InvalidOperationException]::new(
            "Gateway installation failed and rollback was incomplete. $($originalError.Exception.Message)",
            $originalError.Exception)
    }
    throw $originalError
}

Write-Host "Configured the HTTPS gateway relay on TCP $ListenPort."
Write-Host "Firewall scope: Private profiles and $AllowedRemoteAddress."
