Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-EnterpriseCA {
    try {
        & certutil -config - -ping 2>$null | ForEach-Object {
            if ($_ -match '^  "(.*)"$') { return $matches[1] }
        } | Select-Object -First 1
    } catch { return $null }
}

function New-CsrWithSan {
    param (
        [string]$CN, [string]$C, [string]$S, [string]$L,
        [string]$O, [string]$OU, [string]$Email,
        [string[]]$SAN_DNS, [string[]]$SAN_IP,
        [string]$OutDir, [System.Windows.Forms.TextBox]$LogBox,
        [bool]$Submit, [string]$CAConfig
    )

    $baseName = $CN -replace '[^a-zA-Z0-9._-]', "_"
    $keyPath = Join-Path $OutDir "$baseName.key"
    $csrPath = Join-Path $OutDir "$baseName.req"
    $infPath = Join-Path $OutDir "$baseName.inf"
    $logPath = Join-Path $OutDir "request_log.txt"

    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
    $keyBytes = $rsa.ExportCspBlob($true)
    $pemKey = "-----BEGIN RSA PRIVATE KEY-----`n"
    $pemKey += ([Convert]::ToBase64String($keyBytes) -split '(.{1,64})' | Where-Object { $_ }) -join "`n"
    $pemKey += "`n-----END RSA PRIVATE KEY-----"
    Set-Content -Path $keyPath -Value $pemKey -Encoding ascii
    $LogBox.AppendText("🔐 Key saved: $baseName.key`n")

    $subject = "CN=$CN, E=$Email, OU=$OU, O=$O, L=$L, S=$S, C=$C"

    # Build SAN extensions using correct _continue_ syntax
    $sanLines = @()
    foreach ($dns in $SAN_DNS) {
        if ($dns -and $dns.Trim()) {
            $sanLines += '_continue_ = "DNS=' + $dns.Trim() + '"'
        }
    }
    foreach ($ip in $SAN_IP) {
        if ($ip -and $ip.Trim()) {
            $sanLines += '_continue_ = "IP Address=' + $ip.Trim() + '"'
        }
    }

    $sanBlock = ""
    if ($sanLines.Count -gt 0) {
        $sanBlock = "[Extensions]`n2.5.29.17 = `"{text}`"`n" + ($sanLines -join "`n")
    }

    # Build INF content
    $infContent = @"
[Version]
Signature="\$Windows NT\$"

[NewRequest]
Subject = "$subject"
KeyLength = 2048
Exportable = TRUE
MachineKeySet = TRUE
SMIME = FALSE
PrivateKeyArchive = FALSE
UserProtected = FALSE
RequestType = PKCS10
KeyUsage = 0xa0
ProviderName = "Microsoft RSA SChannel Cryptographic Provider"
"@

    if ($sanBlock) { $infContent += "`n$sanBlock`n" }

    $infContent += @"
[RequestAttributes]
CertificateTemplate = WebServer
"@

    Set-Content -Path $infPath -Value $infContent -Encoding ascii
    $LogBox.AppendText("📝 INF created: $baseName.inf`n")

    try {
        certreq -new $infPath $csrPath | Out-Null
        Remove-Item $infPath -Force
        $LogBox.AppendText("✅ CSR created: $baseName.req`n")
        "$CN : CSR + KEY created" | Out-File -Append $logPath
    } catch {
        $LogBox.AppendText("❌ CSR generation failed for ${CN}: $_`n")
        return
    }

    if ($Submit -and $CAConfig) {
        try {
            $output = certreq -submit -config "$CAConfig" -attrib "CertificateTemplate:WebServer" $csrPath 2>&1
            $LogBox.AppendText("🔼 Submitted to CA: $CN`n$output`n")
            $requestId = ($output | Select-String -Pattern "RequestId: (\d+)" | ForEach-Object {
                ($_ -match "RequestId: (\d+)") | Out-Null
                $matches[1]
            })
            if ($requestId) {
                $LogBox.AppendText("📋 Request ID: $requestId (Pending)`n")
                "$CN : Submitted to CA, Request ID $requestId" | Out-File -Append $logPath
            } else {
                "$CN : Submitted to CA (no Request ID detected)" | Out-File -Append $logPath
            }
        } catch {
            $LogBox.AppendText("❌ Submission failed for ${CN}: $_`n")
        }
    }
}


# GUI Elements
$form = New-Object System.Windows.Forms.Form
$form.Text = "PowerShell CSR Generator (.key + .req with SAN + Submit)"
$form.Size = New-Object System.Drawing.Size(600, 520)
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
$submitBox.Location = New-Object System.Drawing.Point(120, 95)
$submitBox.Size = New-Object System.Drawing.Size(200, 20)
$form.Controls.Add($submitBox)

$generateBtn = New-Object System.Windows.Forms.Button
$generateBtn.Text = "Generate"
$generateBtn.Location = New-Object System.Drawing.Point(120, 125)
$generateBtn.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($generateBtn)

$LogBox = New-Object System.Windows.Forms.TextBox
$LogBox.Multiline = $true
$LogBox.ScrollBars = "Vertical"
$LogBox.ReadOnly = $true
$LogBox.Location = New-Object System.Drawing.Point(20, 170)
$LogBox.Size = New-Object System.Drawing.Size(545, 300)
$form.Controls.Add($LogBox)

# Button Logic
$generateBtn.Add_Click({
    $csvPath = $csvPathBox.Text
    $outPath = $outPathBox.Text
    $submit = $submitBox.Checked

    if (-not (Test-Path $csvPath)) {
        [System.Windows.Forms.MessageBox]::Show("Invalid CSV path.","Error")
        return
    }
    if (-not (Test-Path $outPath)) {
        [System.Windows.Forms.MessageBox]::Show("Invalid output path.","Error")
        return
    }

    try {
        $rows = Import-Csv $csvPath
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to read CSV: $_","Error")
        return
    }

    $caConfig = if ($submit) { Get-EnterpriseCA } else { $null }

    foreach ($row in $rows) {
        try {
            $dnsList = $row.SAN_DNS -split ';'
            $ipList  = $row.SAN_IP -split ';'
            New-CsrWithSan -CN $row.CN -C $row.C -S $row.S -L $row.L -O $row.O -OU $row.OU -Email $row.Email `
                -SAN_DNS $dnsList -SAN_IP $ipList -OutDir $outPath -LogBox $LogBox `
                -Submit:$submit -CAConfig $caConfig
        } catch {
            $LogBox.AppendText("❌ Failed for $($row.CN): $_`n")
        }
    }

    [System.Windows.Forms.MessageBox]::Show("CSR generation completed.","Done")
})

[void]$form.ShowDialog()
