# Parallel internal ACA implementation

Repository-only implementation, **not deployment approval**. The deployed App
Service foundation remains in place. Do not rerun that foundation or the legacy
[main.bicep](../main.bicep) to introduce ACA: both own existing foundation resources.
Pipeline, customer parameters, application code and the legacy ACA/App Service
implementations are unchanged.

## Safe parallel plan

| Component | Ownership and proposed Contoso configuration |
| --- | --- |
| VNet | Read-only reference to the deployed foundation VNet; no parent VNet PUT |
| ACA subnet | New `aca-parallel`, proposed `10.240.4.0/23`; owner must recheck against complete fresh subnet inventory |
| App Service subnet | Existing `10.240.3.0/26` and Microsoft.Web delegation remain untouched |
| Endpoint subnet | Reuse existing undelegated `10.240.2.0/24`, subject to verified free capacity |
| SQL/database, Vault, Blob container | Reuse exact existing resource IDs and private connectivity; no parent redeployment |
| Basic foundation ACR | Untouched; not upgraded or made private |
| New ACA registry | Separate Premium ACR with public/admin/anonymous access disabled and private endpoint |
| Runtime identity | Separate ACA identity; scoped AcrPull, telemetry, vault-secret and Blob-container roles |
| ACA | Separate internal workload-profile environment, Consumption profile, new application in the later activation stage |
| Monitoring | Separate private-only workspace/Application Insights; new or explicitly authorised existing PrivateOnly AMPLS |
| DNS | Shared service zones retained; new monitoring/registry zone groups and owner-approved links; new environment-domain zone with apex/wildcard private A records |

The separate Premium registry follows the private People API pattern **without
changing the deployed Basic registry**. Its additional cost and private build-host
requirements must be confirmed before deployment. The private architecture is
already approved; missing Azure RBAC is a deployment prerequisite, not grounds
to enable public access. No Azure ownership is assumed. The /23 subnet is proposed test configuration, not a
claim of currently unallocated space. Existing subnet mode writes no subnet/NSG.
Create mode writes only a dedicated new NSG and VNet child subnet.

New subnet NSG preserves Azure default outbound/control-plane connectivity and
allows private HTTPS ingress. It is not a complete firewall/egress-isolation
policy. Existing NSGs, routes, NAT, peering and DNS-server settings are not changed.
Owners must verify DNS forwarding and required ACA/Entra outbound access.

## Files and sequence

1. [main.bicep](main.bicep): new parallel infrastructure only; no app/image required.
2. [app.bicep](app.bicep): activation with a real image digest, verified Entra
   application/secret and completed database/key prerequisites.
3. [modules/](modules/): subnet, AMPLS associations/endpoint, internal DNS and
   least-privilege access workers. Existing corrected identity/private-DNS/
   endpoint workers are referenced relatively from [appservice/](../appservice/).
4. [main.parameters.example.json](main.parameters.example.json) and
   [app.parameters.example.json](app.parameters.example.json): **incomplete test
   examples**, not customer defaults. Copy outside Git and supply every null.
5. [Test-AcaTemplates.ps1](Test-AcaTemplates.ps1) and
   [Test-AcaRegression.ps1](Test-AcaRegression.ps1): local build/lint, exact-error
   fixture tests, compiled ownership/privacy checks and optional inventory preflight.

After a separately approved infrastructure deployment, use its actual outputs
to populate the app parameters: `managedEnvironmentResourceId`,
`managedIdentityResourceId`, `registryResourceId`, `acaSubnetResourceId`,
`logAnalyticsResourceId`, `applicationInsightsResourceId` and
`reusedFoundationResources`. Other outputs identify the private AMPLS/endpoint,
DNS zones, identity principal/client IDs, registry server, internal IP and proposed
application origin. Owner bootstrap/DBA/image work occurs before app activation.
Do not use an App Service image digest or identity without verifying the intended
registry/image and separate ACA principal.

## Shared AMPLS and DNS ownership

