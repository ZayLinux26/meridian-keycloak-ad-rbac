<#
.SYNOPSIS
    Leaver containment for Keycloak: logs a user out of every Keycloak session.
.DESCRIPTION
    Companion to the Meridian JML engine, which revokes Entra sessions through Graph.
    Authenticates as the jml-session-revoker service account (client credentials grant),
    looks the user up in the meridian realm, logs out all of their sessions, and appends
    an audit record (UTC time, user, session count, affected clients, operator) to a CSV.

    The client secret is read from a DPAPI-protected Clixml file, usable only by the
    Windows account and machine that created it.
.EXAMPLE
    .\Revoke-KeycloakSessions.ps1 -Username praman -WhatIf
    .\Revoke-KeycloakSessions.ps1 -Username praman
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string[]]$Username,
    [string]$BaseUrl  = 'https://idp.meridianfg.internal:8443',
    [string]$Realm    = 'meridian',
    [string]$CredPath = 'C:\Lab\keycloak\revoker.cred.xml',
    [string]$LogPath  = 'C:\Lab\keycloak\revocation-log.csv'
)
$ErrorActionPreference = 'Stop'

$cred  = Import-Clixml $CredPath
$token = Invoke-RestMethod -Method Post -Uri "$BaseUrl/realms/$Realm/protocol/openid-connect/token" -Body @{
    grant_type    = 'client_credentials'
    client_id     = $cred.UserName
    client_secret = $cred.GetNetworkCredential().Password
}
$h = @{ Authorization = "Bearer $($token.access_token)" }

foreach ($u in $Username) {
    $user = @(Invoke-RestMethod -Uri "$BaseUrl/admin/realms/$Realm/users?username=$u&exact=true" -Headers $h)
    if ($user.Count -eq 0) { Write-Warning "$u not found in Keycloak realm '$Realm'"; continue }
    $id       = $user[0].id
    $sessions = @(Invoke-RestMethod -Uri "$BaseUrl/admin/realms/$Realm/users/$id/sessions" -Headers $h)

    if ($PSCmdlet.ShouldProcess($u, "Log out $($sessions.Count) Keycloak session(s)")) {
        Invoke-RestMethod -Method Post -Uri "$BaseUrl/admin/realms/$Realm/users/$id/logout" -Headers $h | Out-Null
        $record = [pscustomobject]@{
            Timestamp       = (Get-Date).ToUniversalTime().ToString('o')
            Username        = $u
            KeycloakUserId  = $id
            SessionsRevoked = $sessions.Count
            Clients         = (($sessions | ForEach-Object { $_.clients.PSObject.Properties.Value }) | Sort-Object -Unique) -join ';'
            Operator        = "$env:USERDOMAIN\$env:USERNAME"
        }
        $record | Export-Csv -Path $LogPath -Append -NoTypeInformation
        $record
    }
}
