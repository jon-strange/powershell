Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-EnterpriseCA {
    $ca = & certutil -config - -ping 2>$null | Select-String '^  "(.*)"' | ForEach-Object {
        ($_ -replace '^  "', '') -replace '"$', ''
    } | Select-Object -First 1
    return $ca
}

function Generate-CSR {
    param (
        [string]$CN,
        [string]$C,
        [string]$ST,
        [string]$L,
        [string]$O,
        [string]$OU,
        [string]$Email,
        [string[]]$SAN_DNS,
        [string[]]$SAN_IP,
        [string]$OutDir,
        [string]$CAConfig,
        [System.Windows.Forms.TextBox]$LogBox,
        [switch]$Submit
    )

    $Subject = "CN=$CN, C=$C, S=$ST, L=$L, O=$O, OU=$OU, E=$Email"
    $SanList = @()

    foreach ($dns in $SAN_DNS) {
        if ($dns -and $dns.Trim()) { $SanList += "dns=$($dns.Trim())" }
    }
    foreach ($ip in $SAN_IP) {
        if ($ip -and $ip.Trim()) { $SanList += "ipaddress=$($ip.Trim())" }
    }

    $sanString = $SanList -join '&'
    $infContent = @"
[Version]
Signature="\$Windows NT\$"

[NewRequest]
Subject = "$Subject"
KeySpec = 1
KeyLength = 2048
Exportable = TRUE
MachineKeySet = TRUE
SMIME = FALSE
PrivateKeyArchive = FALSE
UserProtected = FALSE
UseExistingKeySet = FALSE
ProviderName = "Microsoft RSA SChannel Cryptographic Provider"
ProviderType = 12
RequestType = PKCS10
KeyUsage = 0xa0

[Extensions]
2.5.29.17 = "{text}"
_continue_ = "$sanString"

[RequestAttributes]
CertificateTemplate = WebServer
"@

    $baseName = $CN -replace '[^a-zA-Z0-9_-]', '_'
    $infPath = Join-Path $OutDir "$baseName.inf"
    $reqPath = Join-Path $OutDir "$baseName.req"
    $logPath = Join-Path $OutDir "request_log.txt"

    try {
        $infContent | Set-Content -Path $infPath -Encoding ASCII
        certreq -new $infPath $reqPath | Out-Null
        $LogBox.AppendText("✅ Created CSR: $baseName.req`n")

        if ($Submit -and $CAConfig) {
            $submitOut = certreq -submit -config "$CAConfig" $reqPath 2>&1
            $LogBox.AppendText("🔼 Submitted CSR for ${baseName}:`n$submitOut`n")
        }

        "$CN : Success" | Out-File -Append $logPath
    } catch {
        $err = "❌ Error generating CSR for ${CN}: $_"
        $LogBox.AppendText("$err`n")
        "$CN : Failed - $_" | Out-File -Append $logPath
    }
}

# GUI Setup
$form = New-Object System.Windows.Forms.Form
$form.Text = "Batch SSL CSR Generator"
$form.Size = New-Object System.Drawing.Size(600, 500)
$form.StartPosition = "CenterScreen"

$csvLabel = New-Object System.Windows.Forms.Label
$csvLabel.Text = "CSV File:"
$csvLabel.Location = New-Object System.Drawing.Point(20, 20)
$csvLabel.Size = New-Object System.Drawing.Size(100, 20)
$form.Controls.Add($csvLabel)

$csvPathBox = New-Object System.Windows.Forms.TextBox
$csvPathBox.Location = New-Object System.Drawing.Point(120, 20)
$csvPathBox.Size = New-Object System.Drawing.Size(360, 20)
$form.Controls.Add($csvPathBox)

$browseCSV = New-Object System.Windows.Forms.Button
$browseCSV.Text = "Browse"
$browseCSV.Location = New-Object System.Drawing.Point(490, 18)
$browseCSV.Size = New-Object System.Drawing.Size(75, 23)
$browseCSV.Add_Click({
    $fd = New-Object System.Windows.Forms.OpenFileDialog
    $fd.Filter = "CSV Files (*.csv)|*.csv"
    if ($fd.ShowDialog() -eq "OK") {
        $csvPathBox.Text = $fd.FileName
    }
})
$form.Controls.Add($browseCSV)

$outLabel = New-Object System.Windows.Forms.Label
$outLabel.Text = "Output Folder:"
$outLabel.Location = New-Object System.Drawing.Point(20, 60)
$outLabel.Size = New-Object System.Drawing.Size(100, 20)
$form.Controls.Add($outLabel)

$outPathBox = New-Object System.Windows.Forms.TextBox
$outPathBox.Location = New-Object System.Drawing.Point(120, 60)
$outPathBox.Size = New-Object System.Drawing.Size(360, 20)
$form.Controls.Add($outPathBox)

$browseOut = New-Object System.Windows.Forms.Button
$browseOut.Text = "Browse"
$browseOut.Location = New-Object System.Drawing.Point(490, 58)
$browseOut.Size = New-Object System.Drawing.Size(75, 23)
$browseOut.Add_Click({
    $fd = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($fd.ShowDialog() -eq "OK") {
        $outPathBox.Text = $fd.SelectedPath
    }
})
$form.Controls.Add($browseOut)

$submitBox = New-Object System.Windows.Forms.CheckBox
$submitBox.Text = "Submit CSRs to CA"
$submitBox.Location = New-Object System.Drawing.Point(120, 100)
$submitBox.Size = New-Object System.Drawing.Size(200, 20)
$form.Controls.Add($submitBox)

$generateBtn = New-Object System.Windows.Forms.Button
$generateBtn.Text = "Generate"
$generateBtn.Location = New-Object System.Drawing.Point(120, 140)
$generateBtn.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($generateBtn)

$LogBox = New-Object System.Windows.Forms.TextBox
$LogBox.Multiline = $true
$LogBox.ScrollBars = "Vertical"
$LogBox.ReadOnly = $true
$LogBox.Location = New-Object System.Drawing.Point(20, 190)
$LogBox.Size = New-Object System.Drawing.Size(545, 250)
$form.Controls.Add($LogBox)

$generateBtn.Add_Click({
    $csvPath = $csvPathBox.Text
    $outPath = $outPathBox.Text

    if (-not (Test-Path $csvPath)) {
        [System.Windows.Forms.MessageBox]::Show("Invalid CSV path.","Error")
        return
    }
    if (-not (Test-Path $outPath)) {
        [System.Windows.Forms.MessageBox]::Show("Invalid output path.","Error")
        return
    }

    try {
        $devices = Import-Csv -Path $csvPath
    } catch {
        [System.Windows.Forms.MessageBox]::Show("CSV format error: $_","Error")
        return
    }

    $caConfig = if ($submitBox.Checked) { Get-EnterpriseCA } else { $null }

    foreach ($d in $devices) {
        Generate-CSR -CN $d.CN -C $d.C -ST $d.S -L $d.L -O $d.O -OU $d.OU -Email $d.Email `
            -SAN_DNS ($d.SAN_DNS -split ';') -SAN_IP ($d.SAN_IP -split ';') `
            -OutDir $outPath -CAConfig $caConfig -LogBox $LogBox -Submit:$submitBox.Checked
    }

    [System.Windows.Forms.MessageBox]::Show("CSR generation complete.","Done")
})

[void]$form.ShowDialog()
