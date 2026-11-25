# Azure App Service (Linux container) infrastructure

Hosting option for `rpa-cph-non-subsidy` on **Azure App Service for Containers**, with Azure Container Registry.
It sits beside the Container Apps templates in [`../`](../README.md) and does not change them.

**Status:** repository-only handoff, validated locally (compile, lint, rule self-tests, container build and run,
image scan, unit/integration/browser tests). Nothing here has been deployed. No region, quota, policy, what-if, cost,
RBAC propagation or live-runtime check has been performed. Production gates D-08 (region), D-12 (cost ceiling) and
D-13 (RPO/RTO) are still pending, see [`../../reports/Decisions-Required.md`](../../reports/Decisions-Required.md).

## What is created

| Stage | Entry point | Resources |
|---|---|---|
| 1 Foundation | [main.bicep](./main.bicep) | Selected new/existing VNet and subnets (new NSGs and optional NAT only for newly created subnets), user-assigned identity, Log Analytics and Application Insights with private-only network access, Azure Monitor Private Link Scope (AMPLS) with PrivateOnly ingestion/query, ACR, Key Vault (RBAC), private Blob key-ring storage, Azure SQL (Entra-only), private endpoints with independently owned DNS for SQL/Key Vault/Blob/Monitor services, App Service Plan (+ optional autoscale). **No application starts.** |
| 2 Application | [webapp.bicep](./webapp.bicep) | Web app (Linux container pulled from ACR by digest), optional staging slot with sticky `AllowedHosts`, key-scoped crypto role assignment, diagnostics, metric alerts and optional action group. |

Modules live in [modules/](./modules): `networking`, `identity`, `monitoring`, `registry`, `keyVault`, `storage`,
`database`, `privateEndpoint`, `privateDnsZone`, `monitor-private-link-scope`, `monitor-private-endpoint`, `appServicePlan`, `appService`, `alerts`. AVM versions pinned in source are reused from the
Container Apps templates (identity 0.6.0, Log Analytics 0.16.1, Application Insights 0.8.0, ACR 0.13.1, Key Vault 0.14.2,
Storage 0.33.1, SQL 0.22.1, VNet 0.10.2). AVM VNet is used only for a project-owned new VNet.
Web, plan, autoscale, NAT, NSGs, child subnets in existing VNets, private DNS, monitor AMPLS, monitor endpoint, and alert resources use native Bicep.

## Inputs

Copy [main.parameters.example.json](./main.parameters.example.json) and [webapp.parameters.example.json](./webapp.parameters.example.json)
outside Git. `null` means **unknown**; the checked-in files are intentionally not deployable. Validate with:

```powershell
.\infra\appservice\Test-AppServiceTemplates.ps1 -BicepPath 'C:\tools\bicep.exe' `
  -FoundationParameters 'C:\private\cph\main.json' -ApplicationParameters 'C:\private\cph\webapp.json' `
  -NetworkInventory 'C:\private\cph\network-inventory.json'
```

Negative self-tests clone a valid fixture for each case and require its exact expected validation error.
Successful actions and unrelated exceptions fail the negative-test harness; the original fixtures are
validated again after the negative cases. Nested fixtures are deep-cloned. All 15 Step 1 cases and both
harness regression checks remain in place. Networking tests cover every supported Create/Existing
combination, capacity boundaries, ownership errors and the actual compiled conditional resource writes.

App Service requires both `productionImageDigest` and `stagingImageDigest` to be real registry
`sha256:<64 lowercase hex>` digests. Null examples are intentionally rejected; never replace them with
invented digests or mutable tags. The separate [ACA application parameters](../app.parameters.json)
use `imageDigest` and are not App Service inputs. A null `imageDigest` in that file is incomplete ACA
configuration, not an App Service validator defect. Obtain the registry digest through the approved
image-publishing process before validating a completed parameter file.

Notable owner inputs: `location`; `planSkuName` (staging slot and autoscale need Standard or Premium, zone redundancy needs
Premium v3 with two or more instances); `networking` (see below); `pipelinePrincipalObjectId`
(AcrPush for the pipeline; empty = none); `trustedProxyCidr` (see Assumptions); `routeAllOutboundThroughVnet`
(required for Key Vault references that resolve over a private endpoint; use an approved egress path).

## Networking ownership and parameter migration

