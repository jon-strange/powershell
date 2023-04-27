function ReportMissingOUs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceOU,
        [Parameter(Mandatory = $true)]
        [string]$TargetOU
    )

    # Get all child OUs of the source OU
    $sourceChildOUs = Get-ADOrganizationalUnit -SearchBase $SourceOU -SearchScope OneLevel

    # Get all child OUs of the target OU
    $targetChildOUs = Get-ADOrganizationalUnit -SearchBase $TargetOU -SearchScope OneLevel

    # Compare the source and target child OUs and output any missing OUs
    foreach ($childOU in $sourceChildOUs) {
        $ouName = $childOU.Name
        $ouExists = $targetChildOUs | Where-Object {$_.Name -eq $ouName}
        if (!$ouExists) {
            Write-Output "OU '$ouName' is missing from target OU structure."
            CreateMissingOU -OU $childOU -TargetOU $TargetOU
        }
    }
}

function CreateMissingOU {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.ActiveDirectory.Management.ADOrganizationalUnit]$OU,
        [Parameter(Mandatory = $true)]
        [string]$TargetOU
    )

    $createOU = Read-Host "Do you want to create OU '$($OU.Name)'? (Y/N)"
    if ($createOU -eq "Y") {
        $parentOU = $OU.ParentContainer
        New-ADOrganizationalUnit -Name $OU.Name -Path $parentOU
        Write-Output "Created OU '$($OU.DistinguishedName)'."
    }
}

# Set the source and target OUs
$sourceOU = "OU=SourceOU,DC=example,DC=com"
$targetOU = "OU=TargetOU,DC=example,DC=com"

# Report any missing OUs and create them if desired
ReportMissingOUs -SourceOU $sourceOU -TargetOU $targetOU
