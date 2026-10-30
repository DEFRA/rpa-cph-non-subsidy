# Developer guide

For developers maintaining the application after its move from .NET Framework on a
Windows VM to .NET 10. This guide describes the checked-in implementation, not a
generic rewrite pattern or proof of production readiness.

Start with the README for [build/test commands](../README.md#build-and-test),
[configuration](../README.md#configuration) and [local running](../README.md#run-locally).
See the [operator guide](./operator-guide.md) for Azure deployment and support.

## What changed

| Area | Current approach | What this means for maintenance |
|---|---|---|
| Hosting | ASP.NET Core/Kestrel in a Linux image; ACA terminates public HTTPS. | Deploy a rebuilt image, not files copied into IIS. Do not rely on Windows services, registry settings or a persistent local filesystem. |
| Startup | `Program.cs` and dependency injection. | Register services centrally; configuration comes from ASP.NET Core providers, not `web.config`. |
| UI | Razor Pages and page handlers, retaining compatible `/Home` routes. | Change page models and `.cshtml` files together; do not add a parallel MVC workflow. |
| Persistence | EF Core with explicit existing-schema mappings. | EF6 lazy loading, graph attachment and automatic validation assumptions do not carry over unchanged. |
| Authentication | Microsoft.Identity.Web, Entra sign-in and an authentication cookie. | Preserve explicit token-role/audit-claim contracts; developer or VM identity is not the signed-in user. |
| Azure access | Explicit user-assigned managed identity (UAMI). | User sign-in and Azure resource permissions are separate. Shared keys and telemetry do not fall back to developer credentials. |
| Testing | Domain tests plus direct handler/configuration, in-process integration and browser tests. | Choose the lowest useful layer; preserve isolation rather than repeating every matrix through HTTP. |

## Where to work

Paths are relative to the repository root:

| Location | Responsibility |
|---|---|
| [Web/Program.cs](../RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web/Program.cs) | Middleware ordering, environment-specific errors, HTTPS redirection and health endpoints. |
| [Web/Services](../RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web/Services/) | Application registration, authentication, forwarding, telemetry, shared keys and readiness checks. |
| [Web/Pages](../RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web/Pages/) | Page handlers, routes, forms, layout and parcel partials. |
| [Web/Helpers/HtmlHelperExtensions.cs](../RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web/Helpers/HtmlHelperExtensions.cs) | Indexed collection-field rendering and index preservation. |
| [Domain/Classes](../RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Domain/Classes/) and [Attributes](../RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Domain/Attributes/) | Entities, business validation, audit formatting and CSV fields. |
| [Domain/Context/CPHContext.cs](../RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Domain/Context/CPHContext.cs) | EF mappings and save-time annotation validation. |
| [Domain/Repository/SQLRepository.cs](../RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Domain/Repository/SQLRepository.cs) | Relationship loading, read tracking and row updates. |
| [Domain/UnitOfWork/UnitOfWork.cs](../RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Domain/UnitOfWork/UnitOfWork.cs) | Shared scoped context and commit. |
| [infra/](../infra/) | Foundation, application activation and deployment prerequisites. |

The `Web/` and `Domain/` labels above abbreviate the project names, not additional
directories. Both projects are inside the solution directory `RPA.CPH.NonSubsidy.Domain`.

## Request and form handling

Forwarded headers run before HTTPS redirection and authentication. Production uses
the anonymous error page; Development exposes exception details. Keep Development
restricted to local use. Health probes bypass redirection, not host filtering.

Razor Page models use `OnGet`/`OnPost`. Customer handler parameters retain the
original flat form names; the model's `Customer` property is output-only.
When editing forms:

- Keep antiforgery protection, validation messages and invalid-post redisplay.
- Preserve `LandParcels.index` tokens. Filtering blank/new rows must not move an
  error or posted value onto a different parcel.
- Keep authorization on list, customer, parcel and export pages. Anonymous access
  is deliberate only for the existing account/error responses and probes.
- Do not trust posted audit values. A successful save stamps the authenticated
  audit identity; invalid saves must not stamp or commit.
- Retain the active-parcel POB rule and exact duplicate check unless a business
  change is explicitly approved. Deleting a record does not require valid edit fields.

The README lists compatible routes and the intentional 404, paging-validation,
search-preservation and CSV-escaping behavior.

## EF Core: important differences from EF6

**The database schema is an external contract.** Existing table/column mappings,
shared keys, five cascade relationships, non-unique SBI and SQL `datetime` audit
storage are intentional. Historical EF6 migrations are excluded from execution;
they are not an EF Core migration baseline. Neither startup nor deployment creates
the application schema or database users. Coordinate schema changes with the DBA.

- **No lazy loading:** repository queries explicitly include relationships needed
  by editing, lists and CSV. Collection graphs use split queries. Avoid removing
  includes just because a test's object graph happens to be populated.
- **Read tracking:** read-only collection queries use no tracking with identity
  resolution. Updates must deliberately locate/copy into tracked rows.
- **Detached updates:** copy scalar values into the existing row. Replacing this
  with blanket `Update`/`Attach` on a posted graph can insert skipped inactive
  parcels or modify unintended related rows.
- **Validation:** EF Core does not automatically reproduce EF6 annotation
  validation on save. `CPHContext` validates added/modified entities for both
  synchronous and asynchronous saves; keep both paths covered.
- **Boolean defaults:** a new CLR parcel defaults to active, while the database
  default is inactive. `ValueGeneratedNever()` ensures EF sends explicit true/false.
- **Commit:** repositories stage changes on one scoped context; `Commit()` calls
  `SaveChanges()`. Do not introduce partial commits between customer and audit work.
  There is no new optimistic-concurrency or retry policy.

The provider uses its normal SQL Server compatibility settings. Do not reintroduce
machine-specific compatibility overrides. Test translation and execution against
the actual supported SQL Server/Azure SQL version when changing queries.

## Authentication and configuration changes

`AddCphApplication` is the registration entry point. Startup checks required values
and SQL connection-string syntax; it does not prove connectivity, identity grants
or deployment security. The app does not load a private `.env` file by itself.
Files mounted under `/run/secrets` take precedence over matching environment values.

Preserve these authentication contracts:

- Sign-in is authorization code with PKCE; there is no downstream API token cache.
- Raw `tid` and `roles` claims are used. Both OIDC options and the replacement
  token handler disable inbound claim mapping; changing only one is insufficient.
- The configured tenant and unique audit-name claim are checked during sign-in.
  Authorization requires the exact configured app-role value.
- Cookies are HTTPS-only with 30-minute sliding expiry. Activity does not perform
  a fresh Entra role lookup. Sign-out is an antiforgery-protected POST.
- Entra client-secret authentication remains required for this web application.
  Managed identity authenticates Azure resource access; it does not replace the
  web application's Entra registration/credential.

Changing the audit claim or normalization can change who appears to have edited a
record. Validate historical name continuity and collisions with the identity owner.

### App roles and claims: how the code uses them

**Authentication** establishes who signed in. **Authorization** decides whether
that user can use the business pages. A **claim** is a named value supplied by
Entra in a validated token; it is not a trusted value posted by the browser.
App roles are application-specific permissions, not Azure RBAC roles such as
`Contributor` or `AcrPull`.

The app has one configured business-access role, covering list, edit, delete,
parcel and export pages. It does not currently have separate reader/writer roles.
For example, an identity owner could define:

| Concept | Illustrative value | Used by |
|---|---|---|
| Entra role display name | `CPH Basic Access` | Administrators selecting assignments. |
| Entra role **value** | `CPH.BasicAccess` | Token `roles` claim and `Authorization__BasicAccessRole`. |
| Role definition ID | Entra role GUID | Entra assignment metadata, not this app's role configuration. |
| ASP.NET policy name | `CPH Non Subsidy: Basic Access` | Code's `ApplicationServices.BasicAccessPolicy`, not the token role value. |
| Audit claim type | `preferred_username` | `Identity__AuditNameClaimType`, only if approved for audit attribution. |

These are examples, not production defaults. `preferred_username` can change and
need not match the legacy account name; it must not be used to grant access.
The [operator setup procedure](./operator-guide.md#entra-setup-app-roles-and-audit-claims)
explains role definition, assignments and audit-claim selection.

An illustrative ID-token payload excerpt would be:

```json
{
  "tid": "<configured-tenant-guid>",
  "roles": ["CPH.BasicAccess"],
  "preferred_username": "Operator@example.invalid"
}
```

This is not a usable token. With example configuration
`Authorization__BasicAccessRole=CPH.BasicAccess` and
`Identity__AuditNameClaimType=preferred_username`, the code proceeds as follows:

1. Microsoft.Identity.Web/OIDC validates the token's signature, issuer, audience
   and lifetime. `OnTokenValidated` in
   [ApplicationServices.cs](../RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web/Services/ApplicationServices.cs)
   then requires exactly one `tid` matching the configured tenant and validates
   the configured audit claim. Missing, duplicate or blank audit claims fail sign-in.
2. Both claim-mapping switches remain disabled, so the code sees raw claim types
   such as `tid`, `roles` and `preferred_username`, not mapped URI claim names.
   `RoleClaimType = "roles"` tells ASP.NET Core where role membership lives;
   `NameClaimType` selects the configured audit claim.
3. The Basic Access policy uses `RequireAuthenticatedUser().RequireRole(role)`.
   Protected page models use
   `[Authorize(Policy = ApplicationServices.BasicAccessPolicy)]`. One exact matching
   role is sufficient even if the user has other roles. Case differences, a
   display name, group name or role GUID do not satisfy the configured value.
4. The resulting principal is stored in the protected authentication cookie.
   Subsequent requests authorize against those claims, without calling Graph or
   looking up group membership. An authenticated user without the role is sent
   to `/Account/AccessDenied`, which returns 403; missing roles do not themselves
   trigger the audit/tenant sign-in rejection.
5. On save, [User.Name](../RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web/Models/User.cs)
   calls [AuditIdentity.GetName](../RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web/Services/AuditIdentity.cs).
   It independently validates the configured claim and normalizes its value.
   The example stores `operator@example.invalid` as the audit actor, not a legacy
   account ID. For an approved claim containing `EARTH\M01234`, the result would
   instead be `m1234`; normalization does not perform directory-account mapping.

Do not replace the audit lookup with a fallback to `Identity.Name`, email or a
posted field. Do not authorize using an audit-name claim. To introduce read-only
or administrative access, define and enforce additional policies/handler checks
and test them; adding a role in Entra alone does not add application behavior.

When changing claims or roles, retain coverage for a permitted role, denied/missing
role, foreign tenant, missing/duplicate audit claim and saved audit actor. New
assignments require a fresh application sign-in to update cookie claims; sliding
renewal is not a directory-role refresh or immediate revocation mechanism.

## Tests and verification boundaries

| Tests | Purpose |
|---|---|
| [Domain.Tests](../RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Domain.Tests/) | NUnit domain/validation rules and offline SQL-provider mapping/translation checks. |
| [Web.Tests](../RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web.Tests/) | MSTest handler/configuration checks, real middleware/token/SDK wiring and SQLite persistence. |
| `Browser` category | Real installed Edge/Chrome against the offline page host, including dynamic parcel editing. |

`Unit` and `Integration` categories work across both projects. Mixed fixtures
categorize individual tests. Reuse existing hosts and the independently authored
SQLite schema. Keep network rejection guards and telemetry background-module
disabling in test hosts; tests must not start contacting Azure or Entra.

SQLite and signed offline tokens do not prove Azure SQL behavior or a complete
live Entra authorization-code exchange. Release acceptance still needs the target
database, deployed image, actual proxy path and real identity configuration.

## Compatibility cautions

- Postcode/grid-reference regex quirks, case-sensitive untrimmed duplicate checks
  and the audit display's 12-hour clock without AM/PM remain. Characterization
  tests describe existing behavior; they are not approval of a new business rule.
- Audit writes use process-local `DateTime.Now`. Confirm container timezone against
  the old VM; do not silently reinterpret historical timestamps.
- CSV uses current culture and platform newlines. Validate Linux output with
  downstream consumers rather than assuming byte-for-byte Windows output.
- Linux paths are case-sensitive. Check static assets and certificate mounts in
  the built image, not just during a Windows `dotnet run`.
- Shared-key tests are offline, not proof of Azure Blob/Key Vault connectivity.
  Application Insights defaults are not a guarantee of sensitive-data removal.

Before handing over a change, run the relevant category/tests, update affected
configuration or deployment documentation, and perform the operator acceptance
checks when the change affects authentication, persistence or hosting.
