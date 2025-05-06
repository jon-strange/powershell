Add-Type -AssemblyName System.Windows.Forms

# Prompt for csr_requests.csv
$openFile = New-Object System.Windows.Forms.OpenFileDialog
$openFile.Title = "Select the csr_requests.csv file"
$openFile.Filter = "CSV files (*.csv)|*.csv"
$null = $openFile.ShowDialog()
if (-not $openFile.FileName) {
    Write-Host "No file selected. Exiting."
    exit
}
$RequestLogPath = $openFile.FileName

# Prompt for output folder
$folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
$folderDialog.Description = "Select output folder for saving .cer files"
$null = $folderDialog.ShowDialog()
if (-not $folderDialog.SelectedPath) {
    Write-Host "No folder selected. Exiting."
    exit
}
$OutputPath = $folderDialog.SelectedPath

# Load requests
$requests = Import-Csv -Path $RequestLogPath

foreach ($entry in $requests) {
    $baseName = $entry.CN -replace '[^a-zA-Z0-9._-]', "_"
    $cerPath = Join-Path $OutputPath "$baseName.cer"

    try {
        Write-Host "Retrieving certificate for $($entry.CN) (Request ID: $($entry.RequestID))..."
        certreq -retrieve $entry.RequestID $cerPath | Out-Null

        if (Test-Path $cerPath) {
            Write-Host "$($entry.CN): Certificate retrieved"
            certreq -accept $cerPath | Out-Null
            Write-Host "$($entry.CN): Certificate installed into local store"
        } else {
            Write-Host "$($entry.CN): Certificate file not found after retrieval"
        }

    } catch {
        Write-Host "$($entry.CN): Error retrieving certificate - $_"
    }
}
