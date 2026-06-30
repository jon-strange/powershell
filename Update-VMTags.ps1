#Requires -Modules VMware.PowerCLI
<#
.SYNOPSIS
    Updates VM Tags across multiple vCenter Servers using a CSV exported by Get-VMInventory.ps1.

.DESCRIPTION
    Reads the inventory CSV. For each row, connects to the VCSA listed, compares the Tags
    column to the VM's current tag assignments, then:
      - Assigns any tags present in the CSV that are NOT currently on the VM
      - Removes any tags currently on the VM that are NOT in the CSV
    Tags must already exist in vCenter (Category:TagName). This script will NOT create
    new Categories or Tags — it only assigns/removes existing ones.

    Tags column format (same as exported):  "Category1:TagName1; Category2:TagName2"
    Leave the Tags cell EMPTY to remove ALL tags from a VM.

.PARAMETER CsvPath
    Path to the CSV file produced by Get-VMInventory.ps1 (edited with desired tag changes).

.PARAMETER Credential
    PSCredential for all vCenter connections. Prompted if omitted.

.PARAMETER WhatIf
    Show what would change without making any modifications.

.EXAMPLE
    .\Update-VMTags.ps1 -CsvPath .\VM-Inventory_20240101_120000.csv -WhatIf
    .\Update-VMTags.ps1 -CsvPath .\VM-Inventory_20240101_120000.csv

.NOTES
    Requires: VMware.PowerCLI 13.x or later (vCenter 8.0.x compatible)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $CsvPath,

    [PSCredential] $Credential
)

# ─────────────────────────────────────────────────────────────
# 0.  SETUP
# ─────────────────────────────────────────────────────────────

Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null
Set-PowerCLIConfiguration -ParticipateInCeip $false       -Scope Session -Confirm:$false | Out-Null

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV not found: $CsvPath"
    exit 1
}

if (-not $Credential) {
    Write-Host "Enter credentials for vCenter access:" -ForegroundColor Cyan
    $Credential = Get-Credential
}

$csvData = Import-Csv -Path $CsvPath

# Group rows by VCSA so we only connect once per vCenter
$byVCSA = $csvData | Group-Object -Property VCSA

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# ─────────────────────────────────────────────────────────────
# 1.  PROCESS EACH VCENTER
# ─────────────────────────────────────────────────────────────

