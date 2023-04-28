# Prompt user for input string
$inputString = Read-Host "Enter string to search for"

# Remove first 3 and last characters from input string
$searchString = $inputString.Substring(3, $inputString.Length - 4)

# Search for computer objects in Active Directory matching the pattern
Get-ADComputer -Filter {Name -like "*$searchString*"} -Properties Name