The former top-level `vnetCidr`, `integrationSubnetCidr`, `privateEndpointSubnetCidr` and `enableNatGateway`
parameters are replaced by typed `networking`. Update externally managed foundation parameter files.
The application parameter file now requires `integrationSubnetResourceId`: copy the foundation output
or supply the approved existing subnet ID. Production and staging use the same selected subnet.
The pipeline's secure parameter files must be updated before use. Its initial validation job runs
template/self-tests; the Deploy tasks additionally run the same preflight against the actual secure
parameter files and owner-approved inventory immediately before deployment.

### Pipeline preflight

Upload `network-inventory.json` to Azure DevOps Secure Files and authorize this pipeline to use it,
alongside `webapp.parameters.json` and, when foundation deployment is enabled, `main.parameters.json`.
Missing or unauthorized inventory blocks the deployment job. No placeholder inventory is generated.

Foundation preflight must pass before either what-if or deployment runs. Application preflight uses
a private temporary JSON file containing the actual secure application parameters plus the final
`imageRepository`, production digest and staging digest overrides. The deployment consumes that same
validated file, with no subsequent parameter overrides. Source parameters remain unchanged.
The temporary file is deleted on success or failure; Unix permissions are restricted before writing.
Parameter contents and deployment result objects are not printed in pipeline logs.

Validation exceptions stop the task before its deployment command. The initial deployment approval,
App Service architecture, staging validation, swap and rollback stages are unchanged.
Inventory remains owner-supplied evidence, not a live Azure check. If foundation creates networking
that is absent from the approved snapshot, application preflight blocks activation: obtain fresh
owner-approved inventory and rerun application deployment with `deployFoundation = false`.
Never pre-populate inventory with assumed post-deployment resources.

`networking.mode` is the VNet ownership mode:

| Mode | Required fields | Behavior |
|---|---|---|
| `Create` | `vnetCidr`, `dnsServers`, `integrationSubnet`, `privateEndpointSubnet` | Both subnets must be `Create`. Empty `dnsServers` explicitly selects Azure DNS; a supplied IPv4 array selects approved servers. No DNS resolver is created. |
| `Existing` | `vnetResourceId`, `integrationSubnet`, `privateEndpointSubnet` | Full resource IDs select the VNet and reused subnets. Either or both subnets can instead be explicitly `Create`. |

Each subnet is `{ "mode": "Existing", "resourceId": "<full subnet resource ID>" }` or
`{ "mode": "Create", "cidr": "<approved CIDR>" }`. New integration subnets additionally require
`enableNatGateway` as an explicit boolean. Existing subnet contracts reject NAT/CIDR mutation fields.
Both selected subnets must belong to the selected VNet and must not overlap.

New-resource names remain `<stem>-vnet`, `integration`, `private-endpoints`,
`<stem>-integration-nsg`, `<stem>-pe-nsg`, `<stem>-nat` and `<stem>-nat-pip`.
Creation in an existing VNet uses scoped child resources, never a replacement parent subnet array.
The [networking module](./modules/networking.bicep) derives the subscription and resource group from
the full existing VNet ID and references that exact scope. Its [resource module](./modules/networkingResources.bicep)
deploys subnet/NSG/NAT resources there, including when the caller is in another resource group or subscription.
However, **foundation preflight rejects an existing VNet in a different subscription from the
workload**: the SQL/Vault/Blob endpoints deploy in the workload subscription, and Microsoft requires
Private Endpoints to share their VNet's subscription and region. Supply a valid full VNet resource ID
in the owner-approved workload subscription. Same-subscription cross-resource-group reuse remains
supported. The generic networking module's cross-subscription scope tests are not approval to deploy
the complete foundation across subscriptions. No endpoint deployment is moved into a customer subscription.
The Create path retains the caller's scope, resource names, properties and outputs.
New supporting resources are created in that VNet's resource group. Pure reuse skips that deployment.
Existing resources are neither retagged nor assigned replacement NSGs, NAT, routes or DNS servers.
Empty `natPublicIpAddress` means this deployment did not create NAT; it does not describe existing egress.

**Sizing:** newly created integration subnets must be `/26` or larger. Reused subnets may be `/28`
or larger if the planned scale fits. Five Azure-reserved addresses are excluded; the validator requires
capacity for twice the planned maximum instances (including other plans) and checks available addresses.
For example, `/26` has 59 usable addresses: 29 instances fit doubled capacity; 30 require a larger subnet.
Multi-plan subnet join requires `/26` or larger and customer verification that all plans share an
App Service subscription. This Linux-container app consumes integration addresses per plan worker,
not an extra allocation per staging slot. Rapid scaling and delayed address release can need additional
headroom; the customer must review the operating envelope.

