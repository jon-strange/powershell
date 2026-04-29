$server = "<your-horizon-server>"
$domain = "<your-netbios-domain>"
$username = "<your-username>"
$password = "<your-password>"

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

# Authenticate
$loginUri = "https://$server/rest/login"
$authBody  = @{ domain = $domain; username = $username; password = $password } | ConvertTo-Json
$token     = (Invoke-RestMethod -Uri $loginUri -Method POST -ContentType "application/json" -Body $authBody).access_token

$headers = @{ Authorization = "Bearer $token" }

# Fetch the swagger doc
$swaggerUri = "https://$server/rest/v1/swagger.json"
$swagger    = Invoke-RestMethod -Uri $swaggerUri -Method GET -Headers $headers

# Print all available API paths
$swagger.paths.PSObject.Properties.Name | Sort-Object
