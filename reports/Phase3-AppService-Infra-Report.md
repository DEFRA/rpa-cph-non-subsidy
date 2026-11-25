# Phase 3 — Infrastructure generation: rpa-cph-non-subsidy on Azure App Service

**Date:** 2026-11-17  **Hosting:** Azure App Service (Linux container)  **IaC:** Bicep  **Registry:** ACR  **CI/CD:** Azure DevOps
**Scope:** repository artifacts and local validation only. Nothing was deployed to Azure and no Azure resource was queried.
**Application source:** unchanged. Only the Dockerfile (base-image patch versions, OCI labels) was edited.

## 1. Deliverables

| Requirement | Deliverable |
|---|---|
| Modular Bicep | [infra/appservice/](../infra/appservice/README.md): `main.bicep` (foundation), `webapp.bicep` (application), 11 modules, example parameter files, [Grant-DatabaseAccess.sql](../infra/appservice/Grant-DatabaseAccess.sql), [Test-AppServiceTemplates.ps1](../infra/appservice/Test-AppServiceTemplates.ps1) |
| Dockerfile | [Dockerfile](../Dockerfile): multi-stage, patched pinned bases, non-root, ICU globalization, port 8080, OCI labels, `NUGET_SOURCE` build arg; [.dockerignore](../.dockerignore) allow-list |
| CI/CD YAML | [azure-pipelines.yml](../azure-pipelines.yml): validate, build/test, push, staging-slot deploy, validate, swap, validate, swap-back rollback |
| ACR build and push | [scripts/Build-PushImage.ps1](../scripts/Build-PushImage.ps1) (Docker or `az acr build`, Trivy gate, version + commit tags, digest output, no `latest`) |
| App Service deployment config | `modules/appService.bicep`: ACR pull by managed identity and digest, VNet integration, Key Vault references, health check, hardening, diagnostics, slot |
| Test scripts and reports | [scripts/Invoke-Tests.ps1](../scripts/Invoke-Tests.ps1), [scripts/Test-Deployment.ps1](../scripts/Test-Deployment.ps1), [reports/test-results/](./test-results) |
| Decisions | [Decisions-Required.md](./Decisions-Required.md), [Decision-Log.md](./Decision-Log.md) |

## 2. Validation performed (local) and results

| Check | Result |
|---|---|
| `bicep build` + `bicep lint` on `main.bicep`, `webapp.bicep` (Bicep 0.49.2, AVM restored) | ✅ 0 errors, 0 warnings. One real error (module-output in a loop) found and fixed |
| Parameter-rule self-tests (15 positive/negative cases) and source guard rails (no access policies, keys, ACR admin, shared-key) | ✅ |
| Example parameter files rejected as non-deployable (`null` values) | ✅ by design |
| Pipeline YAML parse, PowerShell script parse | ✅ |
| Docker build of the real Dockerfile | ✅ (restore step substituted, see Issue 1) |
| Container run with App Service-style config | ✅ uid 1654 (non-root); `/health/live` 200 `Healthy`; `/health/ready` 503 `Unhealthy` with no detail when SQL is unreachable; unlisted Host rejected 400; HTTP redirects to `https://`; with `X-Forwarded-Proto: https` from a trusted CIDR the request passes HTTPS redirection |
| Image scan (Trivy, HIGH/CRITICAL, fixable) | ❌ first run: 3 ASP.NET Core runtime CVEs in 10.0.14 + `apt` → ✅ after bumping to `aspnet:10.0.15-noble` / `sdk:10.0.404-noble`: 0 findings. Image 469 MB |
| Tests (Release): Unit 169, Integration 144, Browser (Playwright) 1 | ✅ 314 / 314 passed (Domain 47 + Web 267) |
| `Test-Deployment.ps1` against an unreachable host | ✅ fails cleanly, writes JSON and Markdown report. **Never run against a live site** |

### Test coverage by requested type

| Type | Covered by | Gap |
|---|---|---|
| Unit | Domain (NUnit) and Web (MSTest) `Unit` tests: validation, config, forwarding, telemetry, data protection | none found |
| Integration | In-memory host, SQLite relational persistence, stub OIDC provider, Razor Pages workflows | SQL Server provider behaviour is not exercised on this setup (tests use SQLite and mocks) |
| API / endpoint | Health, auth challenge, page-route tests; `Test-Deployment.ps1` on a live origin | live run pending |
| Connectivity | `/health/ready` (SQL via private endpoint), Key Vault reference status, Entra redirect checks in `Test-Deployment.ps1` | live run pending; Blob/Key Vault key access is proven only by app startup and sign-in |
| End to end | Playwright browser workflow (1 scenario) | authenticated flow against real Entra is manual |