The private-endpoint subnet remains separate and undelegated, with capacity for the three current
SQL/Vault/Blob endpoints. **Azure Monitor/AMPLS subnet sizing is a separate future requirement.**
VNet integration is outbound-only; public App Service ingress, route-all behavior and application
settings remain unchanged. NAT provides stable egress/SNAT, not traffic filtering.

## Private DNS ownership

`privateDns.sql`, `privateDns.vault` and `privateDns.blob` each require:

- `zone`: `{ "mode": "Existing", "resourceId": "<approved zone ID>" }` or `{ "mode": "Create" }`.
- `link`: `{ "mode": "Existing", "name": "<actual link name>" }`,
  `{ "mode": "Create", "name": "<authorized unused link name>" }`, or `{ "mode": "External" }`.
- `zoneGroupOwner`: `Project` (this workload creates the endpoint zone group) or `Platform`
  (approved platform automation owns it; this workload creates no zone group).

The existing zone names remain `privatelink.database.windows.net`, `privatelink.vaultcore.azure.net`
and `privatelink.blob.core.windows.net` in Azure public cloud. Reuse the platform's existing zone IDs.
Do not create another copy in the workload resource group. The foundation uses Bicep `existing`
references for existing zones and links; only an authorized new link deploys into the DNS-owning
resource group. The DNS worker creates a zone only in Create mode and uses the full zone/link name
for new links, without a duplicate Existing-zone alias that ARM would reject as the same resource.
Link creation is rejected if its name already exists or the zone already links to the selected VNet.
New project-owned zones require the original `application-network` link and a project-owned zone group.

`External` requires owner evidence of forwarding/resolver coverage and no direct link to this VNet.
Peering does not automatically provide private DNS resolution. `Platform` requires owner evidence of
zone-group automation; do not select it merely to bypass permissions. Project-owned zone groups manage
records in the existing zones, so reuse still requires DNS authorization and coordination with existing
records. Endpoint names and SQL/Vault/Blob target subresources remain unchanged.

## Azure Monitor private-only configuration

This foundation deploys Log Analytics and Application Insights with **public network access disabled**.
Both services route through Azure Monitor Private Link Scope (AMPLS) for private ingestion and query access.
Four additional private DNS zones are created for monitor services:

- `privatelink.monitor.azure.com` (Azure Portal and API ingestion)
- `privatelink.oms.opinsights.azure.com` (Log Analytics ingestion)
- `privatelink.ods.opinsights.azure.com` (Metrics and diagnostics ingestion)
- `privatelink.agentsvc.azure-automation.net` (Extension service and agent communication)

A fifth zone, `privatelink.blob.core.windows.net`, is reused from the Key Vault private endpoint
configuration to support monitor backup and diagnostic data storage.

`monitoringAmpls` selects AMPLS ownership:

| Mode | Behavior |
|---|---|
| `Create` | A new project-owned AMPLS is created with PrivateOnly ingestion and query modes. Log Analytics and Application Insights are associated. This is the default for initial deployments. |
| `Existing` | An existing AMPLS is used. The `associationOwner` field determines whether this workload or platform automation manages the associations. |

`monitoringPrivateEndpoint` selects monitor endpoint ownership:

| Mode | Behavior |
|---|---|
| `Create` | A new monitor private endpoint is created with the `azuremonitor` group, connecting to AMPLS over five private DNS zones. Project-owned zones are linked to the VNet. This is the default for initial deployments. |
| `Existing` | An existing private endpoint is used. The `resourceId` must be supplied. The endpoint must already be PrivateOnly with correct zone associations. |

The monitor endpoint uses a single DNS zone group named `default`, managed by this workload only when
all four monitor DNS zones are project-owned. When zones are platform-owned, the zone-group owner must be
approved to manage group associations; this workload will not update the group. Platform-owned zones still
require VNet links.

For multi-workload or incremental deployments, coordinate:

1. AMPLS centralization: one shared AMPLS per environment or one per workload. For shared AMPLS,
   use `Create` only for the first deployment; subsequent deployments select `Existing` with
   `associationOwner: Platform` and supply the platform AMPLS resource ID.
2. Monitor private endpoint: one shared endpoint per AMPLS or one per workload. For shared endpoints,
   use `Create` only initially; subsequent deployments select `Existing` and supply the endpoint resource ID.
3. DNS zone-group management: synchronized across deployments. If zones or groups already exist,
   refresh inventory and confirm zone-group ownership before selecting `Existing`.

Disabling public access on existing workloads requires a coordinated update:
- Ensure AMPLS and private endpoint are fully operational and verified.
- Disable Log Analytics public access via `publicNetworkAccessForIngestion: 'Disabled'`.
- Disable Application Insights public access similarly.
- Applications must route telemetry through the private endpoint (VNet integration, private DNS,
  and correct Application Insights instrumentation key are prerequisites).
