# Prompt user for input string
$inputString = Read-Host "Enter computer name to search for"

# Get the first three characters from the input string, which represent the region in GCP
$gcpRegion = $inputString.Substring(0, 3)

# Get the next two characters from the input string, which represent the production environment
$prodEnv = $inputString.Substring(3, 2)

# Construct the filter to find computers in the physical datacenter OUs with names matching the pattern
$filter = "(Name -like '*$($inputString.Substring(5))*') -and (DistinguishedName -like '*OU=Infrastructure Servers,DC=us,DC=saas' -or DistinguishedName -like '*OU=Enterprise Servers,DC=us,DC=saas' -or DistinguishedName -like '*OU=MidMarket Servers,DC=us,DC=saas' -or DistinguishedName -like '*OU=Payment Services File Servers,DC=us,DC=saas')"


# Search for matching computers in Active Directory
$matchingComputers = Get-ADComputer -Filter $filter -Properties Name,DistinguishedName

# Calculate the count of matching computers in each physical datacenter OU
$infraServersCount = ($matchingComputers | Where-Object {$_.DistinguishedName -like '*,OU=Infrastructure Servers,DC=us,DC=saas'}).Count
$enterpriseServersCount = ($matchingComputers | Where-Object {$_.DistinguishedName -like '*,OU=Enterprise Servers,DC=us,DC=saas'}).Count
$midMarketServersCount = ($matchingComputers | Where-Object {$_.DistinguishedName -like '*,OU=MidMarket Servers,DC=us,DC=saas'}).Count
$paymentServicesCount = ($matchingComputers | Where-Object {$_.DistinguishedName -like '*,OU=Payment Services File Servers,DC=us,DC=saas'}).Count

# Determine the physical datacenter OU with the most matching computers
$counts = @{
    "Infrastructure Servers" = $infraServersCount
    "Enterprise Servers" = $enterpriseServersCount
    "MidMarket Servers" = $midMarketServersCount
    "Payment Services File Servers" = $paymentServicesCount
}
$maxCount = ($counts.Values | Measure-Object -Maximum).Maximum
$mostLikelyOu = ($counts.GetEnumerator() | Where-Object {$_.Value -eq $maxCount}).Name


# Construct the OU path for the recommended location in the Public Cloud OU structure
$ouPath = "OU=$mostLikelyOu,OU=$gcpRegion,OU=$mostLikelyOu,OU=GCP,DC=us,DC=saas"

# Display the recommended OU path for the new server
"Recommended OU path for $inputString: $ouPath"
