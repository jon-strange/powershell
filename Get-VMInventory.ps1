#Requires -Modules VMware.PowerCLI
<#
.SYNOPSIS
    Collects a VM inventory from multiple vCenter Server instances and exports to CSV.

.DESCRIPTION
    Connects to each vCenter Server defined in $vCenterServers, retrieves all VMs with:
      - VM Name
      - DNS Name (from VMware Tools guest info)
      - Description (Notes field)
      - All assigned Tags (semicolon-delimited; Category:Tag format)
      - VCSA (which vCenter the VM belongs to)
    Exports the combined results to a single CSV file.
    The CSV can be edited and re-imported to update Tags (see Update-VMTags.ps1).

.PARAMETER vCenterServers
    Array of vCenter Server FQDNs or IPs. Edit the defaults below or pass at runtime.

.PARAMETER OutputPath
    Full path for the exported CSV. Defaults to .\VM-Inventory_<timestamp>.csv

.PARAMETER Credential
    PSCredential to use for all vCenter connections.
    If omitted, you will be prompted once and the same credential is reused.

.EXAMPLE
    # Use default servers and prompt for credentials
    .\Get-VMInventory.ps1

.EXAMPLE
    # Specify servers and a credential object
    $cred = Get-Credential
    .\Get-VMInventory.ps1 -vCenterServers vcsa01.lab.local,vcsa02.lab.local -Credential $cred

.NOTES
    Requires: VMware.PowerCLI 13.x or later (vCenter 8.0.x compatible)
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore  (if using self-signed certs)
#>

[CmdletBinding()]
param(
    [string[]] $vCenterServers = @(
        'vcsa01.yourdomain.local',   # <-- Replace with your vCenter FQDNs / IPs
        'vcsa02.yourdomain.local',
        'vcsa03.yourdomain.local',
        'vcsa04.yourdomain.local'
    ),

    [string] $OutputPath = ".\VM-Inventory_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",

    [PSCredential] $Credential
)

# ─────────────────────────────────────────────────────────────
# 0.  INITIAL SETUP
# ─────────────────────────────────────────────────────────────

# Suppress certificate warnings for lab/self-signed environments.
# Remove or change to 'Fail' in production with valid certs.
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null
Set-PowerCLIConfiguration -ParticipateInCeip $false       -Scope Session -Confirm:$false | Out-Null

# Prompt for credentials once if not supplied
if (-not $Credential) {
    Write-Host "Enter credentials for vCenter access (used for all VCSAs):" -ForegroundColor Cyan
    $Credential = Get-Credential
}

$allVMRecords = [System.Collections.Generic.List[PSCustomObject]]::new()

# ─────────────────────────────────────────────────────────────
# 1.  ITERATE OVER EACH VCENTER
# ─────────────────────────────────────────────────────────────

foreach ($vcsa in $vCenterServers) {

    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Connecting to $vcsa ..." -ForegroundColor Cyan

    try {
        $viServer = Connect-VIServer -Server $vcsa -Credential $Credential -ErrorAction Stop
        Write-Host "  Connected: $($viServer.Name)  (vCenter $($viServer.Version))" -ForegroundColor Green
    }
    catch {
        Write-Warning "  FAILED to connect to $vcsa — $($_.Exception.Message). Skipping."
        continue
    }

    # ---------------------------------------------------------
    # 1a.  Retrieve all VMs — use Get-View for performance
    # ---------------------------------------------------------
    Write-Host "  Retrieving VMs ..." -ForegroundColor Gray

    $vmProperties = @(
        'Name',
        'Config.Annotation',          # Description / Notes
        'Guest.HostName',             # DNS name reported by VMware Tools
        'Summary.Config.GuestFullName'
    )

    $vmViews = Get-View -Server $viServer -ViewType VirtualMachine `
                        -Property $vmProperties `
                        -Filter @{ 'Config.Template' = 'False' } `
                        -ErrorAction Stop

    Write-Host "  Found $($vmViews.Count) VMs. Fetching Tags ..." -ForegroundColor Gray

    # ---------------------------------------------------------
    # 1b.  Build a MoRef → Tag list map (batch tag lookup)
    #      Get-TagAssignment is called once per vCenter, not per VM.
    # ---------------------------------------------------------
    $tagAssignments = @{}    # Key = VM MoRef string, Value = list of "Category/Tag" strings

    try {
        # Get all tag assignments for VirtualMachine objects on this vCenter
        $allAssignments = Get-TagAssignment -Server $viServer -EntityType VirtualMachine -ErrorAction Stop

        foreach ($ta in $allAssignments) {
            $moRefStr = $ta.Entity.Id   # e.g. "VirtualMachine-vm-123"
            $tagLabel  = "$($ta.Tag.Category.Name):$($ta.Tag.Name)"

            if (-not $tagAssignments.ContainsKey($moRefStr)) {
                $tagAssignments[$moRefStr] = [System.Collections.Generic.List[string]]::new()
            }
            $tagAssignments[$moRefStr].Add($tagLabel)
        }
    }
    catch {
        Write-Warning "  Could not retrieve tag assignments from $vcsa — $($_.Exception.Message)"
    }

    # ---------------------------------------------------------
    # 1c.  Build output rows
    # ---------------------------------------------------------
    foreach ($vm in $vmViews) {

        $moRefStr = "$($vm.MoRef.Type)-$($vm.MoRef.Value)"   # e.g. VirtualMachine-vm-123

        # Tags: semicolon-separated "Category:TagName" strings, sorted for readability
        $tagList = if ($tagAssignments.ContainsKey($moRefStr)) {
            ($tagAssignments[$moRefStr] | Sort-Object) -join '; '
        } else {
            ''
        }

        $allVMRecords.Add([PSCustomObject]@{
            VCSA        = $viServer.Name
            VMName      = $vm.Name
            DNSName     = $vm.Guest.HostName        # Empty if Tools not running / not installed
            Description = $vm.Config.Annotation     # VM Notes field
            Tags        = $tagList                  # "Cat1:Tag1; Cat2:Tag2" or empty
        })
    }

    Write-Host "  Processed $($vmViews.Count) VMs from $vcsa." -ForegroundColor Green
    Disconnect-VIServer -Server $viServer -Confirm:$false
    Write-Host "  Disconnected from $vcsa." -ForegroundColor Gray
}

# ─────────────────────────────────────────────────────────────
# 2.  EXPORT TO CSV
# ─────────────────────────────────────────────────────────────

if ($allVMRecords.Count -eq 0) {
    Write-Warning "No VM records collected. CSV will not be written."
    exit 1
}

Write-Host "`nExporting $($allVMRecords.Count) VM records to: $OutputPath" -ForegroundColor Cyan

$allVMRecords | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Export complete." -ForegroundColor Green
Write-Host ""
Write-Host "Column reference:" -ForegroundColor Yellow
Write-Host "  VCSA        — vCenter Server the VM belongs to"
Write-Host "  VMName      — Virtual Machine name"
Write-Host "  DNSName     — Hostname reported by VMware Tools"
Write-Host "  Description — VM Notes / Annotation field"
Write-Host "  Tags        — Semicolon-delimited list of Category:TagName pairs"
Write-Host ""
Write-Host "To update tags, edit the Tags column and run Update-VMTags.ps1 with this CSV." -ForegroundColor Cyan
