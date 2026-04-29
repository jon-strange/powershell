# ============================================================
# Get-VDILastLogin.ps1
#
# Reads a CSV of VDI machines and assigned users, then queries
# the VMware Horizon REST API event history (backed by the
# Events DB) to find the last time each user logged into their
# assigned VDI machine.
#
# CSV format expected:
#   DNS Name,Assigned User
#   vdi01.corp.contoso.com,corp.contoso.com\jsmith
#   vdi02.corp.contoso.com,corp.contoso.com\bjones
#
# Requirements:
#   - HTTPS access to the Horizon Connection Server
#   - Horizon account with "Administrators (Read only)" role or higher
#   - Horizon 7.10+ (REST API with event history support)
#   - PowerShell 5.1+
# ============================================================

[CmdletBinding()]
param (
    # Path to your input CSV
    [Parameter(Mandatory)]
    [string]$CsvPath,

    # Horizon Connection Server FQDN or IP (do NOT include https://)
    [Parameter(Mandatory)]
    [string]$HorizonServer,

    # Horizon credentials (will prompt if not supplied)
    [System.Management.Automation.PSCredential]$HorizonCredential = (Get-Credential -Message "Enter Horizon read-only credentials"),

    # Horizon domain (the short/NetBIOS domain used to log into Horizon console)
    [Parameter(Mandatory)]
    [string]$HorizonDomain,

    # How far back to search for login events (days). Default 365.
    [int]$LookbackDays = 365,

    # Output CSV path. Leave blank to display on screen only.
    [string]$OutputCsv = ""
)

$baseUrl = "https://$HorizonServer/rest"

# Ignore self-signed cert errors common on internal Horizon servers
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

$authBody = @{
    domain   = $HorizonDomain
    username = $HorizonCredential.UserName
    password = $HorizonCredential.GetNetworkCredential().Password
} | ConvertTo-Json

try {
    $authResponse = Invoke-RestMethod `
        -Uri "$baseUrl/login" `
        -Method POST `
        -ContentType "application/json" `
        -Body $authBody `
        -ErrorAction Stop

    $accessToken  = $authResponse.access_token
    $refreshToken = $authResponse.refresh_token
} catch {
    Write-Error "Authentication failed: $_"
    exit 1
}

$authHeaders = @{ Authorization = "Bearer $accessToken" }
Write-Host "  Authenticated successfully." -ForegroundColor Gray

# Helper: refresh token if needed during long runs
function Update-HorizonToken {
    $body = @{ refresh_token = $script:refreshToken } | ConvertTo-Json
    $resp = Invoke-RestMethod `
        -Uri "$baseUrl/refresh" `
        -Method POST `
        -ContentType "application/json" `
        -Headers $script:authHeaders `
        -Body $body
    $script:accessToken  = $resp.access_token
    $script:refreshToken = $resp.refresh_token
    $script:authHeaders  = @{ Authorization = "Bearer $($script:accessToken)" }
}

# ── 3. Query event history per machine/user pair ─────────────
Write-Host "[3/4] Querying Horizon event history..." -ForegroundColor Cyan

# Horizon event types that indicate a successful user login to a desktop
$loginEventTypes = @("AGENT_CONNECTED", "BROKER_USERLOGGEDIN")

$fromTime = (Get-Date).AddDays(-$LookbackDays).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.000Z")

function Get-LastLoginEvent {
    param (
        [string]$MachineName,   # short hostname extracted from FQDN
        [string]$SamAccount,
        [string]$Domain
    )

    $page     = 1
    $pageSize = 100
    $lastLogin = $null

    do {
        # Build filter: machine name AND user name AND event type
        # Horizon REST filter uses JSON filter DSL
        $filterBody = @{
            filter = @{
                type    = "And"
                filters = @(
                    @{ type = "Equals"; name = "machine_name"; value = $MachineName },
                    @{ type = "Equals"; name = "user_name";    value = $SamAccount  },
                    @{ type = "Or"
                       filters = $loginEventTypes | ForEach-Object {
                           @{ type = "Equals"; name = "event_type"; value = $_ }
                       }
                    }
                )
            }
            page      = $page
            size      = $pageSize
            from_time = $fromTime
        } | ConvertTo-Json -Depth 10

        try {
            $resp = Invoke-RestMethod `
                -Uri "$baseUrl/monitor/v2/events" `
                -Method GET `
                -ContentType "application/json" `
                -Headers $script:authHeaders `
                -Body $filterBody `
                -ErrorAction Stop
        } catch {
            # 401 = token expired, refresh and retry once
            if ($_.Exception.Response.StatusCode -eq 401) {
                Update-HorizonToken
                $resp = Invoke-RestMethod `
                    -Uri "$baseUrl/monitor/v2/events" `
                    -Method GET `
                    -ContentType "application/json" `
                    -Headers $script:authHeaders `
                    -Body $filterBody `
                    -ErrorAction Stop
            } else {
                Write-Warning "  Event query failed for $SamAccount / $MachineName : $_"
                return $null
            }
        }

        $events = $resp.data
        if ($events -and $events.Count -gt 0) {
            # Events are returned newest-first; grab the most recent timestamp
            $newest = $events | Sort-Object time -Descending | Select-Object -First 1
            if ($null -eq $lastLogin -or $newest.time -gt $lastLogin) {
                $lastLogin = $newest.time
            }
        }

        $totalPages = [math]::Ceiling($resp.total / $pageSize)
        $page++

    } while ($page -le $totalPages -and $null -eq $lastLogin)
    # Stop as soon as we find any event — events are newest-first so first hit = last login

    return $lastLogin
}

# ── 4. Build results ─────────────────────────────────────────
Write-Host "[4/4] Building report..." -ForegroundColor Cyan

$results = foreach ($row in $vdiList) {
    $fqdn    = ($row."DNS Name"      -as [string]).Trim()
    $rawUser = ($row."Assigned User" -as [string]).Trim()

    # Extract short machine name from FQDN (Horizon stores it without domain suffix)
    $machineName = $fqdn.Split('.')[0].ToUpper()

    # Parse domain.fqdn\username
    $samAccount = $rawUser
    $userDomain = ""
    if ($rawUser -match '^(.+)\\(.+)$') {
        $userDomain = $Matches[1]
        $samAccount = $Matches[2]
    }

    Write-Host "  Checking: $machineName / $samAccount ..." -ForegroundColor Gray

    $lastLoginRaw = Get-LastLoginEvent -MachineName $machineName -SamAccount $samAccount -Domain $userDomain

    $lastLoginDisplay = if ($lastLoginRaw) {
        # Horizon returns epoch milliseconds or ISO string depending on version
        if ($lastLoginRaw -is [long] -or $lastLoginRaw -match '^\d+$') {
            ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$lastLoginRaw)).LocalDateTime.ToString("yyyy-MM-dd HH:mm:ss")
        } else {
            ([datetime]$lastLoginRaw).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
        }
    } else {
        "No login found in last $LookbackDays days"
    }

    [PSCustomObject]@{
        MachineFQDN    = $fqdn
        MachineName    = $machineName
        AssignedUser   = $rawUser
        SamAccountName = $samAccount
        Domain         = $userDomain
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
    Invoke-RestMethod -Uri "$baseUrl/logout" -Method POST `
        -ContentType "application/json" `
        -Headers $authHeaders `
        -Body (@{ refresh_token = $refreshToken } | ConvertTo-Json) | Out-Null
} catch {}

Write-Host "Done." -ForegroundColor Green
