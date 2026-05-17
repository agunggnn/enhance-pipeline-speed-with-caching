#Requires -RunAsAdministrator
# Reads the current WSL2 IP and creates netsh portproxy + Firewall rules to
# expose GitLab (8080), MinIO API (9000), MinIO console (9001), and SSH (2222)
# on the Windows PC's LAN interface (0.0.0.0 = all adapters).
#
# WSL2 assigns a new internal IP on every Windows reboot, so these rules must
# be refreshed each time. Add this script to Task Scheduler:
#   Trigger: At startup
#   Action:  powershell.exe -ExecutionPolicy Bypass -File "<path>\expose-ports.ps1"
#   General: Run with highest privileges, check "Run whether user is logged on or not"
#   Delay:   15 seconds (lets WSL2 fully start before we query its IP)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$wslIp = (wsl -d Ubuntu-22.04 -- ip -4 addr show eth0 2>$null |
    Select-String 'inet ' |
    ForEach-Object { ($_ -split '\s+')[2] -replace '/.*','' } |
    Select-Object -First 1)

if (-not $wslIp) {
    Write-Error "Could not determine WSL2 IP. Is WSL2 running? Try: wsl --list --running"
    exit 1
}
Write-Host "WSL2 IP: $wslIp"

$ports = @(8080, 9000, 9001, 2222)

# Remove stale portproxy rules for these ports before re-adding with the current
# WSL2 IP, which may differ from the last time this script ran.
foreach ($port in $ports) {
    $existing = netsh interface portproxy show v4tov4 |
        Select-String "0\.0\.0\.0\s+$port"
    if ($existing) {
        Write-Host "Removing stale portproxy rule for port $port..."
        netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$port | Out-Null
    }
}

foreach ($port in $ports) {
    Write-Host "Adding portproxy: 0.0.0.0:$port -> ${wslIp}:$port"
    netsh interface portproxy add v4tov4 `
        listenaddress=0.0.0.0 `
        listenport=$port `
        connectaddress=$wslIp `
        connectport=$port | Out-Null
}

$ruleBaseName = "WSL2-GitLab-"
foreach ($port in $ports) {
    $ruleName = "${ruleBaseName}${port}"
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existing) {
        Remove-NetFirewallRule -DisplayName $ruleName
    }
    Write-Host "Adding firewall rule: $ruleName (TCP inbound port $port)"
    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $port `
        -Action Allow `
        -Profile Any | Out-Null
}

Write-Host ""
Write-Host "Current portproxy rules:"
netsh interface portproxy show v4tov4

Write-Host ""
Write-Host "Ports exposed on Windows PC LAN (192.168.1.20):"
foreach ($port in $ports) {
    Write-Host "  $port -> WSL2 $wslIp`:$port"
}
Write-Host ""
Write-Host "From MacBook, verify with:"
Write-Host "  curl http://192.168.1.20:8080/-/health"
Write-Host "  curl http://192.168.1.20:9000/minio/health/live"
