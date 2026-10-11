# Meridian Keycloak AD RBAC

**Active Directory groups drive application access through Keycloak, OIDC role claims and step-up MFA, on a live hybrid lab**

[![Keycloak](https://img.shields.io/badge/Keycloak-26.7-4D4D4D?style=for-the-badge&logo=keycloak&logoColor=white)](https://www.keycloak.org/)
[![Active Directory](https://img.shields.io/badge/Active%20Directory-Windows%20Server%202022-0078D6?style=for-the-badge&logo=windows&logoColor=white)](#lab)
[![AD CS](https://img.shields.io/badge/AD%20CS-Enterprise%20PKI-0078D6?style=for-the-badge&logo=letsencrypt&logoColor=white)](#1-pki-and-ldaps)
[![OpenID Connect](https://img.shields.io/badge/OpenID%20Connect-PKCE%20%2B%20Step--up-F78C40?style=for-the-badge&logo=openid&logoColor=white)](#5-the-apps-and-the-token)
[![RHEL](https://img.shields.io/badge/RHEL-9-EE0000?style=for-the-badge&logo=redhat&logoColor=white)](#lab)
[![Podman](https://img.shields.io/badge/Podman-Rootless-892CA0?style=for-the-badge&logo=podman&logoColor=white)](#lab)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?style=for-the-badge&logo=postgresql&logoColor=white)](#lab)
[![Python](https://img.shields.io/badge/Python-3.12%20%2F%20Flask-3776AB?style=for-the-badge&logo=python&logoColor=white)](apps/oidc-app/app.py)
[![PowerShell](https://img.shields.io/badge/PowerShell-7-5391FE?style=for-the-badge&logo=powershell&logoColor=white)](scripts/Revoke-KeycloakSessions.ps1)
[![Azure](https://img.shields.io/badge/Azure-Lab-0089D6?style=for-the-badge&logo=microsoftazure&logoColor=white)](#lab)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

*Part 2 of the Meridian Financial Group lab. Part 1: [meridian-jml-engine](https://github.com/ZayLinux26/meridian-jml-engine)*

---

Most companies already decide who gets into an application in Active Directory. They just don't do it consistently. One app reads AD groups over plain LDAP, another keeps its own user table, a third got wired to whatever group someone found in 2019. This project shows the pattern that fixes that: **AD stays the source of truth for access, Keycloak turns AD groups into per-application roles, and every app makes its decision from one claim in a signed token.**

It was built for a fictional mid-size bank, Meridian Financial Group, on the same live hybrid lab as Part 1. The headline result: an HR change in a CSV file gave an analyst the right to release wires, and an HR termination cut her off **while she was signed in**, with nobody touching Keycloak or the app.

Getting that second result took three fixes, because the first time I ran the termination, it didn't work. That finding is the most useful part of the project, and it has [its own section](#the-finding-a-leaver-process-only-covers-the-idps-it-knows-about).

## Contents

1. [The enterprise problem](#the-enterprise-problem)
2. [What this project proves](#what-this-project-proves)
3. [Architecture](#architecture)
4. [The access chain, end to end](#the-access-chain-end-to-end)
5. [How it works, layer by layer](#how-it-works-layer-by-layer) (reference section)
6. [The finding: a leaver process only covers the IdPs it knows about](#the-finding-a-leaver-process-only-covers-the-idps-it-knows-about)
7. [Proven on the live lab](#proven-on-the-live-lab)
8. [What broke](#what-broke)
9. [Honest wall: lab vs. production](#honest-wall-lab-vs-production)
10. [Control mapping](#control-mapping)
11. [Questions this project answers](#questions-this-project-answers)
12. [Repository layout and running it](#repository-layout)

---

## The enterprise problem

A bank runs dozens of internal applications. Every one of them has to answer the same two questions: *who is this* and *what may they do here*. When each app answers on its own, auditors find the same problems every year:

- **Access nobody can trace.** An app has 40 admins in its local user table. Which ones were approved, and by whom? Nobody knows.
- **Movers keep old access.** An analyst moves from Treasury to Compliance. AD gets updated. The wire release app has its own role table, so she can still release wires.
- **Leavers stay signed in.** IT disables the account in AD. The user already has a session in an app, and nothing tells the app.
- **Cleartext credentials.** Apps bind to AD over plain LDAP on port 389, so every password check crosses the network readable.
- **Privileged actions protected like ordinary ones.** Viewing a wire and releasing a wire both need the same password.

Centralizing authentication in an identity provider fixes the first problem. Fixing the rest depends on how the IdP is wired to AD, how roles reach the app, and what happens to sessions when AD changes. Those details are where real deployments break, and they are what this project is about.

## What this project proves

Every claim links to evidence from the live lab.

| Claim | Evidence |
|---|---|
| Keycloak reads AD over encrypted, verified LDAPS, never plain LDAP | [Refused](docs/screenshots/04-ldaps-before-no-cert.png) → [encrypted but untrusted](docs/screenshots/07-ldaps-after-tls-unverified.png) → [verified](docs/screenshots/08-ldaps-verified.png) |
| The bind account is read-only and outside the cloud sync scope | [LDAPS bind test](docs/screenshots/09-ldapsearch-ldaps-bind.png), [Keycloak connection test](docs/screenshots/17-ldap-test-connection-auth.png) |
| Nested AGDLP groups resolve correctly | [Direct vs. in-chain query](docs/screenshots/12-nested-membership-in-chain.png), [Elena resolved in Keycloak](docs/screenshots/19-nested-groups-resolved.png) |
| Each app's token carries only that app's roles | [Elena in Actimize: `view`](docs/screenshots/23-token-elena-actimize-view.png), [Elena in SWIFT: nothing](docs/screenshots/24-token-elena-swift-none.png) |
| One login, two apps, two correct answers | [Actimize allowed](docs/screenshots/25-elena-aml-view-allowed.png), [Actimize denied](docs/screenshots/26-elena-aml-cases-denied.png), [SWIFT via SSO](docs/screenshots/27-elena-swift-sso-no-roles.png) |
| An HR change grants app access with no IdP or app change | [Mover plan](docs/screenshots/29-jml-priya-mover-plan.png), [release allowed](docs/screenshots/30-priya-swift-release-allowed.png), [audit log](docs/screenshots/31-app-authz-audit-log.png) |
| Releasing a wire demands fresh MFA; viewing does not | [Step-up flow](docs/screenshots/32-keycloak-stepup-flow.png), [allowed after OTP](docs/screenshots/34-release-allowed-after-stepup.png), [audit trail](docs/screenshots/35-stepup-audit-trail.png) |
| The first termination left the user with access | [Still allowed](docs/screenshots/37-terminated-user-still-has-access.png), [Keycloak session still live](docs/screenshots/38-keycloak-session-still-active.png) |
| After the fixes, termination cuts off a signed-in user | [Cut off in the open tab](docs/screenshots/44-terminated-user-cut-off.png), [Keycloak's reason in the log](docs/screenshots/45-app-session-revoked-log.png) |
| The platform survives a reboot and runs under a named MFA admin | [Services up after reboot](docs/screenshots/46-services-up-after-reboot.png), [named admin, no warning](docs/screenshots/47-named-admin-mfa-no-banner.png) |

---

## Architecture

```mermaid
flowchart LR
    HR[(HR snapshot CSV)] --> JML[JML engine<br/>MFG-MGMT01]
    JML -- AD module --> AD[(Active Directory<br/>MFG-DC01<br/>meridianfg.internal)]
    JML -- Graph --> EN[(Microsoft Entra ID)]
    AD -- Cloud Sync --> EN
    CA[Meridian-Root-CA<br/>AD CS on MFG-MGMT01] -. issues certs .-> AD
    CA -. issues certs .-> KC
    AD -- LDAPS 636<br/>read-only bind --> KC[Keycloak 26.7<br/>realm: meridian<br/>MFG-IDP01]
    PG[(PostgreSQL 16)] --- KC
    KC -- OIDC + PKCE<br/>roles claim --> SW[SWIFT Wire Release<br/>:8444]
    KC -- OIDC + PKCE<br/>roles claim --> AML[Actimize AML Cases<br/>:8445]
    SW -. refresh before every action .-> KC
    AML -. refresh before every action .-> KC
    JML -. leaver: revoke script .-> KC
```

<a name="lab"></a>
| Server | Role | Address |
|---|---|---|
| **MFG-DC01** | Windows Server 2022 **Core** domain controller and DNS for `meridianfg.internal`. Nothing else installed. | 10.20.0.4 |
| **MFG-MGMT01** | Windows Server 2022: RSAT, Entra Cloud Sync agent, the JML engine, the enterprise CA (`Meridian-Root-CA`), the Keycloak revocation script | 10.20.0.5 |
| **MFG-IDP01** | RHEL 9: rootless Podman running Keycloak 26.7 on PostgreSQL 16, plus both sample apps, all under systemd | 10.20.0.6 |

All three sit in one Azure VNet. RDP and SSH are locked to a single admin IP. Keycloak and the apps have **no public exposure**: they are reached by internal DNS name (`idp`, `swift`, `aml` `.meridianfg.internal`) from inside the network, the way an employee on the corporate network would reach them.

---

## The access chain, end to end

This is the whole design in one line:

```
HR record → JML engine → GG group → DL app role group (AD) → client role (Keycloak) → roles claim (token) → app decision
```

Each link has one owner, and each can be audited on its own:

| Link | Owner | Lives in |
|---|---|---|
| Who works here, in what job | HR | HR feed |
| Which birthright groups that job gets | IAM (access model) | JML engine config |
| Which app role a group grants | App owner + IAM | AD nesting (`GG-*` inside `DL-MFG-App-*`) |
| What that group means inside an app | IAM | Keycloak group → client role mapping |
| Whether this action needs that role | App team | One line of app code |

**Worked example: Priya Raman.**

1. HR changes her title from Senior Financial Analyst to **Treasury Analyst**. Nothing else.
2. The JML engine plans a mover and adds her to `GG-MFG-Treasury-WireRelease`.
3. That group is nested in `DL-MFG-App-SWIFT-Release` (AGDLP, from Part 1).
4. Keycloak resolves the nesting and maps `DL-MFG-App-SWIFT-Release` to the `release` role on the `swift-release` client.
5. Her next SWIFT token carries `"roles": ["view", "release"]`.
6. The app checks `"release" in roles`, asks for fresh MFA, and allows the release. It logs the decision.

Nobody opened Keycloak or the SWIFT app to make that happen.

---

## How it works, layer by layer

This section is the reference I'd want if I came back to this in six months.

### 1. PKI and LDAPS

**LDAP** is how apps talk to Active Directory: look up a user, check a password, read group membership. Plain LDAP (port 389) does all of that in cleartext, so a password check made through it crosses the network readable. **LDAPS** is the same protocol inside TLS, on port 636.

A domain controller can't do TLS without a certificate, and a fresh domain has none. So:

- **AD CS** (Active Directory Certificate Services) runs as an **enterprise root CA**, `Meridian-Root-CA`, on MGMT01. "Enterprise" means it's integrated with AD: every domain-joined machine trusts it automatically, and computers can auto-enroll.
- The DC **auto-enrolls** a Domain Controller Authentication certificate. Once a valid server-auth cert with its own name sits in its store, AD DS starts serving LDAPS on its own. No setting to flip, no reboot.
- Linux, Java and Python each keep **their own trust store**, and none of them has heard of the Meridian root. This came up three times: the RHEL system trust (`update-ca-trust`), Keycloak's Java runtime (`KC_TRUSTSTORE_PATHS`), and the Python apps (`REQUESTS_CA_BUNDLE`).
- Keycloak and the apps got their own certificates through the **WebServer** template. The CSR was generated on IDP01, so private keys never left the server they're used on. Each cert carries a **subjectAltName**, because browsers ignore the CN.

The before/after set shows the three states: [connection refused](docs/screenshots/04-ldaps-before-no-cert.png) (no cert), [encrypted but unverified](docs/screenshots/07-ldaps-after-tls-unverified.png) (cert, no trust), [verified](docs/screenshots/08-ldaps-verified.png) (cert and trust). The middle state matters: encrypted to an unverified peer is exactly what a man-in-the-middle attack looks like.

### 2. AD design: groups and the bind account

**App role groups follow AGDLP.** Accounts go in **G**lobal groups (who you are), which nest into **D**omain **L**ocal groups (what you can reach). Users are never direct members of an app role group.

| App | Role group (AD) | Fed by | Kind |
|---|---|---|---|
| SWIFT | `DL-MFG-App-SWIFT-Release` | `GG-MFG-Treasury-WireRelease` | Birthright (Treasury Analyst) |
| | `DL-MFG-App-SWIFT-View` | `GG-MFG-Finance` | Birthright (Finance dept) |
| | `DL-MFG-App-SWIFT-Admin` | `GG-MFG-SWIFT-AppAdmins` | Requested, owner `mbell` |
| Actimize | `DL-MFG-App-Actimize-Cases` | `GG-MFG-AML-CaseMgmt` | Birthright |
| | `DL-MFG-App-Actimize-View` | `GG-MFG-Compliance` | Birthright (Compliance dept) |
| | `DL-MFG-App-Actimize-Admin` | `GG-MFG-Actimize-AppAdmins` | Requested, owner `kwalsh` |

The two **AppAdmins** groups are the "application administrators group" for each app. They are requested access, approved by the owner on `managedBy`, and certified by that owner in access reviews. The JML engine only manages groups named in its access model, so it never adds or strips these. ([`ad/New-MeridianAppRoleGroups.ps1`](ad/New-MeridianAppRoleGroups.ps1))

**The bind account** (`svc-keycloak-ldap`) is a plain domain user with no extra rights. In AD, any authenticated account can already read users and group membership, so a plain user *is* the least-privileged bind identity. The important decision is **where it lives**: `OU=Service Identities` at the domain root, not under `OU=Meridian`. `OU=Meridian` is the Cloud Sync scope with password hash sync on. A service account placed there gets copied to Entra with its password, which turns an internal LDAP credential into one anyone on the internet can try. ([`ad/New-KeycloakBindAccount.ps1`](ad/New-KeycloakBindAccount.ps1))

### 3. Keycloak federation

| Setting | Value | Why |
|---|---|---|
| Realm | `meridian` | `master` is for administering Keycloak only. Workforce identity gets its own realm. |
| Connection | `ldaps://mfg-dc01.meridianfg.internal:636`, truststore **Always** | Encrypted, and the DC's certificate is validated against the Meridian root |
| Edit mode | **READ_ONLY** | AD is the source of truth. Keycloak can't change a password or attribute. |
| Users DN | `OU=Meridian`, **subtree** | Leavers move to `OU=Disabled Users`. Searching only `OU=Users` would make them vanish instead of showing as disabled (the same trap Part 1 hit with Cloud Sync scope). |
| User filter | `(employeeID=*)` | Only HR-anchored identities federate. Admin and service accounts stay out. |
| Cache policy | **MAX_LIFESPAN**, 5 minutes | Caps how long Keycloak trusts its cached copy of an AD user. See [the finding](#the-finding-a-leaver-process-only-covers-the-idps-it-knows-about). |

Passwords are never copied into Keycloak. At login, Keycloak checks the password against AD live, over LDAPS.

### 4. Nested groups

This is the setting that makes or breaks AD federation in an AGDLP shop.

Ask AD the naive way, "which users are members of `DL-MFG-App-Actimize-View`?", and the answer is **nobody**, because only `GG-MFG-Compliance` is a direct member. Ask with the matching rule `1.2.840.113556.1.4.1941` (**LDAP_MATCHING_RULE_IN_CHAIN**) and AD walks the nesting itself and returns the Compliance team. [Both queries side by side](docs/screenshots/12-nested-membership-in-chain.png).

Most IdPs and apps default to the naive query. In an AGDLP directory that means every token comes back with no roles, everyone is denied, and the app team gets blamed. The Keycloak group mapper is set to:

| Setting | Value | Why |
|---|---|---|
| Retrieve strategy | `LOAD_GROUPS_BY_MEMBER_ATTRIBUTE_RECURSIVELY` | Keycloak's built-in use of the in-chain rule |
| LDAP filter | `(cn=DL-MFG-App-*)` | Keycloak only learns about **app role groups**. File share and birthright groups stay out of every token. |
| Preserve group inheritance | Off | AD groups can have several parents (`GG-MFG-Finance` feeds a file share and SWIFT). Keycloak's tree can't model that. We only need the flat answer. |
| Mode | READ_ONLY | Same reason as above |

### 5. The apps and the token

Each app is a **confidential OIDC client** with three **client roles**:

| Client | Roles | Redirect URI |
|---|---|---|
| `swift-release` | `release`, `view`, `admin` | `https://swift.meridianfg.internal:8444/callback` (exact, no wildcard) |
| `actimize-cases` | `cases`, `view`, `admin` | `https://aml.meridianfg.internal:8445/callback` |

Client settings that matter: **standard flow with PKCE S256** on, **direct access grants off** (that flow lets an app collect passwords and skips MFA), exact redirect URIs only.

**Client roles, not realm roles.** `admin` in SWIFT and `admin` in Actimize are owned, approved and reviewed by different people. Client roles keep them separate. Rule of thumb: realm roles for who you are, client roles for what you can do in one app.

Each AD group maps to exactly one client role. On top of that, two token settings per client:

- **Full scope allowed: off.** By default a SWIFT token would carry every role the user has, including their Actimize roles. Off means each app learns only its own roles. If one app's logs leak, they don't expose the user's access everywhere else.
- **A flat `roles` claim** (User Client Role mapper). Keycloak normally buries client roles at `resource_access.swift-release.roles`. A flat claim keeps each app's authorization check to one line.

**The app** ([`apps/oidc-app/app.py`](apps/oidc-app/app.py)) is one codebase run twice, configured by environment variables. It never sees a password: it redirects to Keycloak, receives a code, and trades it for tokens server to server with its client secret. Every allow, deny, step-up and revocation is written as a JSON line. It runs on Red Hat's UBI Python image, with secrets held as Podman secrets, never in files or command history.

### 6. Step-up MFA on wire release

Viewing the wire queue needs a password. Releasing a wire needs a **second factor completed in the last 5 minutes**. Keycloak models this as **Level of Authentication (LoA)**:

```
browser-stepup forms                      Alternative
    LoA1 - password                       Conditional
        Condition - Level of Authentication   Required  (level 1, max age 10h)
        Username Password Form                Required
    LoA2 - otp                            Conditional
        Condition - Level of Authentication   Required  (level 2, max age 300s)
        OTP Form                              Required
```

- The flow is applied **only to the SWIFT client** (browser flow override). Actimize users never see an OTP prompt.
- The client maps readable names to levels: `silver` → 1, `gold` → 2. The app asks for `gold` and never hardcodes Keycloak's numbers. (Minimum ACR stays empty: setting it to `gold` would force OTP on every login.)
- The app checks the **role first**. No `release` role is a flat denial; MFA can't grant access you don't have. With the role but no fresh second factor, the app sends the user back to Keycloak with `acr_values=gold`, then returns them to the action they tried.
- The app keeps its own 5-minute clock. Without it, one OTP would unlock wire releases for the rest of the session.

The audit trail shows the order: `stepup_required` → `stepup` → `ALLOW` ([35](docs/screenshots/35-stepup-audit-trail.png)).

### 7. Leaver containment

Covered in full in the next section. Three controls:

| Layer | Control |
|---|---|
| Keycloak user cache | MAX_LIFESPAN 5 minutes on the AD provider |
| App session | Refresh-token revalidation with Keycloak before every action ([`revalidate()`](apps/oidc-app/app.py)) |
| Keycloak session | `jml-session-revoker` service account + [`Revoke-KeycloakSessions.ps1`](scripts/Revoke-KeycloakSessions.ps1), run as part of the leaver |

---

## The finding: a leaver process only covers the IdPs it knows about

Priya was signed in to SWIFT with release rights. HR terminated her. The Part 1 JML engine did everything it was built to do: disabled her in AD, stripped her groups, moved her to `OU=Disabled Users`, revoked her **Entra** sessions.

Then I clicked **View wire queue** in her open browser tab. [It said ALLOWED.](docs/screenshots/37-terminated-user-still-has-access.png)

Here is where the termination stopped:

| Layer | After the first termination | Why |
|---|---|---|
| Active Directory | Disabled, groups stripped | The JML engine owns it |
| Entra ID | Sessions revoked | The JML engine calls Graph |
| **Keycloak user cache** | **Still enabled, still had her roles** | She logged in minutes earlier, so Keycloak answered from memory |
| **Keycloak session** | **Still live** ([38](docs/screenshots/38-keycloak-session-still-active.png)) | Nothing told Keycloak |
| **SWIFT app session** | **Still allowing actions** | The app trusted the roles it got at login |

Earlier, Tom Brennan's account had flipped to Disabled in Keycloak right away. The difference: Tom wasn't in the cache, so Keycloak read him fresh from AD. Priya was. A test with Tom alone would have suggested the integration was fine.

Priya never signed in through Entra. She signed in through Keycloak, a second identity provider the leaver process didn't know existed. Most organizations with more than one IdP (Entra plus Okta, Ping, Keycloak, or a legacy SSO) have this same gap, and it rarely shows up in testing because testers sign out between steps.

**The fix, one control per layer:**

1. **Cap the cache.** MAX_LIFESPAN of 5 minutes on the AD provider. Not NO_CACHE, which would send every request to the domain controllers. Five minutes is a number you can write into a control and defend.
2. **Revalidate before every action.** The app uses its refresh token to ask Keycloak for a fresh token before each action. A dead session or disabled user is refused, and the app clears its own session. Roles also come from the fresh token, so a mover who loses `release` loses it on their next click. The cost is one call to Keycloak per action: an easy yes for wire release, and a reason to prefer short token lifetimes plus back-channel logout for high-traffic apps.
3. **Revoke Keycloak sessions in the leaver.** A dedicated service account (`jml-session-revoker`, client credentials only) and a script that logs the user out of every Keycloak session and appends an audit record: UTC time, user, session count, affected clients, operator.

**Retest, same scenario:** rehire Priya, sign her in, step up with OTP, release a wire, terminate her, run the revocation. In the same open tab: [**"Your session is no longer valid. Access has been revoked."**](docs/screenshots/44-terminated-user-cut-off.png) The app log shows why ([45](docs/screenshots/45-app-session-revoked-log.png)):

```json
{"event": "login", "user": "praman", "roles": ["view", "release"], "acr": "silver1"}
{"event": "stepup", "user": "praman", "acr": "gold"}
{"event": "authz", "user": "praman", "action": "release", "decision": "ALLOW"}
{"event": "session_revoked", "user": "praman", "reason": "Session not active"}
```

The reason comes from Keycloak. The app asked, and Keycloak refused.

**A second finding along the way:** after the rehire, Priya's **OTP device was still registered** ([42](docs/screenshots/42-priya-rehire-otp-persists.png)). The TOTP secret lives in Keycloak's database, not in AD, so the termination never touched it. A leaver keeps a working second factor, and a rehire inherits it without re-enrolling. Nobody decided either of those things on purpose. MFA factors are identity data too, and they live wherever the IdP keeps them.

---

## Proven on the live lab

### Phase 1: Infrastructure

| Three servers in one VNet | SSH locked to one IP |
|---|---|
| [![VMs](docs/screenshots/01-azure-three-vm-overview.png)](docs/screenshots/01-azure-three-vm-overview.png) | [![NSG](docs/screenshots/02-nsg-ssh-my-ip.png)](docs/screenshots/02-nsg-ssh-my-ip.png) |
| **IDP01 resolves AD names through the DC** | |
| [![DNS](docs/screenshots/03-idp-dns-via-dc.png)](docs/screenshots/03-idp-dns-via-dc.png) | |

### Phase 2: PKI and LDAPS

| Before: the DC refuses TLS | Enterprise root CA created |
|---|---|
| [![Before](docs/screenshots/04-ldaps-before-no-cert.png)](docs/screenshots/04-ldaps-before-no-cert.png) | [![CA](docs/screenshots/05-adcs-enterprise-root-ca.png)](docs/screenshots/05-adcs-enterprise-root-ca.png) |
| **DC auto-enrolls its certificate** | **Encrypted, issuer not yet trusted** |
| [![DC cert](docs/screenshots/06-dc-autoenrolled-ldaps-cert.png)](docs/screenshots/06-dc-autoenrolled-ldaps-cert.png) | [![Unverified](docs/screenshots/07-ldaps-after-tls-unverified.png)](docs/screenshots/07-ldaps-after-tls-unverified.png) |
| **After: verified** | **Bind account reads Elena over LDAPS** |
| [![Verified](docs/screenshots/08-ldaps-verified.png)](docs/screenshots/08-ldaps-verified.png) | [![Bind](docs/screenshots/09-ldapsearch-ldaps-bind.png)](docs/screenshots/09-ldapsearch-ldaps-bind.png) |

### Phase 3: AD role design

| Current state before any change | App role groups and nesting |
|---|---|
| [![Inventory](docs/screenshots/10-ad-groups-current-state.png)](docs/screenshots/10-ad-groups-current-state.png) | [![Groups](docs/screenshots/11-app-role-groups-created.png)](docs/screenshots/11-app-role-groups-created.png) |
| **Direct query finds nobody, in-chain finds the team** | |
| [![In chain](docs/screenshots/12-nested-membership-in-chain.png)](docs/screenshots/12-nested-membership-in-chain.png) | |

The inventory ([10](docs/screenshots/10-ad-groups-current-state.png)) also caught drift: `tbrennan`, a Day 3 leaver in Part 1, was enabled and still in two groups, left over from Part 1's rollback test. It was reconciled through the JML engine before the demos ([28](docs/screenshots/28-jml-drift-reconciled.png)).

### Phase 4: Keycloak

| Keycloak certificate issued | Key and certificate verified |
|---|---|
| [![Cert issued](docs/screenshots/13-keycloak-cert-issued.png)](docs/screenshots/13-keycloak-cert-issued.png) | [![Cert verified](docs/screenshots/14-keycloak-cert-verified.png)](docs/screenshots/14-keycloak-cert-verified.png) |
| **Disk full on image pull, fixed with lvextend** | **Keycloak running in production mode over TLS** |
| [![Disk](docs/screenshots/15a-disk-full-lvextend.png)](docs/screenshots/15a-disk-full-lvextend.png) | [![Running](docs/screenshots/15-keycloak-running-tls.png)](docs/screenshots/15-keycloak-running-tls.png) |
| **Meridian realm** | **LDAPS connection and bind tests** |
| [![Realm](docs/screenshots/16-keycloak-meridian-realm.png)](docs/screenshots/16-keycloak-meridian-realm.png) | [![LDAP test](docs/screenshots/17-ldap-test-connection-auth.png)](docs/screenshots/17-ldap-test-connection-auth.png) |
| **HR-anchored users federated** | **Nested groups resolved for Elena** |
| [![Users](docs/screenshots/18-keycloak-users-federated.png)](docs/screenshots/18-keycloak-users-federated.png) | [![Nested](docs/screenshots/19-nested-groups-resolved.png)](docs/screenshots/19-nested-groups-resolved.png) |
| **SWIFT client roles** | **Actimize client roles** |
| [![SWIFT roles](docs/screenshots/20-swift-client-roles.png)](docs/screenshots/20-swift-client-roles.png) | [![AML roles](docs/screenshots/21-actimize-client-roles.png)](docs/screenshots/21-actimize-client-roles.png) |
| **AD group mapped to client role** | |
| [![Mapping](docs/screenshots/22-group-role-mapping.png)](docs/screenshots/22-group-role-mapping.png) | |

### Phase 5: Tokens and apps

| Elena's Actimize token: `view` only | Elena's SWIFT token: no roles |
|---|---|
| [![Token AML](docs/screenshots/23-token-elena-actimize-view.png)](docs/screenshots/23-token-elena-actimize-view.png) | [![Token SWIFT](docs/screenshots/24-token-elena-swift-none.png)](docs/screenshots/24-token-elena-swift-none.png) |
| **Actimize: view allowed** | **Actimize: case work denied** |
| [![AML allowed](docs/screenshots/25-elena-aml-view-allowed.png)](docs/screenshots/25-elena-aml-view-allowed.png) | [![AML denied](docs/screenshots/26-elena-aml-cases-denied.png)](docs/screenshots/26-elena-aml-cases-denied.png) |
| **SWIFT via SSO, no password prompt, no roles** | |
| [![SSO](docs/screenshots/27-elena-swift-sso-no-roles.png)](docs/screenshots/27-elena-swift-sso-no-roles.png) | |

Elena moved from Treasury to Compliance on Part 1's Day 2. Her tokens show that mover reached all the way to the applications.

### Phase 6: HR drives access

| Drift reconciled (Tom Brennan) | HR moves Priya into Treasury |
|---|---|
| [![Drift](docs/screenshots/28-jml-drift-reconciled.png)](docs/screenshots/28-jml-drift-reconciled.png) | [![Mover](docs/screenshots/29-jml-priya-mover-plan.png)](docs/screenshots/29-jml-priya-mover-plan.png) |
| **Priya releases a wire** | **Every decision logged** |
| [![Release](docs/screenshots/30-priya-swift-release-allowed.png)](docs/screenshots/30-priya-swift-release-allowed.png) | [![Authz log](docs/screenshots/31-app-authz-audit-log.png)](docs/screenshots/31-app-authz-audit-log.png) |

### Phase 7: Step-up MFA

| LoA step-up flow | OTP enrollment at first release (secret blurred) |
|---|---|
| [![Flow](docs/screenshots/32-keycloak-stepup-flow.png)](docs/screenshots/32-keycloak-stepup-flow.png) | [![Enroll](docs/screenshots/33-stepup-otp-enrollment.png)](docs/screenshots/33-stepup-otp-enrollment.png) |
| **Release allowed at `gold`** | **stepup_required → stepup → ALLOW** |
| [![Gold](docs/screenshots/34-release-allowed-after-stepup.png)](docs/screenshots/34-release-allowed-after-stepup.png) | [![Step-up log](docs/screenshots/35-stepup-audit-trail.png)](docs/screenshots/35-stepup-audit-trail.png) |

### Phase 8: The leaver gap

| HR terminates Priya | Her open tab still allowed |
|---|---|
| [![Terminated](docs/screenshots/36-jml-priya-terminated.png)](docs/screenshots/36-jml-priya-terminated.png) | [![Still allowed](docs/screenshots/37-terminated-user-still-has-access.png)](docs/screenshots/37-terminated-user-still-has-access.png) |
| **Keycloak session still live, account still "Enabled"** | |
| [![Session](docs/screenshots/38-keycloak-session-still-active.png)](docs/screenshots/38-keycloak-session-still-active.png) | |

### Phase 9: The fix, and the retest

| Cache capped at 5 minutes | Revocation service account |
|---|---|
| [![Cache](docs/screenshots/39-keycloak-cache-policy.png)](docs/screenshots/39-keycloak-cache-policy.png) | [![Revoker](docs/screenshots/40-keycloak-revoker-service-account.png)](docs/screenshots/40-keycloak-revoker-service-account.png) |
| **Keycloak sessions revoked, with audit record** | **Rehire: old OTP device still registered** |
| [![Revoked](docs/screenshots/41-keycloak-sessions-revoked.png)](docs/screenshots/41-keycloak-sessions-revoked.png) | [![OTP persists](docs/screenshots/42-priya-rehire-otp-persists.png)](docs/screenshots/42-priya-rehire-otp-persists.png) |
| **Retest: JML leaver plus Keycloak revocation** | **Retest: cut off in the open tab** |
| [![Leaver](docs/screenshots/43-leaver-jml-plus-keycloak-revocation.png)](docs/screenshots/43-leaver-jml-plus-keycloak-revocation.png) | [![Cut off](docs/screenshots/44-terminated-user-cut-off.png)](docs/screenshots/44-terminated-user-cut-off.png) |
| **Keycloak's reason in the app log** | |
| [![Revoked log](docs/screenshots/45-app-session-revoked-log.png)](docs/screenshots/45-app-session-revoked-log.png) | |

### Phase 10: Operations hardening

| All five containers up after reboot, nobody logged in | Named admin with MFA, temporary admin deleted |
|---|---|
| [![Reboot](docs/screenshots/46-services-up-after-reboot.png)](docs/screenshots/46-services-up-after-reboot.png) | [![Admin](docs/screenshots/47-named-admin-mfa-no-banner.png)](docs/screenshots/47-named-admin-mfa-no-banner.png) |

> Some log lines in screenshots 31, 35 and 45 show `"acr": "silver1"`. That was a typo in the SWIFT client's ACR-to-LoA mapping (the ACR name, not the level). It had no effect on enforcement, since the app only checks for `gold`, and the mapping now reads `silver`.

---

## What broke

Every one of these happened on the live build. Most of them are the kind of thing that eats a day in a real deployment.

**1. The first Keycloak image pull ran out of disk.** Rootless Podman stores images under the user's home directory. Azure's RHEL image splits its disk into small LVM volumes, and `/home` gets about 1 GB. Postgres fit; Keycloak didn't. The disk had 30+ GB unallocated. Fix: `lvextend -r -L +20G /dev/rootvg/homelv`, live, no reboot. Size `/home` for container storage before deploying. ([15a](docs/screenshots/15a-disk-full-lvextend.png))

**2. `certutil -ca.cert` printed its help text instead of exporting the root.** PowerShell splits an argument starting with a dash at the period, so certutil received `-ca` and `.cert`. One root cause, three errors, since the next two commands had no file to read. Fix: quote it, `certutil '-ca.cert'`. Classic cmd.exe tools don't always survive PowerShell's argument parsing.

**3. A certificate file came out empty.** The clipboard didn't hold the certificate when it was pasted, so `cat > apps.crt` wrote nothing and OpenSSL had nothing to read. Fix: `Get-Content apps.cer | Set-Clipboard` instead of highlighting text in a console, and `head -1` to check the file before verifying it.

**4. SWIFT login returned a 500 after a successful sign-in.** The app log showed the browser came back with a valid code, then the server-to-server token exchange failed with `unauthorized_client`. The stored client secret was wrong. OIDC's front channel (browser to IdP) and back channel (app to IdP) fail independently, and the app log shows which one broke. Fix: recreate the Podman secret and the container, since containers read secrets at creation.

**5. Step-up sub-flows landed in the wrong part of the flow.** Keycloak's browser flow has several sub-flows, each with its own **+** button. The first attempt nested `LoA1 - password` inside the Organization sub-flow, where it would never run, and new sub-flows arrive **Disabled** by default. Rule for that screen: a child always appears below its parent and further right.

**6. The revocation script failed with `invalid_client` twice.** First, a hidden credential prompt stored a one-character secret after a failed paste (one asterisk on screen). Second, remote desktop clipboard sync meant copying instructions on the Mac overwrote a secret copied inside the VM: the last copy on either machine wins. Fix: [`Set-RevokerCredential.ps1`](scripts/Set-RevokerCredential.ps1) reads the clipboard after you copy, then prints only the secret's length, checked against the Keycloak console without ever displaying the secret.

**7. The authorization audit log disappeared after a reboot.** Podman sends container logs to the systemd journal, and Azure's RHEL image keeps the journal in memory. The reboot that proved the services came back on their own also erased the evidence of the first leaver test. Fix: a persistent journal (`/var/log/journal`), then rerun the termination test. In production these logs ship to a SIEM; an access control without durable evidence won't pass an audit.

**8. Drift from Part 1.** The group inventory showed a terminated user enabled and in two groups, left behind by Part 1's rollback test. The JML engine planned six leaver actions for him and reconciled it. Pull current state before designing roles; the directory has always drifted from the documentation. ([28](docs/screenshots/28-jml-drift-reconciled.png))

**9. The leaver gap.** The biggest one, covered in [its own section](#the-finding-a-leaver-process-only-covers-the-idps-it-knows-about).

---

## Honest wall: lab vs. production

What this lab does differently from a production deployment, on purpose:

| Lab | Production |
|---|---|
| Single enterprise root CA on the management server | Two-tier PKI: an offline root and an issuing CA on a dedicated, Tier 0-hardened server. Whoever controls an enterprise CA can mint a certificate for any identity in the domain. |
| WebServer template enrollment by a domain admin | Tightly scoped template permissions. Misconfigured AD CS templates are a well-known attack path (the ESC1-ESC8 family). |
| One certificate covers both apps | One certificate and key per app, so compromising one can't impersonate the other |
| Keycloak and both apps on one server, Postgres in the same pod | IdP on its own hosts, clustered, with a managed database. An app compromise should never land on the box that issues everyone's tokens. |
| Bind account password set to never expire | Rotated on a schedule or vaulted, and blocked from interactive and RDP logon by GPO |
| `manage-users` on the revocation account | Keycloak has no logout-only admin role. Narrow it with fine-grained admin permissions. |
| Revoker secret in a DPAPI-protected file on MGMT01 | Secret in a vault, or a certificate-based client |
| Revocation is a companion script run after the JML leaver | A step inside the leaver plan, with containment status and a failure exit code, like the Entra revocation in Part 1 |
| Leaver doesn't delete Keycloak OTP credentials | Delete IdP-held factors at termination, force re-enrollment on rehire |
| Up to 5 minutes for an AD change to reach Keycloak's cache | Same trade-off, documented as the control's tolerance. Session revocation covers the urgent case. |
| Refresh before every action | Fine for high-risk apps. High-traffic apps use short token lifetimes and back-channel logout. |
| Test passwords reset by an admin | Ticketed helpdesk action, user bootstraps with a temporary pass |
| App logs in a persistent local journal | Shipped to a SIEM with retention |
| `podman generate systemd` (deprecated) | Quadlet, once on Podman 5 |

---

## Control mapping

| Framework | Control | How this project addresses it |
|---|---|---|
| **PCI DSS v4.0** | 7.2.1, 7.2.2 | Access defined by job function in AD and delivered as per-app roles; least privilege per token (full scope off) |
| | 8.2.5 | Terminated users lose access, including live sessions in a second IdP |
| | 8.4.2 | MFA for the high-risk action (wire release) |
| | 8.6.1-8.6.3 | Bind and revocation service accounts: dedicated, documented owner, no interactive use, least privilege |
| **SOX ITGC** | Logical access: provisioning, transfers, terminations | HR-driven grants and removals reach the application; every decision logged with user, role and outcome |
| **SWIFT CSCF** | 4.2 MFA, 5.1 Logical access control | Step-up MFA on release; role-based access from the directory of record |
| **NIST SP 800-53** | AC-2, AC-2(3) | Account management driven from HR; disabled accounts lose app access |
| | AC-3, AC-6 | Authorization enforced from role claims; per-app scoping |
| | AC-12 | Sessions terminated when the account is revoked |
| | IA-2(1) | MFA required at the moment of the privileged action |
| | SC-8, SC-17 | LDAPS and HTTPS everywhere; certificates from an enterprise PKI |
| | AU-2, AU-3, AU-9 | JSON audit events per decision; persistent storage |
| **ISO/IEC 27001:2022** | A.5.15, A.5.18 | Access control policy enforced from one source of truth |
| | A.8.5 | Secure authentication, step-up for high-risk actions |
| | A.8.15, A.8.24 | Logging; use of cryptography |

---

## Questions this project answers

**Why put Keycloak between AD and the apps instead of having each app read AD?**
Each app reading AD means each app holds a bind credential, parses nested groups its own way, and keeps its own session rules. The IdP does that once, issues signed tokens, and gives one place to enforce MFA and kill sessions.

**Why LDAPS and not StartTLS?**
Both encrypt. LDAPS is TLS from the first byte on its own port, so there's no window where a misconfigured client can fall back to cleartext.

**Why does Keycloak need the root CA when the server already trusts it?**
Keycloak runs on Java, inside a container. Java keeps its own trust store, separate from the operating system's.

**What happens if you forget the recursive group strategy?**
Every user's token comes back with no app roles, and everyone is denied. It looks like an app bug.

**Why client roles instead of passing AD group names in the token?**
Group names leak your org structure into every app and bloat tokens. Client roles let the IdP translate "this group" into "this permission, in this app" and keep each token to the app it's for.

**Why does disabling someone in AD not log them out of the app?**
The app holds a session from login, Keycloak holds a session, and Keycloak caches the user. None of them is notified by AD. You need a control at each layer.

**Why not just set the Keycloak cache to NO_CACHE?**
Every request would query the domain controllers. Capping the cache lifespan and revoking sessions at termination gives you a known tolerance without loading AD.

**Why is step-up only on release?**
MFA on every action trains users to approve prompts without reading them. Asking for a second factor at the moment of the high-risk action, and only then, keeps it meaningful.

---

## Repository layout

```
ad/
  New-KeycloakBindAccount.ps1       read-only bind account, outside the Cloud Sync scope
  New-MeridianAppRoleGroups.ps1     AppAdmins groups and DL-MFG-App-* role groups (AGDLP)
apps/oidc-app/
  app.py                            the sample app (v1.2: step-up + per-action revalidation)
  Containerfile                     UBI 9 Python 3.12, gunicorn over TLS
  requirements.txt
deploy/
  01-keycloak-pod.sh                Keycloak 26.7 + PostgreSQL 16, rootless, production mode
  02-run-apps.sh                    builds the app once, runs SWIFT and Actimize
  03-enable-services.sh             systemd units, persistent journal
scripts/
  Revoke-KeycloakSessions.ps1       leaver containment for Keycloak, with audit record
  Set-RevokerCredential.ps1         stores the revoker secret (DPAPI), verifies length
docs/screenshots/                   47 screenshots from the live lab
```

The Keycloak realm itself (federation, mappers, clients, roles, the step-up flow) was configured through the admin console, and every setting is documented in [How it works](#how-it-works-layer-by-layer) with the reason for it.

### App versions

| Version | Adds |
|---|---|
| 1.0 | OIDC login with PKCE, role-based allow/deny, JSON audit log |
| 1.1 | Step-up MFA (`acr_values=gold`) for actions that require it, 5-minute freshness |
| 1.2 | Refresh-token revalidation before every action; live role changes; fail closed when a session can't be verified |

### Resuming the lab after the VMs were stopped

1. Start **MFG-DC01** first (it's everyone's DNS), then MFG-MGMT01 and MFG-IDP01.
2. Keycloak and both apps start on their own (systemd plus linger). Check with `podman ps` on IDP01.
3. Admin console: `https://idp.meridianfg.internal:8443/admin` from Edge on MGMT01.

## Roadmap

- Fold Keycloak session revocation and OTP credential deletion into the JML engine's leaver plan
- Back-channel logout so Keycloak notifies the apps directly
- Realm configuration as code (Terraform Keycloak provider or `kcadm` export) with drift detection
- Separate certificates per app and a two-tier PKI
- Ship app audit events to Microsoft Sentinel

## License

MIT. See [LICENSE](LICENSE).
