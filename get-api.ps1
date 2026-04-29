$server   = "your-horizon-server"
$domain   = "your-netbios-domain"
$username = "your-username"
$password = "your-password"

# A machine and user you KNOW logged in within the last 2 weeks
$testMachine = "yourvdi.domain.fqdn"
$testUser    = "knownusername"   # sAMAccountName only

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
$loginUri = "https://" + $server + "/rest/login"
$authBody = @{ domain = $domain; username = $username; password = $password } | ConvertTo-Json
$token    = (Invoke-RestMethod -Uri $loginUri -Method POST -ContentType "application/json" -Body $authBody).access_token
$headers  = @{ Authorization = "Bearer " + $token }

# Resolve the test user's SID from AD
$adUser = Get-ADUser -Identity $testUser -Properties SID
$sid    = $adUser.SID.Value
Write-Host "Resolved SID: $sid" -ForegroundColor Cyan

# Pull 1000 events newest-first and filter client-side for this machine + user
$uri    = "https://" + $server + "/rest/external/v1/audit-events?page=1&size=1000&sort_by=time&sort_order=Descending"
$result = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers

Write-Host "Total events returned: $($result.Count)" -ForegroundColor Cyan

# Check 1: any events for this machine at all?
$machineEvents = $result | Where-Object { $_.machine_dns_name -eq $testMachine }
Write-Host "Events for $testMachine`: $($machineEvents.Count)" -ForegroundColor Cyan

# Check 2: any events for this SID at all?
$sidEvents = $result | Where-Object { $_.user_id -eq $sid }
Write-Host "Events for SID $sid`: $($sidEvents.Count)" -ForegroundColor Cyan

# Check 3: combined match
$combined = $result | Where-Object { $_.machine_dns_name -eq $testMachine -and $_.user_id -eq $sid }
Write-Host "Combined machine+SID matches: $($combined.Count)" -ForegroundColor Cyan

# Check 4: show event types for this machine regardless of user
Write-Host "`nEvent types seen for $testMachine`:" -ForegroundColor Cyan
$machineEvents | Select-Object -ExpandProperty type | Sort-Object -Unique
