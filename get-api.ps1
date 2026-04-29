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

$headers = @{ Authorization = "Bearer " + $token }

# Hit the events endpoint with no filters — just see what comes back
$eventsUri = "https://" + $server + "/rest/monitor/v2/events?page=1&size=5"
$result    = Invoke-RestMethod -Uri $eventsUri -Method GET -Headers $headers

$result | ConvertTo-Json -Depth 5
