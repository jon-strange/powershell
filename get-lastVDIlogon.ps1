# ============================================================
# Get-VDILastLogin.ps1
#
# Reads a CSV of VDI machines and assigned users, resolves each
# user's AD SID, then queries the Horizon audit events API
# (/rest/external/v1/audit-events) to find the last BROKER_USERLOGGEDIN
# event matching that SID on their assigned VDI machine.
#
# CSV format expected:
#   DNS Name,Assigned User
#   vdi01.corp.contoso.com,corp.contoso.com\jsmith
#   vdi02.corp.contoso.com,corp.contoso.com\bjones
#
# Requirements:
#   - HTTPS access to the Horizon Connection Server
#   - Horizon account with "Administrators (Read only)" role or higher
#   - ActiveDirectory PowerShell module (RSAT)
#   - PowerShell 5.1+
# ============================================================

#Requires -Modules ActiveDirectory

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [string]$HorizonServer,

    [System.Management.Automation.PSCredential]$HorizonCredential = (Get-Credential -Message "Enter Horizon read-only credentials"),

    [Parameter(Mandatory)]
    [string]$HorizonDomain,

    # How far back to search for login events (days). Default 365.
    [int]$LookbackDays = 365,

    [string]$OutputCsv = ""
)

# ── TLS / cert bypass ────────────────────────────────────────
if (-not ([System.Management.Automation.PSTypeName]'TrustAllCerts').Type) {
    Add-Type @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCerts : ICertificatePolicy {
            public bool CheckValidationResult(
                ServicePoint sp, X509Certificate cert,
                WebRequest req, int problem) { return true; }
        }
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# ── 1. Import and validate CSV ───────────────────────────────
Write-Host "[1/4] Reading CSV: $CsvPath" -ForegroundColor Cyan

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV file not found: $CsvPath"
    exit 1
}

$vdiList = Import-Csv -Path $CsvPath

$headers = $vdiList[0].PSObject.Properties.Name
if ("DNS Name" -notin $headers -or "Assigned User" -notin $headers) {
    Write-Error "CSV must contain 'DNS Name' and 'Assigned User' columns. Found: $($headers -join ', ')"
    exit 1
}

Write-Host "  Found $($vdiList.Count) row(s)." -ForegroundColor Gray

# ── 2. Authenticate to Horizon REST API ──────────────────────
Write-Host "[2/4] Authenticating to Horizon REST API..." -ForegroundColor Cyan

$loginUri = "https://" + $HorizonServer + "/rest/login"
$authBody = @{
    domain   = $HorizonDomain
    username = $HorizonCredential.UserName
    password = $HorizonCredential.GetNetworkCredential().Password
} | ConvertTo-Json

try {
    $authResponse        = Invoke-RestMethod -Uri $loginUri -Method POST -ContentType "application/json" -Body $authBody -ErrorAction Stop
    $script:accessToken  = $authResponse.access_token
    $script:refreshToken = $authResponse.refresh_token
    $script:authHeaders  = @{ Authorization = "Bearer " + $script:accessToken }
    $script:baseUrl      = "https://" + $HorizonServer + "/rest"
} catch {
    Write-Error "Authentication failed: $_"
    exit 1
}

Write-Host "  Authenticated successfully." -ForegroundColor Gray

# ── Token refresh helper ─────────────────────────────────────
function Update-HorizonToken {
    $body       = @{ refresh_token = $script:refreshToken } | ConvertTo-Json
    $refreshUri = $script:baseUrl + "/refresh"
    $resp = Invoke-RestMethod -Uri $refreshUri -Method POST -ContentType "application/json" -Headers $script:authHeaders -Body $body
    $script:accessToken  = $resp.access_token
    $script:refreshToken = $resp.refresh_token
    $script:authHeaders  = @{ Authorization = "Bearer " + $script:accessToken }
}

# ── Authenticated GET helper ─────────────────────────────────
function Invoke-HorizonGet {
    param([string]$Uri)
    try {
        return Invoke-RestMethod -Uri $Uri -Method GET -Headers $script:authHeaders -ErrorAction Stop
    } catch {
        if ($_.Exception.Response.StatusCode -eq 401) {
            Update-HorizonToken
            return Invoke-RestMethod -Uri $Uri -Method GET -Headers $script:authHeaders -ErrorAction Stop
        }
        throw
    }
}

# ── 3. Resolve AD SIDs and query audit events ────────────────
Write-Host "[3/4] Resolving AD users and querying audit events..." -ForegroundColor Cyan