- Monitor any ingestion delays during the transition.

## Private DNS ownership and other resources

### Existing Private Endpoints: fail-closed restriction

Foundation preflight checks `<prefix>-<environment>-sql-pe`, `-vault-pe`, `-blob-pe` and `-monitor-pe` in the workload
resource group against both `resourceIds` and the required `privateEndpoints` inventory array.
Any existing planned endpoint blocks foundation deployment, including endpoints claimed to be
project-owned. Naming, tags, an `owner` claim, or apparently matching ARM properties do not authorize
adoption. The current supported inventory contract cannot prove the exact deployment-generated target
and endpoint/zone-group ownership, so no existing-endpoint reuse or update is approved automatically.

Obtain owner-confirmed endpoint ARM IDs, actual target/subresource, subnet, and all DNS zone groups
(zone IDs and owners), plus explicit authorization for any ownership handoff. An approved reuse design
and validation are required before changing this restriction; do not rename around a collision or
delete customer endpoints. Until then, subsequent application deployments use `webapp.bicep` with
`deployFoundation = false`; foundation redeployment is blocked once its planned endpoints exist.
Project-to-Platform DNS ownership changes also require coordinated handoff: disabling group creation
does not remove an already deployed group in an incremental deployment.

## Required inventory preflight

The validator never logs in or queries Azure. Completed foundation/application parameter files require
`-NetworkInventory`, containing a fresh, complete, owner-approved inventory for every selected scope.
Keep it outside Git. Its root fields are:

- `subscriptionId`, `resourceGroupName`: the workload deployment scope.
- `capturedAtUtc`: UTC capture timestamp (future timestamps are rejected).
- `virtualNetworks`: VNet ARM objects with `id`, `location`, `properties.addressSpace.addressPrefixes`
  and complete `properties.subnets`, including each subnet's `id`, `name`, `addressPrefix` and `delegations`.
- `resourceIds`: complete resource IDs in the workload resource group and relevant network scopes,
  including Private Endpoints, NSGs, NAT and public IPs.
- `privateEndpoints`: required for foundation validation; a complete array of existing endpoint ARM
  objects with full `id` values, including every endpoint in the workload resource group. An empty
  array is valid only when the owner confirms none exist. Do not omit colliding endpoints or invent
  ownership values. Existing inventory must be refreshed by its owner, not automatically supplemented.
  Application-only validation does not require this field.
- `privateDnsZones`: objects with `id` and complete `links` (link `name`, `properties.virtualNetwork.id`,
  `registrationEnabled`, `provisioningState`). Include all approved shared service zones.
- `applicationMaxInstanceCount`: required for application validation; use the foundation's approved
  maximum (autoscale maximum when enabled, otherwise plan instance count).

Each reused integration subnet also requires these integer evidence fields alongside `properties`:

```json
{
  "availableIpAddressCount": 59,
  "currentPlanInstanceCount": 0,
  "otherPlanMaxInstanceCount": 0,
  "otherPlanCurrentInstanceCount": 0
}
```

These numbers are synthetic examples, not DEFRA values. The owner must establish real free-address
counts, including platform allocations not visible as ordinary NICs, and other plans' scaling budgets.
Current counts identify allocations already used by this workload/other plans; available addresses
plus those counts must cover doubled planned maxima. Reused endpoint subnets need
`availableIpAddressCount` with at least three free addresses.
For external DNS, supply zone-level `externalResolutionVnetIds`; for platform-owned zone groups,
supply `platformZoneGroupVnetIds`. Both list the specific VNets covered by approved platform evidence.

Creation collisions are rejected, not treated as permission to update resources. After creating a
network/zone/link, refresh inventory and select `Existing` for subsequent deployments. Inventory is
not an existing-endpoint adoption mechanism; the fail-closed endpoint restriction above still applies. It is
not proof of current Azure state: owners must refresh/review it immediately before what-if/deployment,
confirm delegation, region, available addresses, provider registration, cross-scope permissions,
NSG/UDR/NAT behavior and end-to-end DNS resolution. Never bypass preflight for shared-resource changes.

## Deployment sequence (receiving-team commands, not run here)

1. **Foundation**: run the inventory preflight above, then `az deployment group what-if` and `create`
   with `main.bicep`. Check that no shared-resource updates are planned. Read the outputs.
   The identity wrapper and its AVM deployment use distinct deployment names; managed identity resource naming is unchanged.