## 3. Issues, gaps and remediation

| # | Finding | Impact | Remediation |
|---|---|---|---|
| 1 | nuget.org TLS handshake fails from this machine, so `docker build` cannot restore inside the container (host and container both) | Could not run the unmodified Dockerfile here; build stage validated with an offline feed instead | Build in the pipeline/network with NuGet access, or pass `NUGET_SOURCE` for an internal feed. Not a Dockerfile defect |
| 2 | Same TLS issue blocks fetching the Entra OIDC discovery document (IDX20809), so the anonymous challenge returned 500 in the local container | Live sign-in flow not exercised locally | Covered by repo stub-IdP tests; re-check with `Test-Deployment.ps1` after deployment |
| 3 | **Fixed:** vulnerable runtime 10.0.14 in the image | HIGH CVEs (privilege escalation, DoS) | Bumped bases to 10.0.15 / SDK 10.0.404, rescanned clean. Keep Trivy as a push gate |
| 4 | D-08 region, D-12 cost ceiling, D-13 RPO/RTO unanswered | Templates have no sizing; cannot be deployed or costed | Owner supplies decisions, then run what-if. **Phase 4 stays blocked** |
| 5 | Trusted proxy CIDR for App Service (`169.254.0.0/16`) is an assumption | Wrong value causes redirect loops or wrong client IP/scheme | Verify on first deployment; the template takes it as a required input |
| 6 | Existing `infra/app.parameters.json` / `main.parameters.json` contain tenant, client and admin identifiers and a named user's UPN | Information disclosure risk if the repo is shared | Not changed (outside scope). Move to private storage and rotate if the repository is shared |
| 7 | ACR and the web site are public | Larger attack surface | Premium ACR with private endpoint and self-hosted agents; Front Door/WAF or access restrictions |
| 8 | Shared Entra client secret in Key Vault, no rotation automation | Operational risk | Set an expiry and rotation owner; reference is versionless so rotation needs no redeploy |
| 9 | `az bicep` is broken locally (corrupted extension cache, access denied) | none; standalone Bicep CLI used | Fix the extension cache or use the standalone CLI |
| 10 | Pipeline never run against a real Azure DevOps organisation | Unknown service-connection or permission gaps | Dry-run in a non-production project first |
| 11 | Slot swap does not roll back schema or data | Rollback limited to the image | DBA-owned rollback; keep migrations backward compatible |

## 4. Deployment validation checklist

**Before deployment**
- [ ] D-08, D-12, D-13 decided and recorded; parameter files completed outside Git
- [ ] `Test-AppServiceTemplates.ps1` passes with the real parameter files
- [ ] `az deployment group what-if` reviewed (region support, quota, policy, SKU, zone redundancy)
- [ ] Service connections `acr-push` and `app-deploy` created with least privilege; variable group and secure files uploaded
- [ ] Entra app: callbacks `signInCallback`/`signOutCallback` registered, app role and audit claim confirmed, client secret stored in Key Vault

**Foundation and bootstrap**
- [ ] Private DNS resolves SQL, Key Vault and Blob to private IPs from the integration subnet
- [ ] Wrapping key created and rotation policy applied (`Initialize-DataProtectionKey.ps1`)
- [ ] DBA applied schema and ran `Grant-DatabaseAccess.sql` for the runtime identity
- [ ] Image pushed; digest recorded; Trivy gate green

**After deployment (run `Test-Deployment.ps1` for the staging slot, then production)**
- [ ] Liveness 200, readiness 200 (SQL reachable)
- [ ] HTTP redirects to HTTPS, TLS 1.2+, HSTS present, unlisted Host rejected
- [ ] Anonymous request challenged to the correct tenant with the registered `redirect_uri`
- [ ] Key Vault references all `Resolved`; app pulls by digest with managed identity; FTPS disabled; SCM basic auth off
- [ ] Manual: sign in with a user holding the app role, create/edit a land parcel, check audit record, sign out
- [ ] Manual: cookies survive a slot swap and an instance restart (shared key ring)
- [ ] Application Insights receives requests; Log Analytics has console and HTTP logs; alerts route to a real recipient
- [ ] Rollback rehearsed (swap back) before go-live

## 5. Next steps

1. Owner decides D-08, D-12, D-13 (see [Decisions-Required.md](./Decisions-Required.md)).
2. Dry-run the pipeline in a non-production project and run what-if with real parameters.
3. Then `/Phase4-DeployToAzure`. It remains gated on the pending decisions above.
