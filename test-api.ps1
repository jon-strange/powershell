$server      = "your-horizon-server"
$domain      = "your-netbios-domain"
$username    = "your-username"
$password    = "your-password"
$testMachine = "yourvdimachinename"   # SHORT name only, no domain suffix
$testUser    = "knownusername"

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

# Resolve SID
$adUser = Get-ADUser -Identity $testUser -Properties SID
$sid    = $adUser.SID.Value
Write-Host "Resolved SID: $sid" -ForegroundColor Cyan

# Query using short machine name this time
$uri    = "https://" + $server + "/rest/external/v1/audit-events?type=BROKER_USERLOGGEDIN&machine_dns_name=" + $testMachine + "&sort_by=time&sort_order=Descending&page=1&size=10"
$result = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers

Write-Host "Events returned: $($result.Count)" -ForegroundColor Cyan

$result | ForEach-Object {
    [PSCustomObject]@{
        time      = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$_.time).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss")
        user_id   = $_.user_id
        sid_match = ($_.user_id -eq $sid)
    }
} | Format-Table -AutoSize
