#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ConfigFile = (Join-Path $PSScriptRoot '..\config\relay.env'),
    [string]$ServicesFile = (Join-Path $PSScriptRoot '..\config\services.conf'),
    [switch]$RegenerateKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-RelayConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path. Copy config\relay.example.env to config\relay.env first."
    }

    $settings = @{}
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }

        $separator = $line.IndexOf('=')
        if ($separator -lt 1) {
            throw "Invalid configuration line: $rawLine"
        }

        $name = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $settings[$name] = $value
    }
    return $settings
}

function Require-Setting {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Name,
        [string]$DefaultValue = ''
    )

    $value = if ($Settings.ContainsKey($Name)) { [string]$Settings[$Name] } else { $DefaultValue }
    if ([string]::IsNullOrWhiteSpace($value) -or $value.StartsWith('REPLACE_')) {
        throw "Set $Name in $ConfigFile before running this script."
    }
    return $value
}

function Assert-IPv4Address {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Name)

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$parsed) -or
        $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "$Name is not a valid IPv4 address: $Value"
    }
}

function Read-RelayServices {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Services file not found: $Path"
    }

    $result = [System.Collections.Generic.List[object]]::new()
    $lineNumber = 0
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $lineNumber++
        $line = ($rawLine -split '#', 2)[0].Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $fields = $line -split '\s+'
        if ($fields.Count -ne 5) {
            throw "Invalid service at line $lineNumber. Expected: NAME PROTOCOL PUBLIC_PORT TARGET_IP TARGET_PORT"
        }

        $protocol = $fields[1].ToLowerInvariant()
        if ($fields[0] -notmatch '^[A-Za-z0-9_.-]+$') {
            throw "Invalid service name at line $lineNumber."
        }
        if ($protocol -notin @('tcp', 'udp')) {
            throw "Service protocol must be tcp or udp at line $lineNumber."
        }

        $publicPort = 0
        $targetPort = 0
        if (-not [int]::TryParse($fields[2], [ref]$publicPort) -or $publicPort -lt 1 -or $publicPort -gt 65535) {
            throw "Invalid public port at line $lineNumber."
        }
        if (-not [int]::TryParse($fields[4], [ref]$targetPort) -or $targetPort -lt 1 -or $targetPort -gt 65535) {
            throw "Invalid target port at line $lineNumber."
        }
        Assert-IPv4Address -Value $fields[3] -Name "TARGET_IP at line $lineNumber"

        $result.Add([pscustomobject]@{
            Name       = $fields[0]
            Protocol   = $protocol
            PublicPort = $publicPort
            TargetIp   = $fields[3]
            TargetPort = $targetPort
        })
    }
    return $result
}

$settings = Read-RelayConfig -Path $ConfigFile
$ociPublicIp = Require-Setting -Settings $settings -Name 'OCI_PUBLIC_IP'
$serverPublicKey = Require-Setting -Settings $settings -Name 'WIREGUARD_SERVER_PUBLIC_KEY'
$homeServerIp = Require-Setting -Settings $settings -Name 'HOME_SERVER_IP'
$serverTunnelIp = Require-Setting -Settings $settings -Name 'WIREGUARD_SERVER_IP' -DefaultValue '10.77.0.1'
$clientTunnelIp = Require-Setting -Settings $settings -Name 'WIREGUARD_CLIENT_IP' -DefaultValue '10.77.0.2'
$wireGuardPort = [int](Require-Setting -Settings $settings -Name 'WIREGUARD_PORT' -DefaultValue '51820')
$wireGuardMtu = [int](Require-Setting -Settings $settings -Name 'WIREGUARD_MTU' -DefaultValue '1380')

Assert-IPv4Address -Value $ociPublicIp -Name 'OCI_PUBLIC_IP'
Assert-IPv4Address -Value $homeServerIp -Name 'HOME_SERVER_IP'
Assert-IPv4Address -Value $serverTunnelIp -Name 'WIREGUARD_SERVER_IP'
Assert-IPv4Address -Value $clientTunnelIp -Name 'WIREGUARD_CLIENT_IP'
if ($wireGuardPort -lt 1 -or $wireGuardPort -gt 65535) {
    throw 'WIREGUARD_PORT must be between 1 and 65535.'
}
if ($wireGuardMtu -lt 1280 -or $wireGuardMtu -gt 1420) {
    throw 'WIREGUARD_MTU must be between 1280 and 1420.'
}
if ($serverPublicKey -notmatch '^[A-Za-z0-9+/]{43}=$') {
    throw 'WIREGUARD_SERVER_PUBLIC_KEY is not a valid WireGuard public key.'
}
if ($ociPublicIp -eq '203.0.113.10') {
    throw 'Replace the documentation-only OCI_PUBLIC_IP in config\relay.env.'
}

$wireGuardExe = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
$wgExe = Join-Path $env:ProgramFiles 'WireGuard\wg.exe'
if (-not (Test-Path -LiteralPath $wireGuardExe) -or -not (Test-Path -LiteralPath $wgExe)) {
    throw 'WireGuard for Windows is not installed. Install it from https://www.wireguard.com/install/ and rerun this script.'
}