foreach ($group in $byVCSA) {

    $vcsaName = $group.Name
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Connecting to $vcsaName ..." -ForegroundColor Cyan

    try {
        $viServer = Connect-VIServer -Server $vcsaName -Credential $Credential -ErrorAction Stop
        Write-Host "  Connected." -ForegroundColor Green
    }
    catch {
        Write-Warning "  FAILED to connect to $vcsaName — $($_.Exception.Message). Skipping."
        foreach ($row in $group.Group) {
            $results.Add([PSCustomObject]@{
                VCSA    = $vcsaName
                VMName  = $row.VMName
                Status  = "SKIPPED — vCenter connection failed"
                Changes = ''
            })
        }
        continue
    }

    # Cache all tags on this vCenter for fast lookup: "Category:TagName" -> Tag object
    $tagCache = @{}
    Get-Tag -Server $viServer | ForEach-Object {
        $tagCache["$($_.Category.Name):$($_.Name)"] = $_
    }

    # Batch-load all current tag assignments on this vCenter
    # Note: -EntityType is not supported in all PowerCLI versions; filter client-side instead
    $currentAssignments = @{}   # MoRef string -> HashSet of "Category: Tag Name"
    Get-TagAssignment -Server $viServer | Where-Object { $_.Entity.GetType().Name -eq 'VirtualMachineImpl' } | ForEach-Object {
        $moRef = $_.Entity.Id
        if (-not $currentAssignments.ContainsKey($moRef)) {
            $currentAssignments[$moRef] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
        [void]$currentAssignments[$moRef].Add("$($_.Tag.Category.Name):$($_.Tag.Name)")
    }

    # ---------------------------------------------------------
    # Process each VM row for this vCenter
    # ---------------------------------------------------------
    foreach ($row in $group.Group) {

        $vmName = $row.VMName

        # Desired tags from CSV (split on semicolon, trim whitespace, drop empties)
        $desiredTags = if ([string]::IsNullOrWhiteSpace($row.Tags)) {
            @()
        } else {
            $row.Tags -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        }

        try {
            $vmObj = Get-VM -Name $vmName -Server $viServer -ErrorAction Stop
        }
        catch {
            Write-Warning "  VM '$vmName' not found on $vcsaName. Skipping."
            $results.Add([PSCustomObject]@{
                VCSA    = $vcsaName
                VMName  = $vmName
                Status  = "SKIPPED — VM not found"
                Changes = ''
            })
            continue
        }

        $moRef        = $vmObj.Id
        $currentSet   = if ($currentAssignments.ContainsKey($moRef)) { $currentAssignments[$moRef] } `
                        else { [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
        $desiredSet   = [System.Collections.Generic.HashSet[string]]::new([string[]]$desiredTags, [System.StringComparer]::OrdinalIgnoreCase)

        $toAdd    = $desiredSet | Where-Object { -not $currentSet.Contains($_) }
        $toRemove = $currentSet | Where-Object { -not $desiredSet.Contains($_) }

        $changeLog = [System.Collections.Generic.List[string]]::new()
        $errors    = [System.Collections.Generic.List[string]]::new()

        # -- ADD tags --
        foreach ($tagLabel in $toAdd) {
            if (-not $tagCache.ContainsKey($tagLabel)) {
                $errors.Add("Tag not found in vCenter: '$tagLabel'")
                Write-Warning "  [$vmName] Tag '$tagLabel' does not exist on $vcsaName — skipping."
                continue
            }
            if ($PSCmdlet.ShouldProcess($vmName, "Assign tag '$tagLabel'")) {
                try {
                    New-TagAssignment -Tag $tagCache[$tagLabel] -Entity $vmObj -Server $viServer -ErrorAction Stop | Out-Null
                    $changeLog.Add("+$tagLabel")
                }
                catch {
                    $errors.Add("Failed to assign '$tagLabel': $($_.Exception.Message)")
                }
            } else {
                $changeLog.Add("[WhatIf] +$tagLabel")
            }
        }

        # -- REMOVE tags --
        foreach ($tagLabel in $toRemove) {
            if (-not $tagCache.ContainsKey($tagLabel)) {
                # Tag was on VM but no longer exists in vCenter — nothing to remove
                continue
            }
            if ($PSCmdlet.ShouldProcess($vmName, "Remove tag '$tagLabel'")) {
                try {
                    $assignment = Get-TagAssignment -Entity $vmObj -Tag $tagCache[$tagLabel] -Server $viServer -ErrorAction Stop
                    Remove-TagAssignment -TagAssignment $assignment -Confirm:$false -ErrorAction Stop
                    $changeLog.Add("-$tagLabel")
                }
                catch {
                    $errors.Add("Failed to remove '$tagLabel': $($_.Exception.Message)")
                }
            } else {
                $changeLog.Add("[WhatIf] -$tagLabel")
            }
        }

        $status = if ($errors.Count -gt 0) { "PARTIAL ERROR" }
                  elseif ($changeLog.Count -eq 0) { "NO CHANGE" }
                  else { "UPDATED" }

        if ($errors.Count -gt 0) { $changeLog.AddRange($errors) }

        $results.Add([PSCustomObject]@{
            VCSA    = $vcsaName
            VMName  = $vmName
            Status  = $status
            Changes = $changeLog -join ' | '
        })

        $color = switch ($status) {
            'UPDATED'       { 'Green'  }
            'NO CHANGE'     { 'Gray'   }
            'PARTIAL ERROR' { 'Yellow' }
            default         { 'White'  }
        }
        Write-Host "  [$status] $vmName  $($changeLog -join ' | ')" -ForegroundColor $color
    }

    Disconnect-VIServer -Server $viServer -Confirm:$false
    Write-Host "  Disconnected from $vcsaName." -ForegroundColor Gray
}

# ─────────────────────────────────────────────────────────────
# 2.  SUMMARY REPORT
# ─────────────────────────────────────────────────────────────

$reportPath = ".\Tag-Update-Report_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8

Write-Host "`n── Summary ──────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Total processed : $($results.Count)"
Write-Host "  Updated         : $(($results | Where-Object Status -eq 'UPDATED').Count)" -ForegroundColor Green
Write-Host "  No change       : $(($results | Where-Object Status -eq 'NO CHANGE').Count)" -ForegroundColor Gray
Write-Host "  Partial errors  : $(($results | Where-Object Status -eq 'PARTIAL ERROR').Count)" -ForegroundColor Yellow
Write-Host "  Skipped         : $(($results | Where-Object Status -like 'SKIPPED*').Count)" -ForegroundColor Red
Write-Host "  Report saved to : $reportPath" -ForegroundColor Cyan
