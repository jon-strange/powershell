$server   = "your-horizon-server"
$domain   = "your-netbios-domain"
$username = "your-username"
$password = "your-password"
$testMachine = "yourvdi.domain.fqdn"

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

# Test various server-side filter parameter styles
$baseUri = "https://" + $server + "/rest/external/v1/audit-events"

$tests = [ordered]@{
    "type filter"         = $baseUri + "?page=1&size=5&type=BROKER_USERLOGGEDIN"
    "machine_dns_name"    = $baseUri + "?page=1&size=5&machine_dns_name=" + $testMachine
    "filter by type"      = $baseUri + "?page=1&size=5&filter=type%3DBROKER_USERLOGGEDIN"
    "event_type param"    = $baseUri + "?page=1&size=5&event_type=BROKER_USERLOGGEDIN"
    "module param"        = $baseUri + "?page=1&size=5&module=BROKER"
}

foreach ($test in $tests.GetEnumerator()) {
    try {
        $resp = Invoke-RestMethod -Uri $test.Value -Method GET -Headers $headers -ErrorAction Stop
        Write-Host "OK  [$($resp.Count) results] $($test.Key)" -ForegroundColor Green
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        Write-Host "    [$code] $($test.Key)" -ForegroundColor Gray
    }
}
