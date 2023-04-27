# Set the source and target OUs
$sourceOU = "OU=SourceOU,DC=example,DC=com"
$targetOU = "OU=TargetOU,DC=example,DC=com"

# Get all child OUs of the source OU
$sourceChildOUs = Get-ADOrganizationalUnit -SearchBase $sourceOU -SearchScope OneLevel

# Get all child OUs of the target OU
$targetChildOUs = Get-ADOrganizationalUnit -SearchBase $targetOU -SearchScope OneLevel

# Compare the source and target child OUs and output any missing OUs
foreach ($childOU in $sourceChildOUs) {
    $ouName = $childOU.Name
    $ouExists = $targetChildOUs | Where-Object {$_.Name -eq $ouName}
    if (!$ouExists) {
        Write-Output "OU '$ouName' is missing from target OU structure."
    }
}
