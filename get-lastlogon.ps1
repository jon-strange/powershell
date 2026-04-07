Import-Module ActiveDirectory

$VMs = @("VM01", "VM02", "VM03")

$Results = foreach ($VM in $VMs) {
    
    # --- AD Query (separate try/catch so its failure is isolated) ---
    $LastLogonDate = $null
    try {
        $Computer = Get-ADComputer -Identity $VM -Properties LastLogonDate -ErrorAction Stop
        $LastLogonDate = $Computer.LastLogonDate
    }
    catch {
        Write-Warning "[$VM] Failed to query AD: $($_.Exception.Message)"
    }

    # --- Event Log Query (separate try/catch so AD result is preserved) ---
    $Event = $null
    try {
        if ($LastLogonDate) {
            $Event = Get-WinEvent -ComputerName $VM -FilterHashtable @{
                LogName   = 'Security'
                Id        = 4624
                StartTime = $LastLogonDate.AddDays(-90)
                EndTime   = $LastLogonDate.AddMinutes(5)
            } -ErrorAction Stop |
            Where-Object {
                $_.Properties[5].Value -notmatch '^\$'
                $_.Properties[5].Value -notin @('SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE', 'ANONYMOUS LOGON')
                $_.Properties[8].Value -in @(2, 10)
            } | Select-Object -First 1
        }
    }
    catch {
        Write-Warning "[$VM] Failed to query Event Log: $($_.Exception.Message)"
    }

    # --- Build result regardless of which queries succeeded ---
    [PSCustomObject]@{
        VM             = $VM
        LastLogonDate  = if ($LastLogonDate) { $LastLogonDate } else { "AD query failed" }
        LastLoggedUser = if ($Event) { $Event.Properties[5].Value } else { "No interactive logon found" }
        EventTime      = if ($Event) { $Event.TimeCreated } else { "N/A" }
        LogonType      = if ($Event) {
                            switch ($Event.Properties[8].Value) {
                                2  { "Interactive (Local)" }
                                10 { "RemoteInteractive (RDP)" }
                            }
                         } else { "N/A" }
        Status         = switch {
                            (-not $LastLogonDate)  { "AD query failed" }
                            (-not $Event)          { "No interactive event found" }
                            default                { "OK" }
                         }
    }
}

$Results | Format-Table -AutoSize