$services = Read-RelayServices -Path $ServicesFile
$stateDirectory = Join-Path $env:ProgramData 'EdgeRelay'
$privateKeyPath = Join-Path $stateDirectory 'client.key'
$publicKeyPath = Join-Path $stateDirectory 'client.pub'
$tunnelName = 'edge-relay'
$tunnelConfigPath = Join-Path $stateDirectory "$tunnelName.conf"
$serviceName = 'WireGuardTunnel$' + $tunnelName

New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
& icacls.exe $stateDirectory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Could not secure $stateDirectory."
}

if ($RegenerateKey -or -not (Test-Path -LiteralPath $privateKeyPath)) {
    $privateKey = (& $wgExe genkey | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($privateKey)) {
        throw 'WireGuard did not generate a private key.'
    }
    [System.IO.File]::WriteAllText($privateKeyPath, "$privateKey`r`n", [System.Text.UTF8Encoding]::new($false))
} else {
    $privateKey = (Get-Content -LiteralPath $privateKeyPath -Raw).Trim()
}

$publicKey = ($privateKey | & $wgExe pubkey | Out-String).Trim()
if ($publicKey -notmatch '^[A-Za-z0-9+/]{43}=$') {
    throw 'WireGuard did not derive a valid public key.'
}
[System.IO.File]::WriteAllText($publicKeyPath, "$publicKey`r`n", [System.Text.UTF8Encoding]::new($false))

$tunnelConfig = @"
[Interface]
PrivateKey = $privateKey
Address = $clientTunnelIp/32
MTU = $wireGuardMtu

[Peer]
PublicKey = $serverPublicKey
Endpoint = ${ociPublicIp}:$wireGuardPort
AllowedIPs = $serverTunnelIp/32
PersistentKeepalive = 25
"@
[System.IO.File]::WriteAllText($tunnelConfigPath, $tunnelConfig, [System.Text.UTF8Encoding]::new($false))
foreach ($protectedPath in @($privateKeyPath, $publicKeyPath, $tunnelConfigPath)) {
    & icacls.exe $protectedPath /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not secure $protectedPath."
    }
}

$existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($null -ne $existingService) {
    & $wireGuardExe /uninstalltunnelservice $tunnelName
    if ($LASTEXITCODE -ne 0) {
        throw "Could not replace the existing $tunnelName tunnel service."
    }
    Start-Sleep -Seconds 1
}

& $wireGuardExe /installtunnelservice $tunnelConfigPath
if ($LASTEXITCODE -ne 0) {
    throw 'WireGuard tunnel service installation failed.'
}
Set-Service -Name $serviceName -StartupType Automatic
Start-Service -Name $serviceName -ErrorAction SilentlyContinue

$adapter = $null
for ($attempt = 0; $attempt -lt 20 -and $null -eq $adapter; $attempt++) {
    $adapter = Get-NetAdapter -Name $tunnelName -ErrorAction SilentlyContinue
    if ($null -eq $adapter) {
        Start-Sleep -Milliseconds 500
    }
}
if ($null -eq $adapter) {
    throw "The $tunnelName WireGuard adapter did not appear."
}

# The relay can target an address assigned to another local interface, such as
# the server's LAN address. Enable weak-host behavior only on this WireGuard
# adapter so Windows can receive and reply to that traffic without changing the
# Ethernet, Tailscale, or default-route configuration.
Set-NetIPInterface -InterfaceAlias $tunnelName -AddressFamily IPv4 -WeakHostReceive Enabled -WeakHostSend Enabled

$rulePrefix = 'Edge Relay - '
Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object DisplayName -Like "$rulePrefix*" |
    Remove-NetFirewallRule

New-NetFirewallRule `
    -DisplayName "${rulePrefix}tunnel ping" `
    -Direction Inbound `
    -Action Allow `
    -Protocol ICMPv4 `
    -IcmpType 8 `
    -RemoteAddress $serverTunnelIp `
    -Profile Any | Out-Null

foreach ($service in $services) {
    if ($service.TargetIp -ne $homeServerIp -and $service.TargetIp -ne $clientTunnelIp) {
        Write-Warning "Skipping Windows Firewall rule for $($service.Name): target $($service.TargetIp) is not this Windows peer."
        continue
    }

    New-NetFirewallRule `
        -DisplayName "$rulePrefix$($service.Name)" `
        -Direction Inbound `
        -Action Allow `
        -Protocol $service.Protocol `
        -LocalPort $service.TargetPort `
        -RemoteAddress $serverTunnelIp `
        -Profile Any | Out-Null
}

$privateKey = $null
$tunnelConfig = $null

Write-Host ''
Write-Host 'Windows setup complete.' -ForegroundColor Green
Write-Host "Tunnel service: $serviceName"
Write-Host "Allowed route: $serverTunnelIp/32 only (the default route and Tailscale were not changed)."
Write-Host ''
Write-Host "WINDOWS_PUBLIC_KEY=$publicKey" -ForegroundColor Cyan
Write-Host ''
Write-Host 'Put that public key in config\relay.env on the Linux gateway, then run oracle/setup.sh.'
