$Results = foreach ($VM in $VMs) {
    try {
        $Computer = Get-ADComputer -Identity $VM -Properties LastLogonDate -ErrorAction Stop
        $LastLogonDate = $Computer.LastLogonDate

        # Define a narrow time window around LastLogonDate (±5 minutes to account for AD replication lag)
        $TimeStart = $LastLogonDate.AddMinutes(-5)
        $TimeEnd   = $LastLogonDate.AddMinutes(5)

        $Event = Get-WinEvent -ComputerName $VM -FilterHashtable @{
            LogName   = 'Security'
            Id        = 4624
            StartTime = $TimeStart
            EndTime   = $TimeEnd
        } -ErrorAction Stop |
        Where-Object {
            $_.Properties[5].Value -notmatch '^\$'
            $_.Properties[5].Value -notin @('SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE')
            $_.Properties[8].Value -in @(2, 10)   # Interactive & RemoteInteractive only
        } | Select-Object -First 1

        [PSCustomObject]@{
            VM             = $VM
            LastLogonDate  = $LastLogonDate
            LastLoggedUser = if ($Event) { $Event.Properties[5].Value } else { "No matching event found" }
            EventTime      = if ($Event) { $Event.TimeCreated } else { "N/A" }
            Status         = "OK"
        }
    }
    catch {
        [PSCustomObject]@{
            VM             = $VM
            LastLogonDate  = "N/A"
            LastLoggedUser = "N/A"
            EventTime      = "N/A"
            Status         = "Error: $($_.Exception.Message)"
        }
    }
}

$Results | Format-Table -AutoSize
