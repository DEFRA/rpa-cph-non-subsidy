# Bicep handoff

This is a repository-only infrastructure handoff, not a deployment or production
approval. The receiving team supplies approved parameter values and manually
tests in its own subscription. No regional, quota, Azure Policy, what-if, cost,
recovery, compliance or deployed-runtime checks have been performed here.

## Files and stages

- [main.bicep](./main.bicep): foundation, network/private DNS/endpoints,
  user-assigned identity, ACR, Key Vault, private key-ring Blob
  storage, Azure SQL, monitoring and ACA environment. **No application starts.**
- [app.bicep](./app.bicep): application activation after the receiving-team
  prerequisites below. Uses the same foundation names and identity, and grants
  the runtime identity crypto access on the already bootstrapped wrapping key.
- [Initialize-DataProtectionKey.ps1](./Initialize-DataProtectionKey.ps1):
  separate operator-run, private-network key creation and rotation-policy setup.
  It does not open the vault, assign operator roles or activate the application.
- [Test-Templates.ps1](./Test-Templates.ps1): local compilation, synthetic
  negative tests and optional parameter-file validation. It does not log in,
  query Azure or deploy.
- Parameter examples are deliberately incomplete: `null` means **unknown**,
  not a valid production default. Copy them outside Git and supply every value.
  Their checked-in state is intentionally not deployable.

Both entry points target an existing resource group. The receiving team owns
resource-group creation, subscription selection and permissions. Supply the
same resource group, location, prefix, environment and tags for both stages.
Changing these identifiers can create a different stack; review what-if first.
The templates target Azure public cloud; sovereign-cloud compatibility is not
asserted.

## Local checks

Use an installed [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install).
Pinned AVM modules are restored from the public Microsoft registry. Generated
ARM JSON is temporary, not a handoff source file.

```powershell
.\infra\Test-Templates.ps1 -BicepPath 'C:\tools\bicep.exe'
.\infra\Test-Templates.ps1 -BicepPath 'C:\tools\bicep.exe' `
  -FoundationParameters 'C:\private\cph\foundation.parameters.json' `
  -ApplicationParameters 'C:\private\cph\application.parameters.json'
```

Run the parameter check before any Azure what-if or deployment. It rejects
missing/unknown fields, wrong types, provider-independent bounds, invalid
names/CIDRs, overlapping or out-of-VNet subnets, unsupported local CPU/memory
choices, invalid image digests, SQL minimum exceeding maximum and key rotation
at/after expiry. Provider/region-specific combinations still need owner checks.
Do not treat passing this script as budget/compliance/recovery certification.

## Required foundation inputs

Every input is required; none selects a region or production sizing for you.

| Inputs | Contract |
|---|---|
| `location`, `tags` | Owner-approved region and tag object; no default region. |
| `prefix`, `environmentName` | Lowercase alphanumeric, 2-6 and 2-3 characters. Names include deterministic resource-group-scoped uniqueness. |
| `vnetCidr`, `acaSubnetCidr`, `privateEndpointSubnetCidr` | Approved, canonical RFC1918 IPv4 ranges; nonoverlapping subnets inside VNet. ACA subnet /27 or larger. Check overlap with all connected networks and ACA platform-reserved ranges externally. |
| `acaZoneRedundant` | Explicit zone choice, subject to Consumption/region support. No Dedicated fallback. |
| `acrSku`, `acrZoneRedundant` | Basic/Standard/Premium; zone redundancy requires Premium. Standard registry RBAC, not repository ABAC. |
| `logRetentionDays`, `applicationInsightsRetentionDays` | Explicit supported retention; eventual regulatory adequacy remains owner review. |
| `keyRingStorageSku` | Explicit Standard LRS/ZRS/GRS/GZRS choice; geographic redundancy requires residency approval. |
| `blobSoftDeleteDays`, `vaultSoftDeleteDays` | Blob/container soft-delete 1-365 days; vault soft-delete 7-90 days. Vault purge protection is enabled. |
| `wrappingKeySize`, `wrappingKeyRotationDays`, `wrappingKeyExpiryDays` | RSA 2048/3072/4096; supplied rotation/expiry periods, rotation strictly before expiry. Foundation emits these as non-secret bootstrap inputs; it no longer creates the key. Apply them using the private-network bootstrap step. Validate policy bounds and ensure old versions remain available for key-ring decryption. |
| `sqlAdminName`, `sqlAdminObjectId`, `sqlAdminPrincipalType` | Supplied deployment-tenant Entra administrator: explicit `Group` or `User`. For an individual use their user principal name and user Object ID in this tenant, not their app/client ID. Never use the runtime identity as administrator. Replaces the earlier `sqlAdminGroupName`/`sqlAdminGroupObjectId` input names. |
| `databaseName` | Explicit database name, restricted by the local check to letters/digits/underscore/hyphen. |
| `sqlMinVcores`, `sqlMaxVcores`, `sqlMaxSizeGiB` | Explicit GP serverless Gen5 min/max/storage; fractional minimum is a string. Auto-pause is disabled (`-1`); minimum compute remains billed when idle. Confirm actual regional SKU limits. |
| `sqlZoneRedundant`, `sqlBackupRedundancy` | Explicit zone and Local/Zone/Geo/GeoZone backup choices. They do not establish an RPO/RTO or create a secondary server. |
| `sqlPointInTimeRetentionDays`, `sqlLongTermRetention` | Explicit PITR and LTR policy. LTR includes ISO durations for weekly/monthly/yearly retention and weekOfYear. Zero durations mean no LTR **only if the owner explicitly selects them**. |

