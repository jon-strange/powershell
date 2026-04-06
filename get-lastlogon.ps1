

$VMs = @("VM01", "VM02", "VM03")

$Results = foreach ($VM in $VMs) {
    try {
        $Computer = Get-ADComputer -Identity $VM -Properties LastLogonDate -ErrorAction Stop

        # Find the last AD user who logged into this computer via logon events
        $LastUser = Invoke-Command -ComputerName $VM -ScriptBlock {
            (Get-WinEvent -FilterHashtable @{ LogName='Security'; Id=4624 } -MaxEvents 1 `
                -ErrorAction SilentlyContinue).Properties[5].Value
        } -ErrorAction SilentlyContinue

        [PSCustomObject]@{
            VM             = $VM
            LastADLogon    = $Computer.LastLogonDate
            LastLoggedUser = $LastUser
            Status         = "OK"
        }
    }
    catch {
        [PSCustomObject]@{
            VM             = $VM
            LastADLogon    = "N/A"
            LastLoggedUser = "N/A"
            Status         = "Error: $($_.Exception.Message)"
        }
    }
}

$Results | Format-Table -AutoSize
