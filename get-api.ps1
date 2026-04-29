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

$pathsToTry = @(
    "/rest/monitor/v1/events",
    "/rest/monitor/v2/events",
    "/rest/external/v1/audit-events",
    "/rest/monitor/v1/session-events",
    "/rest/monitor/v2/session-events",
    "/rest/monitor/v1/desktop-sessions",
    "/rest/monitor/v2/desktop-sessions",
    "/rest/monitor/v1/audit",
    "/rest/monitor/v2/audit",
    "/rest/inventory/v1/sessions",
    "/rest/inventory/v2/sessions",
    "/rest/inventory/v1/machines",
    "/rest/inventory/v2/machines",
    "/rest/monitor/v1/global-sessions",
    "/rest/monitor/v2/global-sessions"
)

foreach ($path in $pathsToTry) {
    $uri = "https://" + $server + $path + "?page=1&size=1"
    try {
        $resp = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -ErrorAction Stop
        Write-Host "OK  [200] $path" -ForegroundColor Green
        Write-Host "    Response: $($resp | ConvertTo-Json -Depth 2 -Compress)" -ForegroundColor Yellow
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        Write-Host "    [$code] $path" -ForegroundColor Gray
    }
}
