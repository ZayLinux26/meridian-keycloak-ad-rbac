<#
.SYNOPSIS
    Creates the read-only LDAP bind account Keycloak uses to federate to AD.
.DESCRIPTION
    The account lives in its own OU at the domain root, deliberately OUTSIDE OU=Meridian.
    OU=Meridian is the Entra Cloud Sync scope with password hash sync on, so anything
    placed there would be copied to Entra with its password and become an internet-facing
    credential.

    The account gets no extra rights. Any authenticated AD account can already read users
    and group membership, so a plain domain user is the least-privileged bind identity.
#>
$domainDn = (Get-ADDomain).DistinguishedName
$ou = "OU=Service Identities,$domainDn"

if (-not (Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$ou)" -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name 'Service Identities' -Path $domainDn -ProtectedFromAccidentalDeletion $true
}

New-ADUser -Name 'svc-keycloak-ldap' `
  -SamAccountName 'svc-keycloak-ldap' `
  -UserPrincipalName "svc-keycloak-ldap@$((Get-ADDomain).DNSRoot)" `
  -Path $ou `
  -Description 'Keycloak LDAP federation bind account (read-only). Owner: IAM Engineering' `
  -AccountPassword (Read-Host -AsSecureString 'Password (25+ random characters, store in the vault)') `
  -Enabled $true -PasswordNeverExpires $true -CannotChangePassword $true
