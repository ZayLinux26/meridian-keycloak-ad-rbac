<#
.SYNOPSIS
    Stores the jml-session-revoker client secret as a DPAPI-protected credential file.
.DESCRIPTION
    Reads the secret from the clipboard instead of a hidden prompt, then prints only its
    length so it can be checked against the Keycloak console without being displayed.
    Run it, copy the secret from Keycloak (Clients > jml-session-revoker > Credentials)
    when asked, then press Enter. Copy the secret inside the VM, after this script is
    already running: remote desktop clipboard sync means the last copy on either machine wins.
#>
param([string]$CredPath = 'C:\Lab\keycloak\revoker.cred.xml')

New-Item -ItemType Directory -Path (Split-Path $CredPath) -Force | Out-Null
Read-Host "Copy the client secret in Keycloak now, then come back and press Enter"
$sec = (Get-Clipboard).Trim() | ConvertTo-SecureString -AsPlainText -Force
$c = [pscredential]::new('jml-session-revoker', $sec)
$c | Export-Clixml $CredPath -Force
Set-Clipboard -Value ' '
"Stored secret length: " + $c.GetNetworkCredential().Password.Length + " (compare with the Keycloak console)"
