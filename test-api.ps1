$server = "<your-horizon-server>"

# Bypass self-signed cert
Add-Type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCerts2 : ICertificatePolicy {
        public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$pathsToTry = @(
    "/rest/swagger.json",
    "/rest/api-docs",
    "/rest/v1/swagger.json",
    "/rest/v2/swagger.json",
    "/rest/monitor/v1/events",
    "/rest/monitor/v2/events",
    "/rest/external/v1/audit-events",
    "/rest/inventory/v1/machines",
    "/rest/inventory/v2/machines",
    "/portal/rest/swagger.json",
    "/admin/rest/swagger.json",
    "/broker/rest/swagger.json"
)

foreach ($path in $pathsToTry) {
    try {
        $resp = Invoke-WebRequest -Uri "https://$server$path" -Method GET -UseBasicParsing -ErrorAction Stop
        Write-Host "OK  [$($resp.StatusCode)] $path" -ForegroundColor Green
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        Write-Host "    [$code] $path" -ForegroundColor Gray
    }
}
