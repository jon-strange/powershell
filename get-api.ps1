$server   = "your-horizon-server"
$domain   = "your-netbios-domain"
$username = "your-username"
$password = "your-password"

Add-Type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCerts2 : ICertificatePolicy {
        public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$loginUri = "https://" + $server + "/rest/login"
$authBody = @{ domain = $domain; username = $username; password = $password } | ConvertTo-Json
$token    = (Invoke-RestMethod -Uri $loginUri -Method POST -ContentType "application/json" -Body $authBody).access_token
$headers  = @{ Authorization = "Bearer " + $token }

# Pull a larger sample sorted newest-first
$uri    = "https://" + $server + "/rest/external/v1/audit-events?page=1&size=100&sort_by=time&sort_order=Descending"
$result = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers

# 1. Show VLSI_USERLOGGEDIN events only — mask user_id, show machine and time
Write-Host "=== VLSI_USERLOGGEDIN events in last 100 records ===" -ForegroundColor Cyan
$result | Where-Object { $_.type -eq "VLSI_USERLOGGEDIN" } | ForEach-Object {
    [PSCustomObject]@{
        time             = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$_.time).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss")
        machine_dns_name = $_.machine_dns_name
        user_id_prefix   = ($_.user_id -as [string]).Substring(0,10) + "..."
    }
} | Format-Table -AutoSize

# 2. Show all unique machine_dns_name formats seen across all 100 events
Write-Host "=== Unique machine_dns_name formats seen ===" -ForegroundColor Cyan
$result | Select-Object -ExpandProperty machine_dns_name | Sort-Object -Unique
