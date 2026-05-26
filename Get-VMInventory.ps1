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
    .\Get-VMInventory.ps1

.EXAMPLE
    $cred = Get-Credential
    .\Get-VMInventory.ps1 -vCenterServers vcsa01.lab.local,vcsa02.lab.local -Credential $cred

.NOTES
    Requires: VMware.PowerCLI 13.x or later (vCenter 8.0.x compatible)
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

Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null
Set-PowerCLIConfiguration -ParticipateInCeip $false       -Scope Session -Confirm:$false | Out-Null

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
    # 1a.  Retrieve all VMs
    # ---------------------------------------------------------
    Write-Host "  Retrieving VMs ..." -ForegroundColor Gray

    $allVMs = Get-VM -Server $viServer

    Write-Host "  Found $($allVMs.Count) VMs. Fetching tags (this may take a while) ..." -ForegroundColor Gray

    # ---------------------------------------------------------
    # 1b.  Process each VM — get tags via Get-TagAssignment
    # ---------------------------------------------------------
    $vmIndex = 0
    foreach ($vm in $allVMs) {

        $vmIndex++
        Write-Progress -Activity "[$vcsa] Collecting tags" `
                       -Status   "$vmIndex of $($allVMs.Count): $($vm.Name)" `
                       -PercentComplete (($vmIndex / $allVMs.Count) * 100)

        # Get-TagAssignment accepts a VM object directly — no -EntityType needed
        $tags = Get-TagAssignment -Entity $vm -Server $viServer |
                ForEach-Object { "$($_.Tag.Category.Name):$($_.Tag.Name)" } |
                Sort-Object

        $tagList = $tags -join '; '

        $allVMRecords.Add([PSCustomObject]@{
            VCSA        = $viServer.Name
            VMName      = $vm.Name
            DNSName     = $vm.Guest.HostName
            Description = $vm.Notes
            Tags        = $tagList
        })
    }

    Write-Progress -Activity "[$vcsa] Collecting tags" -Completed
    Write-Host "  Processed $($allVMs.Count) VMs from $vcsa." -ForegroundColor Green

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