Microsoft requires one AMPLS per VNet/shared DNS view. Discovery must include all
VNets sharing that view, not merely the workload RG. Private monitoring DNS
overrides affect other consumers. Foundation workspace/Application Insights are
always covered without changing their public-network flags; every additional
consumer must be supplied or already associated with an authorised existing scope.

Required zones are `privatelink.monitor.azure.com`,
`privatelink.oms.opinsights.azure.com`, `privatelink.ods.opinsights.azure.com`,
`privatelink.agentsvc.azure-automation.net` and
`privatelink.blob.core.windows.net`. Reuse the foundation Blob zone and its
`application-network` link. ACR additionally requires `privatelink.azurecr.io`.

Creating an endpoint zone group writes DNS records even when its zone is Existing.
An Existing zone is not a read-only record-management contract. Explicit owner
approval is required. New zones are created without links first; AMPLS associations
and endpoint groups precede publishing the monitoring links. Existing monitor
endpoint mode makes **no endpoint or zone-group writes** and requires an exact
target, subnet, Approved status and five-zone match.

Existing AMPLS mode requires PrivateOnly ingestion/query and approval for new
associations. `existingScopeLinkedResourceIds` must exactly match the verified
existing scoped-resource targets: these associations are skipped, regardless of
their owner-chosen names, rather than adopted or overwritten. Only new association
children are created. Planned resource-name collisions fail; existing application
or parallel-infrastructure adoption/redeployment is intentionally unsupported.
External/platform-managed DNS associations/groups are not supported by this
path: stop and establish an explicit ownership contract rather than bypass checks.

## Inventory preflight contract

No inventory or real parameter files are checked in. The old pre-foundation empty
inventory is stale and must not be reused. Supply an owner-approved snapshot
captured within 24 hours, from successful read-only Azure discovery:

- `subscriptionId`, `tenantId`, `resourceGroupName`, `capturedAtUtc`, `complete: true`,
  `approvalReference`, `dnsViewVnetIds` (all VNets sharing the selected DNS view).
- `resources`: complete `{ id, ... }` ARM metadata, including database, Blob
  container and subnets; include planned-name collision discovery in every
  affected scope, and registries whose names could conflict.
- `virtualNetworks`: raw ARM `id`, `location`, `properties.addressSpace.addressPrefixes`
  and complete `properties.subnets`, each with matching `id`, `name`, one canonical
  `properties.addressPrefix` and `properties.delegations`. No guessed capacity.
- Endpoint subnet `availableIpAddressCount`: integer, verified from allocation
  inventory. This path budgets 11 AMPLS plus two single-region ACR endpoint
  addresses when creating both, or two when reusing a monitor endpoint.
- Existing ACA subnet `exclusiveForNewAcaEnvironment: true`: owner confirmation
  that no other environment or allocation owns the subnet; integer
  `availableIpAddressCount` must equal its total addresses minus five Azure
  reserved addresses before creating the new environment.
- `privateDnsZones`: `{ id, name, links: [{ name, vnetResourceId,
  registrationEnabled }], authorisedZoneGroupVnetIds }`. Authorisations are
  explicit owner confirmations, not fields inferred from Azure resource names.
- `privateEndpoints`: normalised `{ id, targetResourceId, subnetResourceId,
  groupId, status, dnsZoneResourceIds }`, from actual connection and zone-group
  metadata. Include foundation SQL/Vault/Blob and all monitoring endpoints.
- `privateLinkScopes`: `{ id, dnsViewVnetIds, ingestionAccessMode, queryAccessMode,
  authorisedNewAssociations, scopedResources: [{ name, linkedResourceId }] }`.
  Include scopes affecting the entire shared DNS view.
- `monitoringConsumerResourceIds`: complete owner-confirmed workspace/AI consumers.
  `approvalReference` must equal `sharedDnsChangeApprovalReference`.
