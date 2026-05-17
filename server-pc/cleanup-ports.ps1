#Requires -RunAsAdministrator
# Reverses expose-ports.ps1: removes netsh portproxy rules and Firewall rules
# for the GitLab/MinIO ports. Run before decommissioning the PC server role.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ports = @(8080, 9000, 9001, 2222)
$ruleBaseName = "WSL2-GitLab-"

foreach ($port in $ports) {
    $existing = netsh interface portproxy show v4tov4 |
        Select-String "0\.0\.0\.0\s+$port"
    if ($existing) {
        Write-Host "Removing portproxy rule for port $port..."
        netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$port | Out-Null
    } else {
        Write-Host "No portproxy rule found for port $port."
    }

    $ruleName = "${ruleBaseName}${port}"
    $fw = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($fw) {
        Write-Host "Removing firewall rule: $ruleName"
        Remove-NetFirewallRule -DisplayName $ruleName
    } else {
        Write-Host "No firewall rule found: $ruleName"
    }
}

Write-Host ""
Write-Host "Cleanup complete. Remaining portproxy rules:"
netsh interface portproxy show v4tov4
