Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function New-CSRInf {
    param (
        [string]$CN,
        [string]$C,
        [string]$S,
        [string]$L,
        [string]$O,
        [string]$OU,
        [string]$Email,
        [string[]]$SAN_DNS,
        [string[]]$SAN_IP,
        [int]$KeyLength,
        [string]$OutputPath
    )

    $sanEntries = @()
    $sanIndex = 0
    foreach ($dns in $SAN_DNS) {
        if ($dns.Trim()) {
            $sanEntries += "DNS.$sanIndex=$dns"
            $sanIndex++
        }
    }
    foreach ($ip in $SAN_IP) {
        if ($ip.Trim()) {
            $sanEntries += "IP.$sanIndex=$ip"
            $sanIndex++
        }
    }

    $infContent = @"
[Version]
Signature="\$Windows NT\$"

[NewRequest]
Subject = "CN=$CN, C=$C, S=$S, L=$L, O=$O, OU=$OU, E=$Email"
KeyLength = $KeyLength
KeySpec = 1
KeyUsage = 0xa0
Exportable = TRUE
MachineKeySet = TRUE
SMIME = FALSE
PrivateKeyArchive = FALSE
UserProtected = FALSE
ProviderName = "Microsoft RSA SChannel Cryptographic Provider"
RequestType = PKCS10

[Extensions]
2.5.29.17 = "{text}"
$($sanEntries -join "`n")

[RequestAttributes]
CertificateTemplate = WebServer
"@

    $infFile = Join-Path $OutputPath "$CN.inf"
    Set-Content -Path $infFile -Value $infContent -Encoding ASCII
    return $infFile
}

function Submit-CSR {
    param (
        [string]$InfFile,
        [string]$OutputPath,
        [bool]$SubmitCSR,
        [System.Windows.Forms.TextBox]$LogBox
    )

    $reqFile = [System.IO.Path]::ChangeExtension($InfFile, ".req")
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InfFile)

    certreq -new $InfFile $reqFile | Out-Null
    $LogBox.AppendText("Generated CSR for $baseName`n")

    if ($SubmitCSR) {
        $certutil = & certutil -config - -ping
        if ($LASTEXITCODE -ne 0) {
            $LogBox.AppendText("❌ Unable to detect CA. Skipping submission for $baseName`n")
            return
        }

        $submitOut = certreq -submit -attrib "CertificateTemplate:WebServer" $reqFile 2>&1
        $LogBox.AppendText("🔼 Submitted CSR for $baseName:`n$submitOut`n")
    }
}

# GUI Setup
$form = New-Object System.Windows.Forms.Form
$form.Text = "Batch SSL CSR Generator"
$form.Size = New-Object System.Drawing.Size(700,500)
$form.StartPosition = "CenterScreen"

$csvLabel = New-Object System.Windows.Forms.Label
$csvLabel.Text = "CSV File:"
$csvLabel.Location = New-Object System.Drawing.Point(10,20)
$csvLabel.Size = New-Object System.Drawing.Size(100,20)
$form.Controls.Add($csvLabel)

$csvPathBox = New-Object System.Windows.Forms.TextBox
$csvPathBox.Location = New-Object System.Drawing.Point(80,18)
$csvPathBox.Size = New-Object System.Drawing.Size(480,20)
$form.Controls.Add($csvPathBox)

$csvBrowse = New-Object System.Windows.Forms.Button
$csvBrowse.Text = "Browse"
$csvBrowse.Location = New-Object System.Drawing.Point(570,16)
$csvBrowse.Size = New-Object System.Drawing.Size(75,23)
$csvBrowse.Add_Click({
    $fd = New-Object System.Windows.Forms.OpenFileDialog
    $fd.Filter = "CSV Files|*.csv"
    if ($fd.ShowDialog() -eq "OK") {
        $csvPathBox.Text = $fd.FileName
    }
})
$form.Controls.Add($csvBrowse)

$outLabel = New-Object System.Windows.Forms.Label
$outLabel.Text = "Output Folder:"
$outLabel.Location = New-Object System.Drawing.Point(10,55)
$outLabel.Size = New-Object System.Drawing.Size(100,20)
$form.Controls.Add($outLabel)

$outPathBox = New-Object System.Windows.Forms.TextBox
$outPathBox.Location = New-Object System.Drawing.Point(100,53)
$outPathBox.Size = New-Object System.Drawing.Size(460,20)
$form.Controls.Add($outPathBox)

$outBrowse = New-Object System.Windows.Forms.Button
$outBrowse.Text = "Browse"
$outBrowse.Location = New-Object System.Drawing.Point(570,51)
$outBrowse.Size = New-Object System.Drawing.Size(75,23)
$outBrowse.Add_Click({
    $fd = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($fd.ShowDialog() -eq "OK") {
        $outPathBox.Text = $fd.SelectedPath
    }
})
$form.Controls.Add($outBrowse)

$submitBox = New-Object System.Windows.Forms.CheckBox
$submitBox.Text = "Submit CSRs to CA"
$submitBox.Location = New-Object System.Drawing.Point(10,85)
$form.Controls.Add($submitBox)

$runBtn = New-Object System.Windows.Forms.Button
$runBtn.Text = "Generate"
$runBtn.Location = New-Object System.Drawing.Point(10,115)
$runBtn.Size = New-Object System.Drawing.Size(100,30)
$form.Controls.Add($runBtn)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.Location = New-Object System.Drawing.Point(10,160)
$logBox.Size = New-Object System.Drawing.Size(650,280)
$form.Controls.Add($logBox)

$runBtn.Add_Click({
    $csvPath = $csvPathBox.Text.Trim()
    $outPath = $outPathBox.Text.Trim()
    $submit = $submitBox.Checked

    if (-not (Test-Path $csvPath)) {
        [System.Windows.Forms.MessageBox]::Show("CSV path is invalid.","Error")
        return
    }
    if (-not (Test-Path $outPath)) {
        [System.Windows.Forms.MessageBox]::Show("Output folder is invalid.","Error")
        return
    }

    $logPath = Join-Path $outPath "request_log.txt"
    $devices = Import-Csv $csvPath
    foreach ($device in $devices) {
        $san_dns = $device.SAN_DNS -split ',' | ForEach-Object { $_.Trim() }
        $san_ip = $device.SAN_IP -split ',' | ForEach-Object { $_.Trim() }

        $infPath = New-CSRInf -CN $device.CN -C $device.C -S $device.S -L $device.L `
            -O $device.O -OU $device.OU -Email $device.Email -SAN_DNS $san_dns -SAN_IP $san_ip `
            -KeyLength ([int]$device.KeyLength) -OutputPath $outPath

        Submit-CSR -InfFile $infPath -OutputPath $outPath -SubmitCSR:$submit -LogBox $logBox
    }

    $logBox.Text | Out-File -FilePath $logPath -Encoding UTF8
    [System.Windows.Forms.MessageBox]::Show("CSR generation complete.","Done")
})

[void]$form.ShowDialog()
