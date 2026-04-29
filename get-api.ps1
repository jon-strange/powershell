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

# Show only the unique event types and the format of user_id (masked)
$uri    = "https://" + $server + "/rest/external/v1/audit-events?page=1&size=20"
$result = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers

Write-Host "Unique event types seen:"
$result | Select-Object -ExpandProperty type | Sort-Object -Unique

Write-Host "`nUser ID format (masked):"
$sample = $result[0].user_id -as [string]
Write-Host ("Length: " + $sample.Length)
Write-Host ("Starts with: " + $sample.Substring(0, [Math]::Min(3, $sample.Length)) + "...")
Write-Host ("Contains backslash: " + $sample.Contains("\"))
Write-Host ("Contains @: " + $sample.Contains("@"))