- App-stage additions: raw environment, private registry and identity metadata in
  `resources`, plus private ingestion/query flags for workspace/AI and the AI
  `WorkspaceResourceId` binding; `containerImages: [{ registryResourceId, repository, digest }]`;
  `entraApplications: [{ clientId, tenantId, secretVaultResourceId, secretName,
  appRoles }]` with references only, **no secret values**.
- `applicationReadinessApprovalReference`: owner confirmation of the new ACA
  identity's actual RBAC/SQL grants, enabled bootstrapped wrapping key, secret
  accessibility, private clients/DNS/egress and internal Entra callback URLs.

Inventory completeness/authorisation are owner attestations. Local preflight does
not authenticate metadata, verify permissions, inspect live SQL grants or certify
Azure readiness. Missing fields, unknown inventory or unsupported ownership fail.
All referenced foundation resources must be in the workload subscription.
Shared zone/scope workers use the exact referenced resource-group scopes; those
cross-scope writes need explicit approval and permissions.

```powershell
.\infra\aca\Test-AcaTemplates.ps1 -BicepPath 'C:\tools\bicep.exe'
.\infra\aca\Test-AcaTemplates.ps1 -BicepPath 'C:\tools\bicep.exe' `
  -FoundationParameters 'C:\private\aca\main.parameters.json' `
  -NetworkInventory 'C:\private\aca\network-inventory.json'
.\infra\aca\Test-AcaTemplates.ps1 -BicepPath 'C:\tools\bicep.exe' `
  -ApplicationParameters 'C:\private\aca\app.parameters.json' `
  -NetworkInventory 'C:\private\aca\application-inventory.json'
```

## RPA compatibility, prerequisites and cost

Application settings preserve CPH SQL managed-identity authentication, Entra
secret references, CPH/Audit authorisation, health endpoints and the existing
Blob key ring. Data Protection application name remains `prefix-environment`,
not the new ACA resource stem. Trusted proxy CIDR comes from the actual dedicated
ACA subnet. No People-specific application settings are copied.

The DBA must grant the **new ACA principal** the CPH/Audit permissions documented
in [Grant-DatabaseAccess.sql](../appservice/Grant-DatabaseAccess.sql). An authorised
private-network operator must complete [key bootstrap](../Initialize-DataProtectionKey.ps1).
Neither happens in these templates. Supply a real Entra app, vault secret reference,
role and internal callbacks; build/push a real image from a private-connected host.

Additional charges include Premium ACR, private endpoints, DNS zones/queries,
monitoring ingestion/retention, ACA compute when running, and ACA-managed load
balancer/egress IP infrastructure in its platform-managed resource group. Existing
App Service foundation costs continue. Scale-to-zero does not eliminate these
fixed charges. Thirty-day retention and `0.25:0.5Gi`, 0-2 replicas are test examples,
not production sizing/availability guidance.

Deployment remains blocked until fresh inventory/ownership, private build access,
real runtime inputs and operator prerequisites are confirmed. Live provider
validation, permission/policy/quota review, reviewed What-If and explicit deployment
approval are still required. No Azure checks or deployments are performed by the
local test scripts. The older external handover copy is not refreshed by this work.

Before any future deployment, coordinate **all** ACA entry points, including
[the legacy foundation](../main.bicep), [legacy app](../app.bicep) and this parallel
path. Resolve resource/deployment names, ownership, shared DNS, AMPLS coverage
and platform-managed infrastructure RG impact. Do not deploy competing stacks or
recreate the App Service foundation. This conversation's implementation is confined
to this directory; other observed legacy-path changes are preserved and excluded.
Following CAF, landing-zone governance, policy, least-privilege access and network
ownership must be technically validated before live execution.

References: [ACA custom networks](https://learn.microsoft.com/azure/container-apps/custom-virtual-networks),
[Azure Monitor Private Link design](https://learn.microsoft.com/azure/azure-monitor/fundamentals/private-link-design),
[ACR Private Link](https://learn.microsoft.com/azure/container-registry/container-registry-private-link),
[CAF Azure landing zones](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/),
[Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/).
