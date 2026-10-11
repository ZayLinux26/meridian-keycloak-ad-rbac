<#
.SYNOPSIS
    Builds the application role groups Keycloak maps to OIDC client roles.
.DESCRIPTION
    AGDLP: users sit in GG-* (global) groups, which nest into DL-MFG-App-* (domain local)
    application role groups. No user is ever a direct member of an app role group, which is
    why Keycloak must resolve membership transitively.

    Two kinds of source groups feed the app roles:
      Birthright (JML-managed):  GG-MFG-Finance, GG-MFG-Compliance, GG-MFG-Treasury-WireRelease, ...
      Requested (owner-approved): GG-MFG-SWIFT-AppAdmins, GG-MFG-Actimize-AppAdmins
    The JML engine only touches groups in its access model, so it leaves the AppAdmins alone.
    Each AppAdmins group has an owner on managedBy: who approves requests and certifies it.

    DL-MFG-App-SWIFT-Release and DL-MFG-App-Actimize-Cases already exist from Part 1.
#>
$ou = "OU=Groups,OU=Meridian,$((Get-ADDomain).DistinguishedName)"

# Requested-access app admin groups (owner-approved, not JML-managed)
New-ADGroup -Name 'GG-MFG-SWIFT-AppAdmins' -SamAccountName 'GG-MFG-SWIFT-AppAdmins' `
  -GroupScope Global -GroupCategory Security -Path $ou -ManagedBy 'mbell' `
  -Description 'SWIFT application administrators. Requested access, owner-approved. Not JML-managed.'

New-ADGroup -Name 'GG-MFG-Actimize-AppAdmins' -SamAccountName 'GG-MFG-Actimize-AppAdmins' `
  -GroupScope Global -GroupCategory Security -Path $ou -ManagedBy 'kwalsh' `
  -Description 'Actimize application administrators. Requested access, owner-approved. Not JML-managed.'

# Application role groups (AGDLP nesting)
$roles = [ordered]@{
  'DL-MFG-App-SWIFT-View'     = 'GG-MFG-Finance'
  'DL-MFG-App-SWIFT-Admin'    = 'GG-MFG-SWIFT-AppAdmins'
  'DL-MFG-App-Actimize-View'  = 'GG-MFG-Compliance'
  'DL-MFG-App-Actimize-Admin' = 'GG-MFG-Actimize-AppAdmins'
}
foreach ($r in $roles.Keys) {
  New-ADGroup -Name $r -SamAccountName $r -GroupScope DomainLocal -GroupCategory Security `
    -Path $ou -Description "Application role group, nests $($roles[$r])"
  Add-ADGroupMember -Identity $r -Members $roles[$r]
}

# Seed the app admins
Add-ADGroupMember -Identity 'GG-MFG-SWIFT-AppAdmins'    -Members 'hlee'
Add-ADGroupMember -Identity 'GG-MFG-Actimize-AppAdmins' -Members 'jokafor'
