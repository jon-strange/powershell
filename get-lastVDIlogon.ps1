# ============================================================
# Get-VDILastLogin.ps1
# Reads VDI machine names and assigned users from an Excel
# spreadsheet and reports each user's last login time on
# their assigned Horizon VDI machine.
#
# Requirements:
#   - VMware.VimAutomation.HorizonView module  (Horizon PowerCLI)
#   - ImportExcel module  (Install-Module ImportExcel)
#   - ActiveDirectory module  (RSAT)
#   - Run as a user with Horizon read access + AD read access
# ============================================================

#Requires -Modules ImportExcel, ActiveDirectory

[CmdletBinding()]
param (
    # Path to your Excel file
    [Parameter(Mandatory)]
    [string]$ExcelPath,

    # Sheet name (defaults to first sheet if omitted)
    [string]$SheetName,

    # Column header for the VDI DNS name
    [string]$MachineColumn = "DNS Name",

    # Column header for the assigned AD username
    [string]$UserColumn = "Assigned User",

    # Your Horizon Connection Server hostname or IP
    [Parameter(Mandatory)]
    [string]$HorizonServer,

    # Credentials for the Horizon Connection Server
    [System.Management.Automation.PSCredential]$HorizonCredential = (Get-Credential -Message "Horizon Connection Server credentials"),

    # Where to save the results (CSV). Leave blank to only display on screen.
    [string]$OutputCsv = ""
)

# ── 1. Import the spreadsheet ────────────────────────────────
Write-Host "[1/4] Reading Excel file: $ExcelPath" -ForegroundColor Cyan

$importParams = @{ Path = $ExcelPath; ImportColumns = @($MachineColumn, $UserColumn) }
if ($SheetName) { $importParams["WorksheetName"] = $SheetName }

try {
    $vdiList = Import-Excel @importParams
} catch {
    Write-Error "Failed to read Excel file: $_"
    exit 1
}

if (-not $vdiList) {
    Write-Error "No data found in the spreadsheet. Check column names: '$MachineColumn', '$UserColumn'."
    exit 1
}

Write-Host "  Found $($vdiList.Count) row(s)." -ForegroundColor Gray

# ── 2. Connect to Horizon ────────────────────────────────────
Write-Host "[2/4] Connecting to Horizon Connection Server: $HorizonServer" -ForegroundColor Cyan

# Load the Horizon View snap-in if the module isn't available
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
    $services  = $hvServer.ExtensionData          # Horizon API services object
} catch {
    Write-Error "Failed to connect to Horizon: $_"
    exit 1
}

# ── 3. Build a lookup: MachineDnsName → last session info ───
Write-Host "[3/4] Querying Horizon session data..." -ForegroundColor Cyan

# Pull all desktop sessions (active + disconnected + historical if accessible)
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

# Build hashtable: DNS name (lowercase) → most recent login time
$sessionMap = @{}
foreach ($session in $sessionResults) {
    $dns       = $session.NamesData.MachineOrRDSServerDnsName.ToLower()
    $loginTime = $session.SessionData.StartTime      # DateTime of session start

    if (-not $sessionMap.ContainsKey($dns) -or $loginTime -gt $sessionMap[$dns]) {
        $sessionMap[$dns] = $loginTime
    }
}

Write-Host "  Retrieved $($sessionResults.Count) session record(s)." -ForegroundColor Gray

# ── 4. Match each row and enrich with AD info ────────────────
Write-Host "[4/4] Building report..." -ForegroundColor Cyan

$results = foreach ($row in $vdiList) {
    $machineDns  = ($row.$MachineColumn -as [string]).Trim().ToLower()
    $assignedUser = ($row.$UserColumn   -as [string]).Trim()

    # Last login from Horizon session data
    $lastLogin = $sessionMap[$machineDns]

    # Optionally pull AD last logon (domain-wide) for cross-reference
    $adLastLogon = $null
    $adDisplayName = $null
    $adEnabled   = $null
    try {
        $adUser = Get-ADUser -Identity $assignedUser `
                             -Properties LastLogonDate, DisplayName, Enabled `
                             -ErrorAction Stop
        $adLastLogon   = $adUser.LastLogonDate
        $adDisplayName = $adUser.DisplayName
        $adEnabled     = $adUser.Enabled
    } catch {
        Write-Warning "  AD lookup failed for '$assignedUser': $_"
    }

    [PSCustomObject]@{
        MachineDNS          = $row.$MachineColumn
        AssignedUser        = $assignedUser
        DisplayName         = $adDisplayName
        ADAccountEnabled    = $adEnabled
        HorizonLastLogin    = if ($lastLogin)    { $lastLogin.ToString("yyyy-MM-dd HH:mm:ss") } else { "No session found" }
        ADLastLogonDate     = if ($adLastLogon)  { $adLastLogon.ToString("yyyy-MM-dd HH:mm:ss") } else { "N/A" }
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