# Lookback window start in epoch milliseconds
$script:fromTimeMs = [long]((Get-Date).AddDays(-$LookbackDays) - [datetime]"1970-01-01T00:00:00Z").TotalMilliseconds

function Get-LastLoginEvent {
    param (
        [string]$MachineName,  # Short hostname — Horizon Events DB does not store FQDN
        [string]$UserSid
    )

    $pageSize   = 100
    $page       = 1
    $allMatches = @()

    do {
        # Server-side filter on short machine name and event type.
        # sort_order is not reliably honoured by this API version so we
        # collect all matching events across all pages and return the max.
        $uri = $script:baseUrl + "/external/v1/audit-events" +
               "?type=BROKER_USERLOGGEDIN" +
               "&machine_dns_name=" + [System.Uri]::EscapeDataString($MachineName) +
               "&page=" + $page +
               "&size=" + $pageSize

        try {
            $events = Invoke-HorizonGet -Uri $uri

            if ($events -and $events.Count -gt 0) {

                # Filter client-side by SID and lookback window
                $pageMatches = $events | Where-Object {
                    $_.user_id -eq $UserSid -and
                    $_.time    -ge $script:fromTimeMs
                }

                if ($pageMatches) {
                    $allMatches += $pageMatches
                }

                # Stop when we get a partial page — no more results exist
                if ($events.Count -lt $pageSize) { break }

            } else {
                break
            }

            $page++

        } catch {
            Write-Warning "  Event query failed for $MachineName : $_"
            break
        }

    } while ($true)

    # Return the highest (most recent) timestamp across all matching events
    if ($allMatches.Count -gt 0) {
        return ($allMatches | Measure-Object -Property time -Maximum).Maximum
    }

    return $null
}

# ── 4. Build results ─────────────────────────────────────────
Write-Host "[4/4] Building report..." -ForegroundColor Cyan

$results = foreach ($row in $vdiList) {
    $fqdn    = ($row."DNS Name"      -as [string]).Trim()
    $rawUser = ($row."Assigned User" -as [string]).Trim()

    # Strip domain suffix — Horizon Events DB stores short hostname only
    $machineName = $fqdn.Split('.')[0]

    # Parse domain.fqdn\username
    $samAccount = $rawUser
    $userDomain = ""
    if ($rawUser -match '^(.+)\\(.+)$') {
        $userDomain = $Matches[1]
        $samAccount = $Matches[2]
    }

    Write-Host "  Resolving SID for $samAccount ..." -ForegroundColor Gray

    # Resolve the user's SID from AD
    $userSid = $null
    try {
        $adParams = @{
            Identity    = $samAccount
            Properties  = @("SID")
            ErrorAction = "Stop"
        }
        if ($userDomain) { $adParams["Server"] = $userDomain }
        $adUser  = Get-ADUser @adParams
        $userSid = $adUser.SID.Value
    } catch {
        Write-Warning "  AD lookup failed for '$samAccount': $_"
    }

    $lastLoginDisplay = "AD lookup failed - skipping"

    if ($userSid) {
        Write-Host "  Querying events for $samAccount on $machineName ..." -ForegroundColor Gray

        $lastLoginMs = Get-LastLoginEvent -MachineName $machineName -UserSid $userSid

        $lastLoginDisplay = if ($lastLoginMs) {
            ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$lastLoginMs)).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss")
        } else {
            "No login found in last $LookbackDays days"
        }
    }

    [PSCustomObject]@{
        MachineFQDN    = $fqdn
        MachineName    = $machineName
        AssignedUser   = $rawUser
        SamAccountName = $samAccount
        Domain         = $userDomain
        UserSID        = $userSid
        LastVDILogin   = $lastLoginDisplay
    }
}

# ── Display ──────────────────────────────────────────────────
$results | Format-Table -AutoSize

# ── Export ───────────────────────────────────────────────────
if ($OutputCsv) {
    $results | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Host "`nResults saved to: $OutputCsv" -ForegroundColor Green
}

# ── Logout ───────────────────────────────────────────────────
try {
    $logoutUri = $script:baseUrl + "/logout"
    Invoke-RestMethod -Uri $logoutUri -Method POST -ContentType "application/json" `
        -Headers $script:authHeaders `
        -Body (@{ refresh_token = $script:refreshToken } | ConvertTo-Json) | Out-Null
} catch {}

Write-Host "Done." -ForegroundColor Green
