# Prompt user to select the CSV file
Add-Type -AssemblyName System.Windows.Forms

$csvDialog = New-Object System.Windows.Forms.OpenFileDialog
$csvDialog.Title = "Select devices.csv"
$csvDialog.Filter = "CSV files (*.csv)|*.csv"
$null = $csvDialog.ShowDialog()
if (-not $csvDialog.FileName) {
    Write-Host "No CSV file selected. Exiting."
    exit
}
$csvPath = $csvDialog.FileName

# Prompt user to select the output folder
$folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
$folderDialog.Description = "Select output folder for CSR and logs"
$null = $folderDialog.ShowDialog()
if (-not $folderDialog.SelectedPath) {
    Write-Host "No output folder selected. Exiting."
    exit
}
$outputPath = $folderDialog.SelectedPath
$logPath = Join-Path $outputPath "csr_request_log.csv"
"CN,RequestID,CSRPath" | Out-File -Encoding utf8 -FilePath $logPath

# Detect the CA
$caConfig = (& certutil -dump | Select-String "Config:" | ForEach-Object {
    ($_ -split ":\s+", 2)[1].Trim()
}) | Select-Object -First 1

if (-not $caConfig) {
    Write-Host "No CA detected. Exiting."
    exit
}

Write-Host "Using CA: $caConfig"

# Read CSV
$devices = Import-Csv -Path $csvPath

foreach ($device in $devices) {
    $CN = $device.CN.Trim()
    $baseName = $CN -replace '[^a-zA-Z0-9._-]', "_"
    $infPath = Join-Path $outputPath "$baseName.inf"
    $reqPath = Join-Path $outputPath "$baseName.req"
    $certPath = Join-Path $outputPath "$baseName.cer"

    # Extract SAN values
    $SAN_DNS = $device.SAN_DNS -split ';'
    $SAN_IP  = $device.SAN_IP -split ';'

    # Build SAN block
    $sanLines = @()
    foreach ($dns in $SAN_DNS) {
        if ($dns -and $dns.Trim()) {
            $sanLines += '_continue_ = "DNS=' + $dns.Trim() + '&' + '"'
        }
    }
    foreach ($ip in $SAN_IP) {
        if ($ip -and $ip.Trim()) {
            $sanLines += '_continue_ = "IP Address=' + $ip.Trim() + '&' +  '"'
        }
    }

    $sanBlock = ""
    if ($sanLines.Count -gt 0) {
        $sanBlock = "[Extensions]`n2.5.29.17 = `"{text}`"`n" + ($sanLines -join "`n")
    }

    # Build subject line
    $subject = "CN=$($device.CN), E=$($device.Email), OU=$($device.OU), O=$($device.O), L=$($device.L), S=$($device.S), C=$($device.C)"

    # Create INF file
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

    if ($sanBlock) {
        $infContent += "`n$sanBlock`n"
    }

# Replace <cert_template_name> with the name of the Certificated Template being requested
    $infContent += @"
[RequestAttributes]
CertificateTemplate = <cert_template_name>
"@

    Set-Content -Path $infPath -Value $infContent -Encoding ascii
    Write-Host "Generated INF for $CN"

    # Generate CSR
    certreq -new $infPath $reqPath | Out-Null
    Write-Host "Generated CSR: $reqPath"

    # Submit CSR
    try {
        # Replace <cert_template_name> with the name of the Certificated Template being requested
        $output = certreq -submit -config "$caConfig" -attrib "CertificateTemplate:<cert_temmplate_name>" $reqPath 2>&1
        Write-Host "Submitted CSR for $CN"

        # Try to extract Request ID
        $requestId = ($output | Select-String "RequestId" | Select-Object -First 1 | ForEach-Object {
            ($_ -match "RequestId: (\d+)") | Out-Null
            $matches[1]
        })


        if ($requestId) {
            Write-Host "Request ID: $requestId"
            "$CN,$requestId,$reqPath" | Out-File -Append -Encoding utf8 -FilePath $logPath
        } else {
            Write-Host "Submitted (no Request ID found — may be auto-issued)"
        }

        # If certificate issued immediately, extract .cer path and save
        $certIssued = $output | Where-Object { $_ -match '\.cer"' }
        if ($certIssued -match '"(.+?\.cer)"') {
            $issuedPath = $matches[1]
            Copy-Item -Path $issuedPath -Destination $certPath -Force
            Write-Host "Certificate saved to: $certPath"
        } else {
            Write-Host "Certificate pending approval or issued manually."
        }

    } catch {
        Write-Host "Error submitting CSR for ${CN}:`n$_"
    }

    #Remove-Item -Path $infPath -Force -ErrorAction SilentlyContinue
}
