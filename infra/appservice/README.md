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
| 1 Foundation | [main.bicep](./main.bicep) | VNet (integration + private-endpoint subnets, NSGs, optional NAT gateway), user-assigned identity, Log Analytics, Application Insights (Entra-only ingestion), ACR, Key Vault (RBAC), private Blob key-ring storage, Azure SQL (Entra-only), private endpoints and DNS for SQL/Key Vault/Blob, App Service Plan (+ optional autoscale). **No application starts.** |
| 2 Application | [webapp.bicep](./webapp.bicep) | Web app (Linux container pulled from ACR by digest), optional staging slot with sticky `AllowedHosts`, key-scoped crypto role assignment, diagnostics, metric alerts and optional action group. |

Modules live in [modules/](./modules): `networking`, `identity`, `monitoring`, `registry`, `keyVault`, `storage`,
`database`, `privateEndpoint`, `appServicePlan`, `appService`, `alerts`. AVM versions pinned in source are reused from the
Container Apps templates (identity 0.6.0, Log Analytics 0.16.1, Application Insights 0.8.0, ACR 0.13.1, Key Vault 0.14.2,
Storage 0.33.1, SQL 0.22.1). Web, plan, autoscale, NAT, network and alert resources are native Bicep.

## Inputs

Copy [main.parameters.example.json](./main.parameters.example.json) and [webapp.parameters.example.json](./webapp.parameters.example.json)
outside Git. `null` means **unknown**; the checked-in files are intentionally not deployable. Validate with:

```powershell
.\infra\appservice\Test-AppServiceTemplates.ps1 -BicepPath 'C:\tools\bicep.exe' `
  -FoundationParameters 'C:\private\cph\main.json' -ApplicationParameters 'C:\private\cph\webapp.json'
```

Notable owner inputs: `location`; `planSkuName` (staging slot and autoscale need Standard or Premium, zone redundancy needs
Premium v3 with two or more instances); `integrationSubnetCidr` (/26 recommended, /28 minimum); `pipelinePrincipalObjectId`
(AcrPush for the pipeline; empty = none); `trustedProxyCidr` (see Assumptions); `routeAllOutboundThroughVnet`
(required for Key Vault references that resolve over a private endpoint; pair with `enableNatGateway`).

## Deployment sequence (receiving-team commands, not run here)

1. **Foundation**: `az deployment group what-if` then `create` with `main.bicep`. Read the outputs.
2. **Owner bootstrap** (private-network host): DNS resolves SQL/Key Vault/Blob to private IPs; create the wrapping key with
   [`../Initialize-DataProtectionKey.ps1`](../Initialize-DataProtectionKey.ps1) using the `dataProtectionKeyBootstrap` output;
   put the Entra client secret in Key Vault; register `signInCallback`/`signOutCallback` in the Entra app; the DBA runs
   [Grant-DatabaseAccess.sql](./Grant-DatabaseAccess.sql) and applies the approved schema.
3. **Image**: [`../../scripts/Build-PushImage.ps1`](../../scripts/Build-PushImage.ps1) (or the pipeline) pushes
   `:<version>` and `:sha-<commit>` and records the immutable digest. `latest` is never used.
4. **Application**: `webapp.bicep` with the digests. First deployment uses the same digest for production and staging.
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
  private DNS zones linked to the VNet. If references show `AccessToKeyVaultDenied`, check DNS, routing and the identity's
  `Key Vault Secrets User` assignment before anything else.
- **Default outbound.** With route-all enabled, public dependencies (Entra sign-in, Application Insights ingestion) leave via the
  NAT gateway. Without it, rely on the owner's platform egress path.
- **Hostname.** The default `<site>.azurewebsites.net` name is assumed (no unique-hostname label). With a custom domain,
  add it to `additionalAllowedHosts` and register its callbacks.
- **Database schema and users** are DBA-owned; the app does not migrate at startup. The schemas used are `CPH` and `Audit`.
- **Source code is unchanged.** Only the Dockerfile base-image patch versions and OCI labels were touched.
- Existing owner Entra app, role (`basicAccessRole`), audit claim and secret lifecycle are inputs, not created here.
