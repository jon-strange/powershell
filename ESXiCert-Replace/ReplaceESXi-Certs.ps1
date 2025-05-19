######################################################################################
# ReplaceESXi-Certs
# This script replaces the default VMCA signed SSL certificates on ESXi hosts with
# externally signed SSL Certificates.
#
# This script assumes that a properly signed SSL certificate and private key file 
# exist for each host defined in the host list file. All cert and key pairs should
# be placed in a single folder for this script to work
#
# 1. Create a text file with the FQDN of each 
#    host, 1 per line. 
# 2. The certificate and private key files should be in PEM format and named for
#    the corresponding host (host1.corp.lan.pem, host1.corp.lan.key)
# 3. Before running this script, ensure the vCenter server has the root CA installed
#    in the trusted store and it is pushed to all hosts (refer to VMWare documentation
#    for steps on how to do this)
# 4. Ensure that all hosts have the SSH service running before executing this script
#######################################################################################


# === USER SETTINGS ===
$HostListFile = "C:\Path\To\hosts.txt"     # Text file with FQDNs of ESXi hosts
$CertFolder = "C:\Path\To\Certs"           # Folder containing .crt and .key files
$Username = "root"

# === Get Credentials Securely ===
$Credential = Get-Credential -Message "Enter password for ESXi root access"
$PlainPassword = $Credential.GetNetworkCredential().Password

# === Read Hosts File ===
$Hosts = Get-Content -Path $HostListFile

foreach ($Host in $Hosts) {
    Write-Host "`nProcessing $Host..."

    $CertFile = Join-Path $CertFolder "$Host.crt"
    $KeyFile  = Join-Path $CertFolder "$Host.key"

    # === Validate File Existence ===
    if (-not (Test-Path $CertFile)) {
        Write-Warning "Certificate file not found: $CertFile"
        continue
    }
    if (-not (Test-Path $KeyFile)) {
        Write-Warning "Key file not found: $KeyFile"
        continue
    }

    # === Upload cert and key to /tmp on ESXi host ===
    & scp $CertFile "$Username@$Host:/tmp/rui.crt"
    & scp $KeyFile  "$Username@$Host:/tmp/rui.key"

    # === Prepare commands to execute over SSH ===
    $commands = @(
        "cp /etc/vmware/ssl/rui.crt /etc/vmware/ssl/rui.crt.bak",
        "cp /etc/vmware/ssl/rui.key /etc/vmware/ssl/rui.key.bak",
        "mv /tmp/rui.crt /etc/vmware/ssl/rui.crt",
        "mv /tmp/rui.key /etc/vmware/ssl/rui.key",
        "/etc/init.d/hostd restart",
        "/etc/init.d/vpxa restart"
    )

    foreach ($cmd in $commands) {
        & ssh "$Username@$Host" "$cmd"
    }

    Write-Host "Certificate replaced and services restarted on $Host"
}
