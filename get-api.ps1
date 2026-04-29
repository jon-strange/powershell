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

$uri    = "https://" + $server + "/rest/external/v1/audit-events?page=1&size=3"
$result = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers

# Print only the field names from the first record — no values
if ($result -and $result.Count -gt 0) {
    Write-Host "Top-level response type: $($result.GetType().Name)"
    Write-Host "First record field names:"
    $result[0].PSObject.Properties.Name
} elseif ($result.PSObject.Properties["data"]) {
    Write-Host "Top-level response type: object with 'data' property"
    Write-Host "First record field names:"
    $result.data[0].PSObject.Properties.Name
}