2. **Owner bootstrap** (private-network host): DNS resolves SQL/Key Vault/Blob to private IPs; create the wrapping key with
   [`../Initialize-DataProtectionKey.ps1`](../Initialize-DataProtectionKey.ps1) using the `dataProtectionKeyBootstrap` output;
   put the Entra client secret in Key Vault; register `signInCallback`/`signOutCallback` in the Entra app; the DBA runs
   [Grant-DatabaseAccess.sql](./Grant-DatabaseAccess.sql) and applies the approved schema.
3. **Image**: [`../../scripts/Build-PushImage.ps1`](../../scripts/Build-PushImage.ps1) (or the pipeline) pushes
   `:<version>` and `:sha-<commit>` and records the immutable digest. `latest` is never used.
4. **Application**: validate the updated parameter file with refreshed inventory, then use `webapp.bicep`
   with the selected integration subnet ID and digests. First deployment uses the same digest for production and staging.
5. **Validate**: [`../../scripts/Test-Deployment.ps1`](../../scripts/Test-Deployment.ps1), then swap.

[`../../azure-pipelines.yml`](../../azure-pipelines.yml) automates steps 3-5 (and optionally 1) with an approval gate,
staging-slot validation, swap, production validation and swap-back rollback.

## Well-Architected alignment

| Pillar | What is implemented | Gap or owner decision |
|---|---|---|
| Security | Managed identity everywhere (ACR pull, SQL, Blob, key wrap, telemetry); Entra-only SQL; Key Vault RBAC, purge protection, private; shared-key and ACR admin disabled; HTTPS-only, TLS 1.2, FTPS and SCM/FTP basic auth off; secrets via Key Vault references. | Site is public (Entra sign-in is the control). Consider Front Door/WAF or access restrictions. ACR is public with Entra auth; Premium + private endpoint + private build agent is the hardening path. |
| Reliability | Health check on `/health/ready`, optional zone redundancy, autoscale, slot swap rollback, SQL/blob soft delete and versioning. | No multi-region or geo-replica. D-13 pending. |
| Cost | Parameterised SKUs, autoscale bounds, optional NAT gateway. | No ceiling known (D-12). SQL serverless has auto-pause disabled, so minimum compute is billed. |
| Operational excellence | IaC with lint, pipeline with gates, structured validation reports, diagnostics to Log Analytics, alert rules. | No alert routing unless `alertEmailAddresses` is set. |
| Performance | Always On, HTTP/2, autoscale on CPU, stateless (cookies protected by shared key ring; ARR affinity off). | Load/performance testing not performed. |

## Assumptions and dependencies

- **Trusted proxy range.** The app refuses wildcard proxy trust and needs an explicit CIDR. App Service for Linux forwards from
  the platform front end over a link-local address, commonly in `169.254.0.0/16`, but this is **unverified here**. Confirm the
  real peer address after the first deployment (check `X-Forwarded-*` handling in logs); wrong values show as redirect loops
  or an HTTP redirect target. Do not replace it with a wildcard.
- **Key Vault references over a private endpoint** need VNet integration with `routeAllOutboundThroughVnet = true` and the
  private DNS resolution through approved VNet links or platform forwarding. If references show `AccessToKeyVaultDenied`, check DNS, routing and the identity's
  `Key Vault Secrets User` assignment before anything else.
- **Default outbound.** With route-all enabled, public dependencies (Entra sign-in, Application Insights ingestion) leave via the
  NAT gateway. Without it, rely on the owner's platform egress path.
- **Hostname.** The default `<site>.azurewebsites.net` name is assumed (no unique-hostname label). With a custom domain,
  add it to `additionalAllowedHosts` and register its callbacks.
- **Database schema and users** are DBA-owned; the app does not migrate at startup. The schemas used are `CPH` and `Audit`.
- **Source code is unchanged.** Only the Dockerfile base-image patch versions and OCI labels were touched.
- Existing owner Entra app, role (`basicAccessRole`), audit claim and secret lifecycle are inputs, not created here.

## Microsoft guidance

- [App Service VNet integration and subnet sizing](https://learn.microsoft.com/en-us/azure/app-service/overview-vnet-integration)
- [Bicep existing resources](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/existing-resource)
- [Bicep resource-group scopes](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-to-resource-group)
- [Private endpoint DNS integration](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns-integration)
- [Architecture Center Private Link hub/spoke guidance](https://learn.microsoft.com/en-us/azure/architecture/networking/guide/private-link-hub-spoke-network)
- [Well-Architected SE:06 networking](https://learn.microsoft.com/en-us/azure/well-architected/security/networking)
