# RPA CPH Non Subsidy

Customer and land-parcel management using ASP.NET Core Razor Pages and EF Core on
.NET 10. The application preserves the existing SQL schema and customer workflows.
It can run directly on Windows or as a non-root Linux container.

**Azure deployment and production parity have not been verified.** Deployment
templates are supplied, but no Azure resources have been provisioned.

For maintenance and handover, see the [developer guide](./docs/developer-guide.md)
and [operator guide](./docs/operator-guide.md).

## Build and test

Run from the repository root in PowerShell with the .NET 10 SDK:

```powershell
dotnet restore .\RPA.CPH.NonSubsidy.Domain\RPA.CPH.NonSubsidy.sln
dotnet build .\RPA.CPH.NonSubsidy.Domain\RPA.CPH.NonSubsidy.sln -c Release --no-restore
dotnet test .\RPA.CPH.NonSubsidy.Domain\RPA.CPH.NonSubsidy.sln -c Release --no-build --filter "TestCategory!=Browser"
```

Tests use fake identities, TestServer, SQLite and offline SDK fixtures; they do not
contact Entra, SQL Server or Azure. SQL Express/LocalDB is not required.
Use `--filter "TestCategory=Unit"` or `"TestCategory=Integration"` for focused runs.
These checks do not establish SQL Server collation, precision, concurrency or Azure parity.

The optional browser test requires already-installed Edge or Chrome. It bridges
requests to TestServer and blocks other origins; no browser is downloaded:

```powershell
dotnet test .\RPA.CPH.NonSubsidy.Domain\RPA.CPH.NonSubsidy.Web.Tests -c Release --no-build --filter "TestCategory=Browser"
```

## Configuration

Supply configuration through environment variables (`__` separates sections),
development user secrets or an external launcher. The application does **not** load
`.env` files itself. Optional files mounted at `/run/secrets` override matching
environment values; do not mount obsolete settings there.

| Environment key | Requirement |
|---|---|
| `AllowedHosts` | Required explicit hostnames, separated by semicolons. No wildcards, schemes, paths, ports or whitespace. |
| `AzureAd__Instance` | Entra authority; defaults to `https://login.microsoftonline.com/`. |
| `AzureAd__TenantId` | Required specific tenant GUID, not `common` or `organizations`. |
| `AzureAd__ClientId` | Required web application registration GUID. |
| `AzureAd__ClientSecret` | Required in every environment. Certificate/federated `ClientCredentials` alternatives are not supported by this configuration. |
| `Authorization__BasicAccessRole` | Required exact, case-sensitive Entra app-role **value**, not display name. |
| `Identity__AuditNameClaimType` | Required claim type providing the historical audit name; no fallback. |
| `ConnectionStrings__CPHContext` | Required parseable SQL Server connection string; startup does not test connectivity or enforce authentication/TLS policy. |
| `ReverseProxy__KnownProxies__0` | Approved immediate proxy IP; use subsequent indices for additional IPs. |
| `ReverseProxy__KnownIPNetworks__0` | Approved canonical proxy CIDR; use subsequent indices for additional networks. Never trust all networks. |
| `HttpsRedirection__HttpsPort` | External HTTPS port; defaults to 443. |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Optional telemetry opt-in. Alternative: `ApplicationInsights__ConnectionString`; the former takes precedence. |
| `Telemetry__ManagedIdentityClientId` | Optional explicit nonempty UAMI client GUID for telemetry ingestion; requires its connection string. Required for the ACA configuration below. |
| `DataProtection__Enabled` | `true` enables shared keys; absent/`false` keeps local defaults. Enable for production ACA. |
| `DataProtection__BlobUri` | HTTPS container/blob URI, without SAS, query, credentials or fragment. |
| `DataProtection__KeyIdentifier` | HTTPS versionless Key Vault **key** URI: `/keys/<name>`, not a secret/certificate URL. |
| `DataProtection__ApplicationName` | Nonblank, stable environment-specific name shared by its replicas/revisions. |
| `DataProtection__ManagedIdentityClientId` | Explicit nonempty UAMI client GUID for Blob access and key wrapping. |