This creates one ACA environment, SQL server/database and key-ring account,
not a multi-region failover topology. If the eventual RPO/RTO/compliance
requirements need geo-replicas, secondary compute, customer-managed database
encryption or another topology, extend/review the templates before deployment.
No paired region, recovery strategy, monthly ceiling or legal scope is assumed.

## Required application inputs

Copy [app.parameters.example.json](./app.parameters.example.json) outside Git
and replace every `null`. The example contains no credentials.

| Inputs | Contract |
|---|---|
| `location`, `prefix`, `environmentName`, `tags`, `databaseName` | Match foundation exactly. Do not select a second location or database accidentally. |
| `imageRepository`, `imageDigest` | Repository inside the new ACR and immutable `sha256:` digest obtained after receiving-team push. |
| `entraTenantId`, `entraClientId` | Supplied production Entra tenant/application IDs, never assumed from local development. |
| `entraClientSecretName` | Existing owner-populated secret **name** in the new Key Vault, not a secret value or arbitrary URL. ACA resolves its versionless reference through the UAMI. |
| `basicAccessRole`, `auditNameClaimType` | Exact approved production role value and unique audit claim contract. No audit-name fallback. |
| `containerSize` | Explicit supported CPU:memory pair, e.g. format `CPU:GiB`, selected from the Bicep allowed-values list. No default pair. |
| `minReplicas`, `maxReplicas`, `concurrentRequests` | Explicit bounds/HTTP threshold; min <= max, max 1-300. Confirm workload quota and subnet capacity, including temporary revision overlap, before deployment. |
| `terminationGracePeriodSeconds` | Explicit shutdown allowance, 1-600 seconds. |

The template obtains the trusted proxy CIDR from the actual foundation ACA
subnet, configures one-hop forwarding and HTTPS port 443, and supplies the
strict application hostname. Confirm the real ACA peer is inside that range;
do not replace this with a wildcard or trust-all setting if acceptance fails.
Liveness/readiness use HTTP8080 with that Host header, 10-second periods and
three-failure thresholds; these operational probe settings are not an RTO/SLA.
No platform Easy Auth is layered over the existing application Entra flow.

Shared Data Protection uses the private XML Blob, versionless wrapping-key URI,
stable prefix/environment discriminator and explicit UAMI client ID. SQL uses
Entra managed-identity authentication with that same client ID, encryption and
certificate validation. Application Insights receives its non-secret endpoint
connection string plus `Telemetry__ManagedIdentityClientId`; local ingestion
authentication is disabled on the component and the runtime identity receives
component-scoped Monitoring Metrics Publisher. No storage keys/SQL passwords
are supplied to the app.

## Manual deployment checkpoints

The following are **receiving-team commands**, not commands executed by this
handoff. Obtain production approvals before using them. Testing in a subscription
can incur charges and must use approved values and access.

### 1. Foundation

The operator needs resource deployment permissions plus narrowly scoped role
assignment privileges at the target scopes. Foundation does **not** create a
cryptographic key: an ARM key-create request is not automatically routed through
the private endpoint, and the previous template failed with
`ForbiddenByConnection` when both public access and trusted-service bypass were
disabled. Key creation now happens separately through an approved private path.
The templates do not grant the operator directory/Graph permissions or make
the application an SQL/Key Vault administrator.

