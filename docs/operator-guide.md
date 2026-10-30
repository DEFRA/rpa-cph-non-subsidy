# Operator guide: Azure Container Apps

For teams moving from a Windows VM deployment to the supplied Linux container on
Azure Container Apps (ACA). Use the README for [configuration](../README.md#configuration),
[local commands](../README.md#run-locally) and the [developer guide](./developer-guide.md)
for implementation details.

**Status:** Azure deployment and production parity have not been verified by this
handover. This is a runbook for receiving-team deployment and acceptance, not a
claim that the environment, alerts or recovery procedures already exist.

## The operating model has changed

| Windows VM habit | Container Apps equivalent |
|---|---|
| Copy binaries or patch the installed runtime | Build/test a replacement image, push it to ACR and deploy its immutable digest. |
| Recycle IIS or log onto the server to repair files | Inspect the failing revision/replica; correct the image or external configuration. Local container changes are disposable. |
| Keep machine-local configuration and certificates | Supply non-secret configuration and ACA Key Vault secret references. ACA ingress terminates public TLS. |
| Depend on a VM identity/account | Use the configured UAMI for Azure services; Entra separately authenticates users. |
| Keep cookie-encryption keys on disk | Share the encrypted Data Protection key ring in Blob Storage, wrapped by a Key Vault key. |
| Read local event/file logs | Use ACA system/console logs, Log Analytics and Application Insights. |

Containers and their filesystems are replaceable. SQL data, configuration,
identity resources and encryption keys must survive their replacement.

## Supplied deployment model and ownership

[infra/app.bicep](../infra/app.bicep) uses the Consumption profile, **single-revision
mode**, HTTPS-only external ingress targeting HTTP 8080, HTTP scaling and a
non-root `web` container. Replica bounds, CPU/memory, concurrency and shutdown
grace are explicit deployment inputs, not application-selected defaults.
The [foundation](../infra/main.bicep) supplies private service connectivity; its
network design and region/SKU availability still need receiving-team validation.

| Owner | Responsibilities |
|---|---|
| Application team | Image, application configuration contract, regression tests and business smoke tests. |
| Platform/operations | ACA/ACR, network/private DNS, deployment permissions, monitoring, image retention and runtime identity attachment. |
| Identity team | Entra registration, role assignments, audit claim, callbacks and client-secret lifecycle. |
| DBA | Approved schema, contained UAMI database user/grants, backup/restore and database compatibility. |
| Security/service owner | Access approvals, telemetry/privacy policy, incident handling, recovery objectives and release acceptance. |

Agree named owners, rollback authority, recovery time (RTO) and acceptable data loss
(RPO) before go-live. The templates do not establish an SLA, multi-region failover
or operational alert rules.

### Identity and permission checklist

The supplied templates use one runtime UAMI across resource accesses. Keep build,
deployment, human/operator and runtime privileges separate; do not give the app
subscription administration or SQL administrator access.

| Access | Mechanism / permission to verify |
|---|---|
| Users signing in | Entra web app registration and client secret; exact app-role value and configured audit claim. |
| Image pull | Runtime UAMI with registry-scoped `AcrPull`; image push uses a separate principal. |
| Entra client-secret delivery | ACA Key Vault reference resolved by the configured UAMI with `Key Vault Secrets User` access. |
| SQL | Managed-identity connection string identifying the UAMI **client ID**, plus a contained database user with minimum CRUD/audit grants. Azure resource RBAC alone is not database access. |
| Key-ring Blob | Runtime UAMI with Blob data read/write permissions at the approved scope. |
| Key wrapping | Runtime UAMI with key get/wrap/unwrap permissions; secret-read access is a different permission. |
| Application Insights | Explicit ingestion UAMI with component-scoped `Monitoring Metrics Publisher`; local ingestion authentication disabled. |

The app uses explicit managed-identity credentials for shared keys and telemetry,
not developer-credential fallback. A UAMI survives app replacement only while its
separate identity resource is retained.

## Entra setup: app roles and audit claims

Three different permissions must not be confused:

- **App role:** lets a signed-in person use this application's business pages.
- **Azure RBAC/database permissions:** let the runtime UAMI access Azure resources.
- **Entra administrator permissions:** let an authorized identity administrator
  manage the registration and assignments. Azure subscription ownership alone
  does not imply these directory permissions.

The **App registration** defines the application's identity, callback URLs and
available roles. Its **Enterprise application** (service principal) is where users
or groups in the tenant are assigned those roles. Confirm the application/client
ID, not just its display name, before editing either object.

### 1. Confirm the web application registration

With the identity owner's approval, use the [Entra admin center](https://entra.microsoft.com):

1. Select the approved tenant, then **Entra ID > App registrations** and the
   production web application. Use the existing approved registration where applicable.
   Confirm it serves this tenant and matches `AzureAd__TenantId`/`AzureAd__ClientId`.
2. Under **Authentication**, configure the **Web** platform with the exact HTTPS
   `/signin-oidc` and `/signout-callback-oidc` URLs for the approved app origin.
   Coordinate front-channel `/signout-oidc` if needed. Do not enable implicit-grant
   switches just to obtain an ID token: this application uses authorization code.
3. Ensure a valid client secret is delivered through the existing ACA Key Vault
   reference. Store its **value**, not its credential/secret ID, using approved
   private tooling. Never paste the value into deployment parameters or this guide.
   See [secret maintenance](#secret-and-key-maintenance) for rotation.

### 2. Define and assign the business-access role

Under **App registrations > your application > App roles > Create app role**,
the following is an illustrative definition, not an instruction to rename an
existing approved role:

| Field | Example |
|---|---|
| Display name | `CPH Basic Access` |
| Allowed member types | `Users/Groups` |
| Value | `CPH.BasicAccess` |
| Description | `Use the CPH customer and parcel workflows, including editing, deletion and export.` |
| Enable this app role | Yes |

The **value**, including case, must match `Authorization__BasicAccessRole`.
Spaces belong in the display name, not the value. Do not supply the role GUID,
the internal policy name `CPH Non Subsidy: Basic Access`, or a security-group name.
This is full business-page access, not a read-only role.

Next go to **Entra ID > Enterprise applications > your application > Users and
groups > Add user/group**. Select the approved users/security group, select the
defined role and save the assignment. Merely creating a role or assigning
**Default Access** does not supply the required role value. The interactive-user
assignment is not an **API permissions > Application permissions** assignment.

Group-based assignment requires suitable Entra licensing (currently P1/P2);
nested group membership does not cascade. The app consumes the resulting `roles`
claim, not a list of group IDs, so adding a `groups` claim is not required.
Agree the enterprise application's **Assignment required?** setting with the
identity owner; requiring assignment can block unassigned users at Entra, but
does not replace this application's own role check.

### 3. Agree the audit claim before configuring it

`Identity__AuditNameClaimType` is the exact claim name to read from the **ID token**
issued to this web app. It is not necessarily a directory attribute's display
name. The claim must occur exactly once with a nonblank value for every permitted
user. A missing, duplicate or unusable claim causes sign-in rejection even when
the user has the correct role.

For illustration only:

```text
Authorization__BasicAccessRole=CPH.BasicAccess
Identity__AuditNameClaimType=preferred_username
```

A user whose ID token contains `roles: ["CPH.BasicAccess"]` and
`preferred_username: "Operator@example.invalid"` would receive business access
and be audited as `operator@example.invalid`. That is **not** a conversion to
their old Windows account name. Usernames can change; do not select this example
for production unless the identity/business owner accepts its audit meaning.

If historical audit continuity needs a legacy account value, have the identity
team supply it through an approved claim and verify real user samples. For
supported optional claims, use **App registrations > Token configuration > Add
optional claim**, selecting **ID**, not only Access/SAML. Custom/legacy attributes
may require a separate approved claims-mapping setup; naming an attribute in
application configuration does not make Entra emit it. Do not add a second copy
of an already emitted claim or grant broad Graph permissions to work around this.

The application lowercases the value, removes `earth\` and replaces every `m0`
with `m`; for example `EARTH\M01234` becomes `m1234`. Check continuity and collisions
with existing audit records. The claim identifies the actor; it grants no access.
See the [developer explanation](./developer-guide.md#app-roles-and-claims-how-the-code-uses-them)
for the exact code path.

### 4. Verify assignments and claims safely

- Perform a fresh application sign-out/sign-in after assignment/claim changes;
  refreshing the page or renewing an existing cookie does not fetch new roles.
- With approved test users, verify: correct role permits access; no/wrong role
  denies business pages; missing audit claim rejects sign-in; a successful edit
  records the agreed normalized actor.
- With **Assignment required?** enabled, unassigned users can be rejected by Entra
  before reaching the app. Otherwise, a valid signed-in identity without the
  required role reaches the application's access-denied response (403).
- Check ID-token claims only through approved local diagnostic tooling. Never
  upload live tokens to public decoders or copy tokens/claim dumps into logs,
  tickets or screenshots. Authorization is enforced by validated server-side
  claims, not by manually decoding a JWT.
- For event 1001, `AUDIT_CONTRACT_REJECTED` indicates the audit-claim contract,
  `TENANT_CONTRACT_REJECTED` the tenant contract, and `OIDC_REMOTE_FAILURE` the
  remote sign-in flow. Access denied is instead a role/policy investigation.
- For removal, remove the user/group role assignment rather than only disabling
  the role definition. Existing app cookies can retain their claims; urgent
  revocation needs the agreed incident procedure, not an assumption of instant logout.

## First deployment and release acceptance

Follow the [Bicep deployment guide](../infra/README.md) for commands, parameter
validation and deployment ordering. Do not improvise bootstrap through public
endpoints or substitute regions/SKUs when a prerequisite fails.

1. **Foundation:** approve parameters and create network, registry, identity, data
   and monitoring resources. Match subscription, resource group and names for
   subsequent stages.
2. **Private access:** verify workload and operator DNS/routing to SQL, Blob and
   Key Vault. Public Cloud Shell/laptop access is not implied by a private endpoint.
3. **Bootstrap:** push and retain the image digest, configure Entra/callbacks,
   populate the Key Vault secret, install the approved SQL schema/user/grants,
   and create the dedicated wrapping key through the documented private path.
   The application does not create schema, database users or that wrapping key.
4. **Activation:** deploy the application with matching foundation identifiers.
   Verify image pull, secret resolution and RBAC propagation rather than relying
   on a fixed sleep or successful resource creation.
5. **Application acceptance:** complete the checks below using approved test data.
   Do not treat successful provisioning or readiness as business acceptance.

- [ ] Correct image digest/revision, Production environment, resource sizing and replica bounds.
- [ ] Allowed application/custom hostnames and probe Host; HTTPS origin and Entra callbacks match.
- [ ] Actual immediate proxy belongs to the configured trust range; external
      redirects stay HTTPS and untrusted forwarded headers cannot alter them.
- [ ] Liveness/readiness pass; sign-in, allowed role, denied role and sign-out work.
- [ ] Create/edit/parcel inactivation/export/delete work, including audit identity,
      timestamps, validation and downstream CSV consumption.
- [ ] Cookies remain usable across replica/revision replacement with shared keys;
      key-ring storage is encrypted and accessible with the intended identity.
- [ ] Telemetry arrives without unacceptable sensitive data; alerts reach the on-call team.
- [ ] Last-known-good image/configuration and tested SQL/key-ring recovery paths are retained.

Do not set `ASPNETCORE_FORWARDEDHEADERS_ENABLED`, trust every network, disable SQL
certificate validation or deploy a local development PFX as a troubleshooting shortcut.

## Routine health checks and diagnosis

| Signal | Meaning / limitation |
|---|---|
| `/health/live` | HTTP 200 `Healthy`: process responds. It does not check SQL or sign-in. |
| `/health/ready` | Bounded SQL `SELECT 1`; 200 `Healthy` or 503 `Unhealthy`. It does not check application tables, CRUD permissions or Entra. |
| ACA system logs | Image pull, revision provisioning, replica lifecycle, probe and secret-resolution failures. |
| Container console logs | Startup validation, authentication rejection and SQL readiness warnings. Inspect the correct revision/replica. |
| Application Insights | Requests, dependencies, exceptions, traces and metrics, subject to sampling, filters and platform support. Missing telemetry is not proof of health. |

The configured probes call HTTP 8080 with an allowed Host. Liveness uses a 3-second
probe timeout and readiness 5 seconds; both run every 10 seconds after an initial
10 seconds, with a three-failure threshold. The SQL check separately limits
connection and command timeouts to 3 seconds each. Keep these layers consistent
if changing probe timings; a SQL outage should not trigger a SQL-based liveness loop.

Read-only examples below require Azure CLI access to the **approved** subscription.
Replace placeholders; commands are not executed by this guide. Do not collect
environment dumps, secret values or user/token contents in incident attachments.

```powershell
az containerapp revision list --resource-group '<resource-group>' --name '<app-name>' `
  --query "[].{Revision:name,Active:properties.active,Health:properties.healthState}" --output table
az containerapp logs show --resource-group '<resource-group>' --name '<app-name>' --type system --tail 50
```

In the portal, select the affected revision, replica and `web` container for console
logs. Correlate timestamps, request/operation IDs and release digest with Application
Insights and dependency/platform diagnostics. Authentication rejections use event
**1001**, with `TENANT_CONTRACT_REJECTED`, `AUDIT_CONTRACT_REJECTED` or
`OIDC_REMOTE_FAILURE`; SQL readiness warnings use event **1002**. Details are
intentionally limited: do not enable identity PII logging to obtain more context.

| Symptom | First checks |
|---|---|
| No ready revision / image pull failure | Registry digest exists, UAMI attached, `AcrPull`, network access and system events. |
| Process repeatedly exits | Required configuration, identity GUIDs, Data Protection settings and startup console logs; distinguish failures from normal scale-to-zero. |
| HTTP 400 / failed probes | Allowed Host including the probe Host; invalid paging values on list requests. |
| Redirect loop or HTTP callback | Ingress TLS/target port, observed proxy peer, configured trust and external HTTPS port. Never fix by trusting all proxies. |
| Sign-in fails / access denied | Callback registration, client-secret validity, tenant, exact role value and unique configured audit claim. |
| Readiness fails | SQL private DNS/routing, UAMI contained user/grants, TLS and service availability. |
| CRUD fails despite healthy readiness | Schema compatibility, table permissions, constraints, validation and application exceptions. |
| Users lose sign-in after scale/release | Shared-key enablement, stable Blob URI/application name, historical wrapping-key versions and resource access. |
| Telemetry missing | Connection string, ingestion UAMI role, disabled local authentication, network access and collection/sampling filters. |

Configure owner-approved alerts for availability/readiness, sustained failures,
exceptions/dependency failures, replica restarts/OOM, saturation and SQL health.
Choose thresholds and notification routing for the service; the supplied templates
do not create alert rules/action groups. Telemetry may contain URLs/query strings
or exception details: apply access, retention and privacy controls before production.

## Releases, scaling and rollback

For each release retain the tested registry digest, compatible non-secret
configuration/parameter version, previous revision and required secret/key versions.
Do not export secret values into the release record. Validate new images in an
approved non-production environment before production.

Deploy through the existing application activation path. A template/image or
container-environment change can create a new revision. In the supplied single
mode, ACA keeps traffic on the old revision until the new one is ready, then
deactivates the old one. Readiness is only the SQL connectivity check, so run
business acceptance promptly; platform readiness is not a functional release gate.
Application-scoped changes, including secrets, can affect more than one revision.

This deployment does **not** implement multi-revision canary/percentage traffic
splitting. That would be a separate approved deployment change. Never rely on
being able to keep two production revisions serving traffic in the current mode.

Replica count does not replace SQL capacity planning. Scale-to-zero is permitted
by the parameter bounds and can introduce cold starts. Verify SQL connection
capacity and request latency when changing HTTP concurrency, replicas or CPU/memory.
Account for temporary old/new replica overlap and in-flight requests at shutdown.
Shared keys support cookie decryption across replicas; sticky sessions are not a
substitute for durable keys.

### Rollback checklist

1. Have the designated owner declare rollback for failed acceptance, sustained
   errors or unacceptable user impact; stop further rollout and notify support.
2. Identify the last-known-good **registry digest** and compatible configuration.
   Review shared secret/identity/network changes; an old image alone may not undo them.
3. Redeploy that digest through the approved application activation process as a
   new revision, without changing the environment's key-ring identity or applying
   destructive foundation changes. Do not merely retag a mutable image.
4. Verify the serving revision, probes, real sign-in and a permitted business
   operation. Check telemetry, audit continuity and cookie behavior.
5. If data/schema changes or corruption are involved, stop and involve the DBA.
   Image rollback neither reverses committed data nor restores a database. Approve
   any restore endpoint change and its data-loss window separately.
6. If ingress/DNS or platform configuration caused the incident, reverse the
   relevant approved change separately and validate DNS/TLS/callbacks.
7. Record recovery time, impact and follow-up actions in the team's incident system.

Do not delete the SQL database, key-ring Blob, Key Vault key/version or identity as
a rollback step. Backups and configured retention are not proof that restore works;
test database and key-ring recovery against the agreed RTO/RPO.

## Secret and key maintenance

| Item | Procedure / impact |
|---|---|
| Entra client secret | Create a replacement credential in the same app registration, store it as a new version of the referenced Key Vault secret, verify refresh and a fresh sign-in, then retire the previous credential. Keep an overlap window. |
| ACA secret references | The template uses a versionless Key Vault URI. Microsoft documents latest-version retrieval within 30 minutes and restart of active revisions using it as an environment variable. Verify completion; it is not instantaneous. Direct ACA secret updates do not themselves create a revision; restart/deploy as needed. |
| Key Vault wrapping key | Use the approved rotation policy/private-network process. Old encrypted key-ring entries reference specific key versions; rotation does not rewrap them. Keep required historical versions enabled and usable. |
| Data Protection key ring | Preserve Blob history/recoverability, application name and access. Do not routinely delete/reset it: that can invalidate cookies and outstanding antiforgery data. Coordinate any intentional reset as a security-impacting change. |
| Runtime UAMI | Keep resource identity and grants stable. Replacing/deleting it changes the principal and requires re-granting resource/database access. |
| Role/audit claim changes | Validate identity/audit continuity. Existing cookies do not continuously refresh Entra roles; removing an assignment does not guarantee immediate logout. Plan urgent revocation separately, not by casually deleting shared keys. |

Keep Production configuration, TLS validation and private connectivity intact
during maintenance. Runtime and secret-management permissions are different;
grant support staff only the access they need, including careful review of any
permission that can list secret values.

## Platform references

- [Define app roles and receive them in tokens](https://learn.microsoft.com/entra/identity-platform/howto-add-app-roles-in-apps)
- [Assign users/groups to an enterprise application](https://learn.microsoft.com/entra/identity/enterprise-apps/assign-user-or-group-access-portal)
- [Configure optional ID-token claims](https://learn.microsoft.com/entra/identity-platform/optional-claims)
- [ACA revisions and single-revision behavior](https://learn.microsoft.com/azure/container-apps/revisions)
- [ACA secrets and Key Vault refresh](https://learn.microsoft.com/azure/container-apps/manage-secrets)
- [ACA ingress and forwarded headers](https://learn.microsoft.com/azure/container-apps/ingress-overview#http-headers)
