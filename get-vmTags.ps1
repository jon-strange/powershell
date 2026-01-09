# Requires: VMware.PowerCLI
# Purpose: List all VMs that do NOT have any RP00# tags (RP001..RP005)

# Connect-VIServer -Server vcenter.example.com

$rpTags = @('RP001','RP002','RP003','RP004','RP005')

# Get all VMs once
$vms = Get-VM

# Get all tag assignments for those VMs once (much faster than per-VM calls)
$assignments = Get-TagAssignment -Entity $vms -ErrorAction SilentlyContinue

# Build a lookup: VM Id -> list of tag names
$tagsByVmId = @{}
foreach ($a in $assignments) {
    $vmId = $a.Entity.Id
    if (-not $tagsByVmId.ContainsKey($vmId)) {
        $tagsByVmId[$vmId] = New-Object System.Collections.Generic.List[string]
    }
    [void]$tagsByVmId[$vmId].Add($a.Tag.Name)
}

# Find VMs with none of the RP00 tags
$results = foreach ($vm in $vms) {
    $vmTags = @()
    if ($tagsByVmId.ContainsKey($vm.Id)) {
        $vmTags = $tagsByVmId[$vm.Id]
    }

    $hasRp = $false
    foreach ($t in $rpTags) {
        if ($vmTags -contains $t) { $hasRp = $true; break }
    }

    if (-not $hasRp) {
        [pscustomobject]@{
            VMName = $vm.Name
            # Optional: show existing tags to help remediation
            CurrentTags = ($vmTags -join ';')
        }
    }
}

# Output
$results | Sort-Object VMName

# Optional CSV export
# $results | Sort-Object VMName | Export-Csv -NoTypeInformation -Path .\VMs_Missing_RP00_Tags.csv