```powershell
az account set --subscription '<approved-subscription-id>'
az deployment group what-if --resource-group '<approved-resource-group>' `
  --template-file '.\infra\main.bicep' `
  --parameters '@C:\private\cph\foundation.parameters.json'
az deployment group create --name 'cph-foundation' `
  --resource-group '<approved-resource-group>' `
  --template-file '.\infra\main.bicep' `
  --parameters '@C:\private\cph\foundation.parameters.json'
az deployment group show --name 'cph-foundation' `
  --resource-group '<approved-resource-group>' --query properties.outputs
```

Stop on failed validation/deployment. Review regional Consumption/private
network/zone support, SKU availability, quotas, costs, tenancy and policy before
retrying; never silently substitute a region, compute model or SKU.

Foundation outputs include the future application hostname/callback URLs,
registry, SQL server/database, identity resource/client/principal IDs and
versionless key/Blob URIs and `dataProtectionKeyBootstrap` inputs. The key URI is
the intended identifier, not proof the key exists. Outputs contain no secret
values. Do not copy deployment
history, environment dumps or credentials into Git.

### 2. Owner bootstrap, from an approved private-network path

1. Verify private DNS resolves SQL, Key Vault and Blob through the new private
   endpoints from the workload and operator execution paths. Public access to
   those services is disabled; do not temporarily open them to fix bootstrap.
   The NSGs retain default VNet/load-balancer rules and standard outbound,
   with public ACA HTTPS ingress allowed on platform ports 443/31443;
   they are **not** an internet egress allow-list or inspected firewall.
2. Push the receiving team's built image into ACR with a **separate** authorized
   build/push principal. Runtime gets registry-scoped `AcrPull` only. Obtain the
   repository's immutable `sha256:` digest; a local Docker image ID is not a
   registry digest. Admin credentials and anonymous pulls are disabled.
3. The identity team supplies the production Entra registration, app role,
   assigned users/groups and approved audit claim. Register the foundation's
   exact sign-in/sign-out callback URLs. Never reuse local test IDs implicitly.
4. Populate the configuration secret(s) in Key Vault through approved owner
   tooling and private access. Supply only the secret URI to application
   parameters, never its value. Do not inspect/list secret values in logs.
5. The DBA installs the owner-approved schema and creates the contained user
   for the output UAMI principal with the application's minimum CRUD/audit
   grants. No startup migration or Bicep SQL script creates schema/users.
   Resolve Entra object lookup permissions through the DBA's approved process;
   no automatic Graph/directory grants are included.
6. Create/verify the dedicated wrapping key and rotation policy using the
   private-network bootstrap instructions below. App activation grants its
   UAMI key-scoped crypto access; the operator needs separate key-management
   permissions. Confirm runtime Blob/container permissions. Persisted XML key-ring
   entries reference specific wrapping-key versions: keep those versions and
   recoverable Blob versions as long as needed. Automatic key rotation does
   **not** rewrap old XML or authorize deleting/expiring required versions.
7. Allow identity/RBAC propagation, then explicitly verify image pull, secret
   resolution and private service access. Do not use a fixed sleep as proof.
   Retry the failed stage only after its concrete prerequisite is satisfied.
8. Configure receiving-team operational alerts, notification routing and
   recovery procedures. No alert rules/action groups are generated here.

The same user-assigned identity survives an ACA app replacement only while its
separate identity resource is retained. Deleting the resource group deletes
that identity; do not describe the identity as permanently retained.

#### Private-network key bootstrap and recovery from ForbiddenByConnection

Keep the vault's `publicNetworkAccess: Disabled` and `bypass: None`. Rerun the
updated foundation with the **same subscription, resource group and names** in
incremental mode (the default) to complete missing resources and retrieve outputs.
Do not delete the vault or resource group; soft delete/purge protection also make
destructive retries inappropriate. Do not use complete deployment mode to
remove the former key resource.

Use a private-network-connected workstation, a suitably connected existing VM,
or an approved runner with private DNS resolution to the new vault endpoint.
A normal laptop or ordinary public Cloud Shell is **not** connected merely
because a private endpoint exists. VPN/peering/routing/private DNS or a connected
execution host must already be arranged; this fix does not provision them.

The operator signs into the explicit deployment subscription and needs **Key
Vault Crypto Officer** or equivalent key list/create/read/rotation-policy
permissions at this vault. A subscription Contributor role alone does not grant
these data-plane permissions. Have the authorized platform owner assign the
appropriate operator role and allow propagation; the script does not grant
itself privileges. These are operator rights, not application rights.

