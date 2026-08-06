$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$proxy = $null
$dump = (& netsh.exe interface portproxy dump | Out-String)
$match = [regex]::Match(
    $dump,
    'add v4tov4 listenport=(\d+) connectaddress=127\.0\.0\.1 connectport=22(?: listenaddress=0\.0\.0\.0)?'
)
if ($match.Success) {
    $listenPort = [int]$match.Groups[1].Value
    $listener = Get-NetTCPConnection -State Listen -LocalPort $listenPort `
        -ErrorAction SilentlyContinue
    $proxy = [ordered]@{
        enabled = $true
        listenAddress = '0.0.0.0'
        listenPort = $listenPort
        targetAddress = '127.0.0.1'
        targetPort = 22
        listening = [bool]$listener
    }
}

$firewallRule = Get-NetFirewallRule `
    -DisplayName 'WSL SSH (LAN TCP *)' `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1
$firewall = $null
if ($firewallRule) {
    $addressFilter = $firewallRule | Get-NetFirewallAddressFilter
    $portFilter = $firewallRule | Get-NetFirewallPortFilter
    $firewall = [ordered]@{
        enabled = $firewallRule.Enabled -eq 'True'
        action = $firewallRule.Action.ToString()
        profile = $firewallRule.Profile.ToString()
        remoteAddress = @($addressFilter.RemoteAddress)
        localPort = $portFilter.LocalPort
    }
}

$interfaces = Get-NetIPConfiguration |
    Where-Object IPv4DefaultGateway |
    ForEach-Object {
        [ordered]@{
            name = $_.InterfaceAlias
            address = $_.IPv4Address.IPAddress
            gateway = $_.IPv4DefaultGateway.NextHop
        }
    }

$task = Get-ScheduledTask -TaskName 'Start WSL __DISTRO__ SSH at logon' `
    -ErrorAction SilentlyContinue

[ordered]@{
    interfaces = @($interfaces)
    portProxy = $proxy
    firewall = $firewall
    startupTask = if ($task) {
        [ordered]@{ exists = $true; state = $task.State.ToString() }
    } else {
        [ordered]@{ exists = $false; state = 'Missing' }
    }
} | ConvertTo-Json -Depth 6 -Compress
