# ============================================================
# Get-VDILastLogin.ps1
# Reads VDI machine names and assigned users from a CSV file
# and reports each user's last login time on their assigned
# Horizon VDI machine.
#
# CSV format expected:
#   DNS Name,Assigned User
#   vdi01.corp.contoso.com,corp.contoso.com\jsmith
#   vdi02.corp.contoso.com,corp.contoso.com\bjones
#
# Requirements:
#   - VMware.VimAutomation.HorizonView module  (Horizon PowerCLI)
#   - ActiveDirectory module  (RSAT)
#   - Run as a user with Horizon read access + AD read access
# ============================================================

#Requires -Modules ActiveDirectory

[CmdletBinding()]
param (
    # Path to your CSV file
    [Parameter(Mandatory)]
    [string]$CsvPath,

    # Your Horizon Connection Server hostname or IP
    [Parameter(Mandatory)]
    [string]$HorizonServer,

    # Credentials for the Horizon Connection Server
    [System.Management.Automation.PSCredential]$HorizonCredential = (Get-Credential -Message "Horizon Connection Server credentials"),

    # Where to save the results CSV. Leave blank to only display on screen.
    [string]$OutputCsv = ""
)

# ── 1. Import the CSV ────────────────────────────────────────
Write-Host "[1/4] Reading CSV file: $CsvPath" -ForegroundColor Cyan

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV file not found: $CsvPath"
    exit 1
}

try {
    $vdiList = Import-Csv -Path $CsvPath
} catch {
    Write-Error "Failed to read CSV file: $_"
    exit 1
}

# Validate required headers exist
$headers = $vdiList[0].PSObject.Properties.Name
if ("DNS Name" -notin $headers -or "Assigned User" -notin $headers) {
    Write-Error "CSV must contain headers: 'DNS Name' and 'Assigned User'. Found: $($headers -join ', ')"
    exit 1
}

if (-not $vdiList) {
    Write-Error "No data rows found in CSV."
    exit 1
}

Write-Host "  Found $($vdiList.Count) row(s)." -ForegroundColor Gray

# ── 2. Connect to Horizon ────────────────────────────────────
Write-Host "[2/4] Connecting to Horizon Connection Server: $HorizonServer" -ForegroundColor Cyan

if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.HorizonView)) {
    try {
        Add-PSSnapin VMware.View.Broker -ErrorAction Stop
    } catch {
        Write-Error "Could not load Horizon PowerCLI. Install VMware.PowerCLI or add the View snap-in."
        exit 1
    }
}

try {
    $hvServer = Connect-HVServer -Server $HorizonServer -Credential $HorizonCredential -ErrorAction Stop
    $services  = $hvServer.ExtensionData
} catch {
    Write-Error "Failed to connect to Horizon: $_"
    exit 1
}

# ── 3. Build a lookup: MachineDnsName → most recent login ───
Write-Host "[3/4] Querying Horizon session data..." -ForegroundColor Cyan

$queryService = New-Object VMware.Hv.QueryServiceService
$queryDef     = New-Object VMware.Hv.QueryDefinition
$queryDef.queryEntityType = "SessionLocalSummaryView"

$sessionResults = @()
try {
    $queryResult = $queryService.QueryService_Create($services, $queryDef)
    $sessionResults += $queryResult.Results
    while ($queryResult.RemainingCount -gt 0) {
        $queryResult = $queryService.QueryService_GetNext($services, $queryResult.Id)
        $sessionResults += $queryResult.Results
    }
    $queryService.QueryService_Delete($services, $queryResult.Id)
} catch {
    Write-Warning "Session query encountered an issue (may be normal if no active sessions): $_"
}

# Hashtable: FQDN (lowercase) → most recent session start time
$sessionMap = @{}
foreach ($session in $sessionResults) {
    $dns       = $session.NamesData.MachineOrRDSServerDnsName.ToLower()
    $loginTime = $session.SessionData.StartTime

    if (-not $sessionMap.ContainsKey($dns) -or $loginTime -gt $sessionMap[$dns]) {
        $sessionMap[$dns] = $loginTime
    }
}

Write-Host "  Retrieved $($sessionResults.Count) session record(s)." -ForegroundColor Gray

# ── 4. Match each row and enrich with AD info ────────────────
Write-Host "[4/4] Building report..." -ForegroundColor Cyan

$results = foreach ($row in $vdiList) {
    $machineFqdn = ($row."DNS Name"      -as [string]).Trim().ToLower()
    $rawUser     = ($row."Assigned User" -as [string]).Trim()

    # Parse 'domain.fqdn\username' → split domain and sAMAccountName
    $samAccount = $rawUser
    $userDomain = ""
    if ($rawUser -match '^(.+)\\(.+)$') {
        $userDomain = $Matches[1]   # e.g. corp.contoso.com
        $samAccount = $Matches[2]   # e.g. jsmith
    }

    # Last login from Horizon session data (matched on FQDN)
    $lastLogin = $sessionMap[$machineFqdn]

    # AD lookup — target the domain FQDN directly so multi-domain environments work
    $adLastLogon   = $null
    $adDisplayName = $null
    $adEnabled     = $null
    try {
        $adParams = @{
            Identity    = $samAccount
            Properties  = @("LastLogonDate", "DisplayName", "Enabled")
            ErrorAction = "Stop"
        }
        if ($userDomain) { $adParams["Server"] = $userDomain }

        $adUser        = Get-ADUser @adParams
        $adLastLogon   = $adUser.LastLogonDate
        $adDisplayName = $adUser.DisplayName
        $adEnabled     = $adUser.Enabled
    } catch {
        Write-Warning "  AD lookup failed for '$samAccount' (domain: $userDomain): $_"
    }

    [PSCustomObject]@{
        MachineFQDN         = $row."DNS Name"
        AssignedUser        = $rawUser
        SamAccountName      = $samAccount
        Domain              = $userDomain
        DisplayName         = $adDisplayName
        ADAccountEnabled    = $adEnabled
        HorizonLastLogin    = if ($lastLogin)   { $lastLogin.ToString("yyyy-MM-dd HH:mm:ss") } else { "No session found" }
        ADLastLogonDate     = if ($adLastLogon) { $adLastLogon.ToString("yyyy-MM-dd HH:mm:ss") } else { "N/A" }
    }
}

# ── Display results ──────────────────────────────────────────
$results | Format-Table -AutoSize

# ── Optional CSV export ──────────────────────────────────────
if ($OutputCsv) {
    $results | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Host "`nResults saved to: $OutputCsv" -ForegroundColor Green
}

# ── Disconnect ───────────────────────────────────────────────
Disconnect-HVServer -Server $hvServer -Confirm:$false
Write-Host "Done." -ForegroundColor Green