When Data Protection is enabled, supply all its settings. Invalid/incomplete
configuration and unknown Data Protection setting names fail startup. URI validation
does not prove that the configured Azure resources exist or are accessible.
Keep credentials, certificates and private configuration outside Git and images.

### Application behavior

- Entra sign-in uses authorization code and PKCE. Configure HTTPS redirect URIs
  `/signin-oidc` and `/signout-callback-oidc`; coordinate `/signout-oidc` if needed.
  Exactly one matching tenant claim and one nonempty audit-name claim are required.
- Authentication cookies are Secure, HttpOnly and SameSite=Lax, with a 30-minute
  sliding lifetime. Requests after half the lifetime can renew them; typing alone
  cannot. There is no absolute session cap or immediate Entra role-revocation check.
  Sign-out requires an antiforgery-protected POST.
- Audit names retain culture-sensitive lowercase (`en-GB`), removal of `earth\`
  and replacement of every `m0` with `m`. Timestamps use local `DateTime.Now`.
  Confirm claim continuity and possible name collisions before release.
- EF mappings, shared keys, cascades, non-unique SBI and parcel `Active` default 0
  are preserved. Saves commit data and audit together; omitted existing parcels
  remain, and new inactive parcels are not inserted. There is no new retry or
  concurrency policy. Startup never creates/migrates the database; a DBA owns
  schema compatibility. Historical EF6 migrations are not an EF Core baseline.

| Route | Behavior |
|---|---|
| `/`, `/Home`, `/Home/Index` | Authorized list/search. Paging defaults to 1/20; invalid or nonpositive values return 400, with no additional page-size cap. Search survives paging. |
| `/Home/Customer?customerId=...`, `/Home/Customer/{id}` | Authorized create/edit and antiforgery-protected save/delete. Missing customers return 404. |
| `/Home/_LandParcel`, `/Home/_NewLandParcel?landId=...` | Authorized indexed parcel partials used by AJAX. |
| `/Home/Extract` | Authorized UTF-8 CSV of active parcels, retaining column order/date culture and escaping embedded quotes. |
| `/Account/SignIn`, `/Account/SignOut` | Entra sign-in and sign-out confirmation. |
| `/Account/SignedOut`, `/Account/AccessDenied`, `/Account/AuthenticationFailed` | Anonymous status responses. |
| `/Error`, `/Error/Index` | Anonymous error page, including failed-POST re-execution. |

Historical validation quirks and existing vendor assets remain unchanged.

## Run locally

### Directly on Windows

Load the required configuration using your private launcher, user secrets or process
environment. For `https://localhost:7143`, set `AllowedHosts=localhost`,
`HttpsRedirection__HttpsPort=7143`, and register the matching Entra callback URIs.
Then run:

```powershell
dotnet dev-certs https --trust
$env:ASPNETCORE_ENVIRONMENT = 'Development'
$env:DOTNET_ENVIRONMENT = 'Development'
dotnet run --project .\RPA.CPH.NonSubsidy.Domain\RPA.CPH.NonSubsidy.Web --no-launch-profile -- --urls https://localhost:7143
```

Entra sign-in, role checks and audit claims still apply locally. LocalDB and SQL
Express both use the same SQL Server provider; choose your own database:

```text
Server=(localdb)\MSSQLLocalDB;Database=<database>;Integrated Security=True;Encrypt=True;TrustServerCertificate=True
Server=.\SQLEXPRESS;Database=<database>;Integrated Security=True;Encrypt=True;TrustServerCertificate=True
```

Certificate trust bypass is only for local self-signed SQL certificates; use
`TrustServerCertificate=False` when the certificate is trusted. Use a SQL release
and database compatibility level supported by EF Core's default SQL Server provider
settings. Startup does not change either. Obsolete `LocalDevelopmentSql` flags
should be removed from local configuration.

### Docker

Use Docker Desktop in Linux-container mode:

```powershell
docker build -t cph-nonsubsidy:local .
# Optional non-secret package source, replacing configured restore sources:
docker build --build-arg NUGET_SOURCE="https://your-feed/v3/index.json" -t cph-nonsubsidy:local .
```

