# Connect to the vCenter server
Connect-VIServer -Server "vcenter.domain.com"

# Prompt securely for the new root password
$newPassword = Read-Host -Prompt "Enter the new root password" -AsSecureString

# Retrieve all ESXi hosts from the connected vCenter
$vmhosts = Get-VMHost

foreach ($vmhost in $vmhosts) {
    Write-Host "Processing host: $($vmhost.Name)"

    try {
        # Retrieve the 'root' user account on this host
        $account = $vmhost | Get-VMHostAccount -User "root"

        if ($account -ne $null) {
            # Update the password for the root account
            $account | Set-VMHostAccount -Password $newPassword -Confirm:$false
            Write-Host "Successfully changed password on $($vmhost.Name)" -ForegroundColor Green
        } else {
            Write-Host "Root account not found on $($vmhost.Name)" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Failed to update $($vmhost.Name): $_" -ForegroundColor Red
    }
}

# Disconnect from the vCenter server
Disconnect-VIServer -Confirm:$false