Read `dataProtectionKeyBootstrap` from the successful foundation outputs and
pass its values explicitly on that private-network host:

```powershell
.\infra\Initialize-DataProtectionKey.ps1 `
  -SubscriptionId '<output subscriptionId>' `
  -ResourceGroupName '<output resourceGroupName>' `
  -VaultName '<output vaultName>' `
  -WrappingKeySize <output wrappingKeySize> `
  -WrappingKeyRotationDays <output wrappingKeyRotationDays> `
  -WrappingKeyExpiryDays <output wrappingKeyExpiryDays>
```

Replace the placeholders before running. The script reuses a compatible existing
`data-protection` RSA key; it does not rotate/recreate it on every run. It applies
the explicit rotation policy, reports failures and never exports private key
material. A failed policy update can be retried without creating another key
version. A soft-deleted key requires owner recovery rather than overwriting it.
Do not proceed until this step succeeds. Keep required historical key versions
usable; expiry/rotation settings alone do not prove recovery or decryption
retention adequacy.

Then continue owner bootstrap and app activation. Key-scoped RBAC in
[app.bicep](./app.bicep) must propagate before the app can wrap/unwrap keys;
deployment ordering alone does not guarantee immediate authorization. Leave
the vault private if access fails and diagnose DNS/connectivity/RBAC separately.

### 3. Application activation and acceptance

Run the local parameter check, then receiving-team what-if and deployment for
[app.bicep](./app.bicep) using the same scope/names/location as foundation.
The application must use its user-assigned identity for SQL, Blob and wrapping
key operations; Key Vault configuration references are resolved by ACA.

```powershell
az deployment group what-if --resource-group '<approved-resource-group>' `
  --template-file '.\infra\app.bicep' `
  --parameters '@C:\private\cph\application.parameters.json'
az deployment group create --name 'cph-application' `
  --resource-group '<approved-resource-group>' `
  --template-file '.\infra\app.bicep' `
  --parameters '@C:\private\cph\application.parameters.json'
```

Rebuild the Linux image from the updated source before the owner pushes it.
The previously tested local Razor Pages image predates the shared-key-ring and
ACA runtime integration; do not treat that old local image as this release.

Verify HTTPS, anonymous liveness/readiness (SQL failures must give readiness
503 while liveness stays healthy), Entra sign-in/roles/audit, protected CRUD,
logout and callback origins. Verify cookies survive a replica/revision change
with the shared encrypted key ring. Test real ACA forwarding/trust with the
receiving network; local tests alone cannot establish that proxy contract.

On application failure, retain foundation, identity and key ring for diagnosis.
The operator owns rollback to the last known-good image/configuration and
verifies traffic/authentication/readiness; do not claim a rollback RTO without
rehearsal. Schema and data rollback belong to the DBA and are not an app-image
rollback. Do not delete the vault/storage/identity to retry activation.

## Module pins and validation boundary

AVM versions are explicit in source and restored from Microsoft Container
Registry: identity 0.6.0; VNet 0.10.2; Log Analytics 0.16.1; Application Insights
0.8.0; ACR 0.13.1; Key Vault 0.14.2; Storage 0.33.1; SQL 0.22.1; ACA environment
0.16.0; ACA application 0.23.0. The private endpoint/DNS helper and NSG
resources use native Bicep
for their small, explicit contracts. AVM usage telemetry is disabled.

AVM secure internal outputs may include platform keys; this handoff never
re-exports, prints or uses storage keys for application authentication.
Do not dump nested deployment outputs. Compilation does not exercise ARM
authorization, private data-plane access, provider policies or RBAC propagation.

Production gates D-08/D-11/D-12/D-13 remain pending; D-14/D-15 cutover/downtime
and D-16 CI/CD remain separate receiving-team decisions. No Phase 4 approval is
implied by the existence of these files.

References: [ACA networking](https://learn.microsoft.com/azure/container-apps/networking),
[ACA NSG requirements](https://learn.microsoft.com/azure/container-apps/firewall-integration),
[managed-identity ACR pulls](https://learn.microsoft.com/azure/container-apps/managed-identity-image-pull),
[key rotation](https://learn.microsoft.com/azure/key-vault/keys/how-to-configure-key-rotation),
[Key Vault network security](https://learn.microsoft.com/azure/key-vault/general/network-security).