Omitting `NUGET_SOURCE` or passing an empty value preserves normal restore behavior.
Authenticated feeds require separate BuildKit secret setup; never put credentials
in build arguments. Recreate containers after rebuilding the image.

The multi-stage [Dockerfile](./Dockerfile) pins SDK 10.0.403 and ASP.NET runtime
10.0.14 on Ubuntu Noble, includes ICU for `en-GB`, runs as UID 1654 and listens on
HTTP 8080. Only published application files enter the runtime image.

<details>
<summary>Local Docker HTTPS setup (Windows development certificate)</summary>

ACA terminates TLS at ingress. Local authenticated browser testing instead needs
HTTPS in Kestrel; the Windows certificate store is not available inside Linux.
Use your existing trusted ASP.NET Core development certificate, not a new CA.

1. As your normal Windows user, check the certificate with
   `dotnet dev-certs https --check --trust`. If missing/untrusted, run
   `dotnet dev-certs https --trust` and approve the prompt. Do not use `--clean`;
   it can disrupt other apps. Follow corporate policy if trust is blocked.
2. Create a private directory outside the checkout and restrict access to your
   account and necessary administrators/system:

   ```powershell
   $privateDirectory = Join-Path $HOME '.cph-local'
   New-Item -ItemType Directory -Path $privateDirectory -Force
   ```

3. Open `certmgr.msc` > **Current User > Personal > Certificates**. Select the
   valid **localhost ASP.NET Core HTTPS development certificate** with its private
   key. Use **All Tasks > Export**, include the private key, and save a
   password-protected PKCS #12/PFX as `localhost.pfx` in that directory. Use
   AES256-SHA256 if offered; do **not** delete the original private key.
   A public-only `.cer` file will not work.
4. Create `local.env` in the same directory using the required Entra, role and
   audit keys from the configuration table, plus:

   ```text
   ASPNETCORE_ENVIRONMENT=Development
   DOTNET_ENVIRONMENT=Development
   ASPNETCORE_URLS=https://+:8443;http://+:8080
   AllowedHosts=localhost
   HttpsRedirection__HttpsPort=7143
   Kestrel__Certificates__Default__Path=/https/localhost.pfx
   Kestrel__Certificates__Default__Password=<private-pfx-password>
   ConnectionStrings__CPHContext=Server=tcp:host.docker.internal,<tcp-port>;Database=<database>;User ID=<development-login>;Password=<private-sql-password>;Encrypt=Mandatory;TrustServerCertificate=True
   ```

   Docker env files use literal `KEY=value`, without surrounding quotes or shell
   expansion. Edit credentials privately, not in command history. Ask the SQL
   owner for the TCP port and a least-privilege development login. LocalDB and
   Windows integrated authentication are not directly available from this Linux
   container. SQL certificate trust does not affect browser HTTPS trust.
   Leave optional Azure telemetry/shared-key settings unset unless separately
   configured. Docker administrators can inspect environment values.
5. In the same PowerShell session, with both files present and ports/name free:

   ```powershell
   docker run --rm --name cph-local-env --cap-drop=ALL --security-opt=no-new-privileges `
     --env-file "$privateDirectory\local.env" `
     --mount "type=bind,source=$privateDirectory\localhost.pfx,target=/https/localhost.pfx,readonly" `
     --publish 127.0.0.1:7143:8443 --publish 127.0.0.1:5143:8080 cph-nonsubsidy:local
   ```

   Each backtick must be the last character on its line. The PFX must be readable
   by UID 1654. Open `https://localhost:7143`, with no certificate warning.
   Check `/health/live`, `/health/ready`, sign-in, role/audit mapping and sign-out.
   Stop with Ctrl+C; recreate after changing the env file or certificate.
   Never deploy the development PFX to ACA. Remove private credential files through
   your approved cleanup process after testing.

</details>

## Azure deployment requirements

Use the [Bicep deployment guide](./infra/README.md) for foundation and application
activation. The receiving team must supply approved parameters, provision resources
and verify the following before production:

