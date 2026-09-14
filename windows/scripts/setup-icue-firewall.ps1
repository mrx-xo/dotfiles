# Run separately from an elevated PowerShell session. Never self-elevates.
# Explicit parameters override environment; AllowedNetworks REPLACES defaults.
# Configure the same port and networks in the driver's logon environment.
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$Port = $(if (Test-Path Env:ICUE_HTTP_PORT) { $env:ICUE_HTTP_PORT } else { '7790' }),
    [string]$AllowedNetworks = $(if (Test-Path Env:ICUE_HTTP_ALLOWED_NETWORKS) {
        $env:ICUE_HTTP_ALLOWED_NETWORKS
    } else { '127.0.0.0/8,::1/128,100.64.0.0/10' })
)
$ErrorActionPreference = 'Stop'

if ($Port -notmatch '^[0-9]{1,5}$' -or [int]$Port -lt 1 -or [int]$Port -gt 65535) {
    throw 'Port must be an integer in 1..65535.'
}
$networks = @($AllowedNetworks.Split(',') | ForEach-Object { $_.Trim() })
foreach ($network in $networks) {
    $parts = $network.Split('/')
    $address = $null
    if ($parts.Count -ne 2 -or
        -not [System.Net.IPAddress]::TryParse($parts[0], [ref]$address) -or
        $parts[1] -notmatch '^[0-9]{1,3}$') {
        throw 'AllowedNetworks must contain comma-separated network CIDRs.'
    }
    $bytes = $address.GetAddressBytes()
    $bits = $bytes.Length * 8
    $prefix = [int]$parts[1]
    if ($prefix -gt $bits) { throw 'Invalid network prefix length.' }
    for ($bit = $prefix; $bit -lt $bits; $bit++) {
        if (($bytes[[int][Math]::Floor($bit / 8)] -band (1 -shl (7 - ($bit % 8)))) -ne 0) {
            throw 'Network CIDRs must have host bits cleared.'
        }
    }
}

$ruleName = 'ICUELights-HTTP'
$settings = @{
    Direction = 'Inbound'
    Action = 'Allow'
    Enabled = 'True'
    Protocol = 'TCP'
    LocalPort = [int]$Port
    RemoteAddress = $networks
    Profile = 'Any'
}
if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -Name $ruleName @settings
} else {
    New-NetFirewallRule -Name $ruleName -DisplayName 'iCUE lights HTTP' @settings | Out-Null
}
Write-Host "Done. Scoped iCUE HTTP firewall rule configured for TCP port $Port."
