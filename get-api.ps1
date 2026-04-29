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

# Pull a large batch sorted newest-first and show ALL unique event types
# along with what machine names they are associated with (masked)
$uri    = "https://" + $server + "/rest/external/v1/audit-events?page=1&size=1000&sort_by=time&sort_order=Descending"
$result = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers

Write-Host "=== All unique event types in last 1000 records ===" -ForegroundColor Cyan
$result | Select-Object -ExpandProperty type | Sort-Object -Unique

Write-Host "`n=== Newest and oldest event timestamps in this batch ===" -ForegroundColor Cyan
$sorted = $result | Sort-Object time -Descending
$newest = [DateTimeOffset]::FromUnixTimeMilliseconds([long]($sorted | Select-Object -First 1).time).LocalDateTime
$oldest = [DateTimeOffset]::FromUnixTimeMilliseconds([long]($sorted | Select-Object -Last 1).time).LocalDateTime
Write-Host "Newest: $newest"
Write-Host "Oldest: $oldest"

# Pick one of your known VDI machine FQDNs that had a login 2 weeks ago
$knownMachine = "yourvdimachine.domain.fqdn"

Write-Host "`n=== All event types for $knownMachine ===" -ForegroundColor Cyan
$result | Where-Object { $_.machine_dns_name -eq $knownMachine } |
    Select-Object @{N="time";E={[DateTimeOffset]::FromUnixTimeMilliseconds([long]$_.time).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss")}}, type |
    Sort-Object time -Descending |
    Format-Table -AutoSize