- **Secrets and identity:** ACA resolves Key Vault secret references through its
  configured managed identity, then injects values using `secretRef`. Do not supply
  unresolved vault URLs as application secrets. The app does not fetch Key Vault
  configuration/secrets; Data Protection separately uses the key cryptography SDK.
  Configure secret-access RBAC, network access and rotation/revision refresh.
- **SQL:** grant the runtime UAMI least-privilege database access. Use managed
  identity, encryption and certificate validation, for example:
  `Server=<sql-endpoint>;Database=<database>;Authentication=Active Directory Managed Identity;User Id=<uami-client-guid>;Encrypt=Mandatory;TrustServerCertificate=False`.
  `User Id` is the UAMI client ID, not its object/resource ID. Successful startup
  proves neither connectivity nor compliance.
- **Shared cookie keys:** enable Data Protection, provision the Blob container and
  dedicated Key Vault key, attach the UAMI, and grant Blob read/write plus key
  get/wrap/unwrap permissions. Keep the Blob URI/application name stable across
  replicas and revisions, separate environments, and retain all old wrapping-key
  versions needed for decryption. Access failures have no local/unencrypted fallback.
  Verify cookies across restarts, revisions and replicas.
- **Ingress and hosts:** terminate HTTPS at ACA ingress targeting HTTP 8080. Include
  approved application/custom hostnames in `AllowedHosts`, including the Host used
  by probes; unlisted hosts return 400. Configure Entra callbacks for each origin.
- **Forwarding:** verify the actual immediate ACA proxy IP/subnet before configuring
  trust. Standard middleware consumes one hop of `X-Forwarded-For`/`X-Forwarded-Proto`,
  never forwarded Host; header-count symmetry is disabled for ACA. No trust means forwarding
  is disabled. Do not use guessed subnets, all-network trust or
  `ASPNETCORE_FORWARDEDHEADERS_ENABLED`. Verify external HTTPS redirects/callbacks
  and that untrusted forwarded headers cannot affect redirects.
- **Telemetry:** provide the connection string and explicit ingestion UAMI client
  ID, grant **Monitoring Metrics Publisher** on Application Insights and set
  `disableLocalAuth=true`. Without the identity setting, connection-string-only
  ingestion requires local authentication to be allowed. Verify ingestion/RBAC.
  SDK defaults collect requests, dependencies, exceptions, traces and metrics,
  subject to platform support, filters and sampling. There is no custom redaction;
  review URLs/query strings, exceptions, logs, access and retention for sensitive
  data. Never log credentials, tokens or submitted forms, or enable identity PII.

Keep the deployed environment set to `Production`. Registry access, SQL schema/
network compatibility and real Entra sign-in also require deployment verification.

| Probe | Meaning |
|---|---|
| `/health/live` | Anonymous HTTP 200 `Healthy`; process only. |
| `/health/ready` | Anonymous bounded SQL `SELECT 1`; 200 `Healthy` or 503 `Unhealthy`. |

Probes bypass HTTPS redirection but still require an allowed Host. Readiness does
not verify schema compatibility, user permissions for CRUD or Entra authentication.

## Troubleshooting

| Symptom | Check |
|---|---|
| Local browser certificate warning | Use `localhost`, not an IP; check certificate trust, expiry and the exported certificate. Do not bypass TLS warnings. |
| PFX missing/unreadable or incorrect password | Check the mount path, private-key export, password and UID 1654 read access. Do not switch to root or grant Everyone access. |
| Port/name already in use | Resolve only your own app/container; do not terminate another user's process. |
| HTTP 400 before page handling | Check `AllowedHosts`, probe Host and paging values. |
| Redirect loop or wrong callback scheme | Check ingress TLS, approved proxy trust, forwarding headers and external HTTPS port. |
| Entra redirect mismatch or access denied | Check registered HTTPS callbacks, assigned role value, tenant and configured audit claim. |
| Liveness succeeds but readiness fails | Investigate SQL endpoint/port, identity/login grants, network access and SQL TLS separately. |
