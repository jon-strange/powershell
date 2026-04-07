Import-Module ActiveDirectory

$VMs = @("VM01", "VM02", "VM03")
$ADDomain = (Get-ADDomain).NetBIOSName  # Dynamically pulls your AD domain name

$Results = foreach ($VM in $VMs) {

    # --- AD Query ---
    $LastLogonDate = $null
    try {
        $Computer = Get-ADComputer -Identity $VM -Properties LastLogonDate -ErrorAction Stop
        $LastLogonDate = $Computer.LastLogonDate
    }
    catch {
        Write-Warning "[$VM] Failed to query AD: $($_.Exception.Message)"
    }

    # --- Event Log Query ---
    $Event = $null
    try {
        $Event = Get-WinEvent -ComputerName $VM -FilterHashtable @{
            LogName = 'Security'
            Id      = 4624
        } -ErrorAction Stop |
        Where-Object {
            $_.Properties[5].Value -notmatch '^\$'             # Exclude machine accounts
            $_.Properties[5].Value -notin @('SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE', 'ANONYMOUS LOGON')
            $_.Properties[6].Value -eq $ADDomain               # Must match your AD domain
            $_.Properties[8].Value -in @(2, 10)                # Interactive & RDP only
        } | Select-Object -First 1
    }
    catch {
        Write-Warning "[$VM] Failed to query Event Log: $($_.Exception.Message)"
    }

    # --- Build Result ---
    [PSCustomObject]@{
        VM                   = $VM
        AD_LastLogonDate     = if ($LastLogonDate) { $LastLogonDate } else { "AD query failed" }
        LastInteractiveUser  = if ($Event) { $Event.Properties[5].Value } else { "No interactive logon found" }
        LastInteractiveLogon = if ($Event) { $Event.TimeCreated } else { "N/A" }
        LogonType            = if ($Event) {
                                    switch ($Event.Properties[8].Value) {
                                        2  { "Interactive (Local)" }
                                        10 { "RemoteInteractive (RDP)" }
                                    }
                               } else { "N/A" }
        Status               = if (-not $LastLogonDate) { "AD query failed" }
                               elseif (-not $Event)     { "No interactive event found" }
                               else                     { "OK" }
    }
}

$Results | Format-Table -AutoSize
# $Results | Export-Csv -Path "LastInteractiveLogon_Report.csv" -NoTypeInformation
