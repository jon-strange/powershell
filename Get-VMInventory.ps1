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
    Uses the vCenter CIS REST API (/rest/com/vmware/cis/tagging/) for tag retrieval,
    which is compatible across all vCenter 8.0.x builds regardless of PowerCLI version.
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

# PowerShell 5.1 does not support -SkipCertificateCheck on Invoke-RestMethod.
# This bypass covers self-signed vCenter certs on Windows PowerShell.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [System.Net.ServicePointManager]::SecurityProtocol  = [System.Net.SecurityProtocolType]::Tls12
}

# Prompt for credentials once if not supplied
if (-not $Credential) {
    Write-Host "Enter credentials for vCenter access (used for all VCSAs):" -ForegroundColor Cyan
    $Credential = Get-Credential
}

# Build Invoke-RestMethod common parameters depending on PS version
$irmCommon = if ($PSVersionTable.PSVersion.Major -ge 6) {
    @{ SkipCertificateCheck = $true }
} else {
    @{}   # cert bypass already applied globally above
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
    # 1a.  Retrieve all VMs via Get-View (fast bulk retrieval)
    # ---------------------------------------------------------
    Write-Host "  Retrieving VMs ..." -ForegroundColor Gray

    $vmViews = Get-View -Server $viServer -ViewType VirtualMachine `
                        -Property 'Name','Config.Annotation','Guest.HostName' `
                        -Filter @{ 'Config.Template' = 'False' } `
                        -ErrorAction Stop

    Write-Host "  Found $($vmViews.Count) VMs. Fetching Tags ..." -ForegroundColor Gray

    # ---------------------------------------------------------
    # 1b.  Build MoRef -> Tag list map via vCenter CIS REST API
    #
    #      The PowerCLI Get-TagAssignment cmdlet dropped the -EntityType
    #      parameter in newer releases, making bulk retrieval impossible.
    #      The CIS REST API is the supported alternative and works on all
    #      vCenter 8.0.x builds.
    #
    #      Endpoint base: /rest/com/vmware/cis/tagging/
    # ---------------------------------------------------------
    $tagAssignments = @{}   # Key = "VirtualMachine:vm-NNN"  Value = List[string]

    try {
        $baseUri = "https://$($viServer.Name)"

        # -- Authenticate: POST /rest/com/vmware/cis/session --
        $authBytes = [System.Text.Encoding]::UTF8.GetBytes(
            "$($Credential.UserName):$($Credential.GetNetworkCredential().Password)")
        $authB64   = [Convert]::ToBase64String($authBytes)

        $cisSession = Invoke-RestMethod `
            -Uri     "$baseUri/rest/com/vmware/cis/session" `
            -Method  Post `
            -Headers @{ Authorization = "Basic $authB64" } `
            @irmCommon

        $cisToken = $cisSession.value
        $restHdr  = @{
            'vmware-api-session-id' = $cisToken
            'Content-Type'          = 'application/json'
        }

        # -- Step 1: Get all tag IDs --
        # GET /rest/com/vmware/cis/tagging/tag
        $tagListResp = Invoke-RestMethod `
            -Uri     "$baseUri/rest/com/vmware/cis/tagging/tag" `
            -Method  Get `
            -Headers $restHdr `
            @irmCommon

        $allTagIds    = @($tagListResp.value)
        $tagIdToLabel = @{}
        $catCache     = @{}

        Write-Host "  Resolving $($allTagIds.Count) tags to Category:Name labels ..." -ForegroundColor Gray

        # -- Step 2: Resolve each tag ID to "Category:TagName" --
        foreach ($tagId in $allTagIds) {
            $tagDetail = Invoke-RestMethod `
                -Uri     "$baseUri/rest/com/vmware/cis/tagging/tag/$tagId" `
                -Method  Get `
                -Headers $restHdr `
                @irmCommon

            $catId = $tagDetail.value.category_id

            if (-not $catCache.ContainsKey($catId)) {
                $catDetail       = Invoke-RestMethod `
                    -Uri     "$baseUri/rest/com/vmware/cis/tagging/category/$catId" `
                    -Method  Get `
                    -Headers $restHdr `
                    @irmCommon
                $catCache[$catId] = $catDetail.value.name
            }

            $tagIdToLabel[$tagId] = "$($catCache[$catId]):$($tagDetail.value.name)"
        }

        # -- Step 3: Bulk-fetch which objects each tag is assigned to --
        # POST /rest/com/vmware/cis/tagging/tag-association
        #      ?~action=list-attached-objects-on-tags
        # Body: { "tag_ids": [ "id1", "id2", ... ] }
        $chunkSize = 500
        for ($i = 0; $i -lt $allTagIds.Count; $i += $chunkSize) {
            $chunk = $allTagIds[$i .. ([Math]::Min($i + $chunkSize - 1, $allTagIds.Count - 1))]
            $body  = @{ tag_ids = $chunk } | ConvertTo-Json -Compress

            $assocResp = Invoke-RestMethod `
                -Uri     "$baseUri/rest/com/vmware/cis/tagging/tag-association?~action=list-attached-objects-on-tags" `
                -Method  Post `
                -Headers $restHdr `
                -Body    $body `
                @irmCommon

            foreach ($entry in $assocResp.value) {
                $label = $tagIdToLabel[$entry.tag_id]
                foreach ($obj in $entry.object_ids) {
                    if ($obj.type -ne 'VirtualMachine') { continue }
                    $key = "VirtualMachine:$($obj.id)"
                    if (-not $tagAssignments.ContainsKey($key)) {
                        $tagAssignments[$key] = [System.Collections.Generic.List[string]]::new()
                    }
                    $tagAssignments[$key].Add($label)
                }
            }
        }

        # Clean up REST session
        Invoke-RestMethod `
            -Uri     "$baseUri/rest/com/vmware/cis/session" `
            -Method  Delete `
            -Headers $restHdr `
            @irmCommon | Out-Null

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

        # Key must match REST API format: "VirtualMachine:vm-NNN"
        $moRefStr = "$($vm.MoRef.Type):$($vm.MoRef.Value)"

        $tagList = if ($tagAssignments.ContainsKey($moRefStr)) {
            ($tagAssignments[$moRefStr].ToArray() | Sort-Object) -join '; '
        } else {
            ''
        }

        $allVMRecords.Add([PSCustomObject]@{
            VCSA        = $viServer.Name
            VMName      = $vm.Name
            DNSName     = $vm.Guest.HostName
            Description = $vm.Config.Annotation
            Tags        = $tagList
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
