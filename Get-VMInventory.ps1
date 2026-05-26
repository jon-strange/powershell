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
    # 1b.  Build a MoRef → Tag list map via vSphere REST API
    #      (avoids -EntityType which was removed from Get-TagAssignment
    #       in newer PowerCLI releases)
    # ---------------------------------------------------------
    $tagAssignments = @{}    # Key = "VirtualMachine:vm-NNN", Value = List[string] "Cat:Tag"

    try {
        # Reuse the session token that Connect-VIServer already established
        $sessionToken = $viServer.SessionSecret

        $baseUri  = "https://$($viServer.Name)"
        $headers  = @{
            'vmware-api-session-id' = $sessionToken
            'Content-Type'          = 'application/json'
        }

        # --- Build a tag-id → "Category:Name" lookup ---
        # GET /api/tagging/tag  returns all tag IDs
        $allTagIds = Invoke-RestMethod -Uri "$baseUri/api/tagging/tag" `
                                       -Headers $headers -Method Get -SkipCertificateCheck

        $tagIdToLabel = @{}   # tag-id -> "Category:Name"

        foreach ($tagId in $allTagIds) {
            $tagDetail = Invoke-RestMethod -Uri "$baseUri/api/tagging/tag/$tagId" `
                                           -Headers $headers -Method Get -SkipCertificateCheck

            $catDetail = Invoke-RestMethod -Uri "$baseUri/api/tagging/category/$($tagDetail.category_id)" `
                                           -Headers $headers -Method Get -SkipCertificateCheck

            $tagIdToLabel[$tagId] = "$($catDetail.name):$($tagDetail.name)"
        }

        # --- For each tag, get which objects it is assigned to ---
        # POST /api/tagging/tag-association?action=list-attached-objects-on-tags
        # Accepts up to 2000 tag IDs per call — chunk if necessary
        $chunkSize  = 500
        $allTagIdList = @($allTagIds)

        for ($i = 0; $i -lt $allTagIdList.Count; $i += $chunkSize) {
            $chunk = $allTagIdList[$i .. ([Math]::Min($i + $chunkSize - 1, $allTagIdList.Count - 1))]

            $body     = $chunk | ConvertTo-Json -Compress
            $response = Invoke-RestMethod `
                            -Uri "$baseUri/api/tagging/tag-association?action=list-attached-objects-on-tags" `
                            -Headers $headers -Method Post -Body $body -SkipCertificateCheck

            foreach ($entry in $response) {
                $label = $tagIdToLabel[$entry.tag_id]

                foreach ($obj in $entry.object_ids) {
                    # Only care about VirtualMachine objects
                    if ($obj.type -ne 'VirtualMachine') { continue }

                    $key = "VirtualMachine:$($obj.id)"   # e.g. "VirtualMachine:vm-123"

                    if (-not $tagAssignments.ContainsKey($key)) {
                        $tagAssignments[$key] = [System.Collections.Generic.List[string]]::new()
                    }
                    $tagAssignments[$key].Add($label)
                }
            }
        }

        Write-Host "  Tag map built: $($tagAssignments.Count) VMs have at least one tag." -ForegroundColor Gray
    }
    catch {
        Write-Warning "  Could not retrieve tag assignments from $vcsa — $($_.Exception.Message)"
        Write-Warning "  Tags will be empty for all VMs on this vCenter."
    }

    # ---------------------------------------------------------
    # 1c.  Build output rows
    # ---------------------------------------------------------
    foreach ($vm in $vmViews) {

        # REST API key format:  "VirtualMachine:vm-NNN"
        $moRefStr = "$($vm.MoRef.Type):$($vm.MoRef.Value)"   # e.g. "VirtualMachine:vm-123"

        # Tags: semicolon-separated "Category:TagName" strings, sorted for readability
        $tagList = if ($tagAssignments.ContainsKey($moRefStr)) {
            ($tagAssignments[$moRefStr].ToArray() | Sort-Object) -join '; '
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
