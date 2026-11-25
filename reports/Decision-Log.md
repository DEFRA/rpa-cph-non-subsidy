# Decision Log — rpa-cph-non-subsidy

Immutable history. Newest entries at the bottom.

## 2026-11-17 — Waiver: skip Discovery contract for Phase 3
**Waiver:** skip-discovery=Discovery-Dossier, Capability-Matrix and Migration-Plan do not exist for this app; the owner
asked to use `reports/rpa-cph-non-subsidy.md`, `docs/` and the existing `infra/` as the baseline.
**Decided by:** user via chat (explicit "waive" selected in the Phase 3 form)
**Agent observed evidence:**
- `reports/rpa-cph-non-subsidy.md` (Phase 0 assessment), `docs/developer-guide.md`, `docs/operator-guide.md`
- Application already migrated to .NET 10 Razor Pages with a Dockerfile and Container Apps Bicep
**Locked downstream:** none

## 2026-11-17 — Hosting platform (D-06)
**Choice:** Azure App Service, Linux container
**Rationale (user):** stated in the Phase 3 request ("Azure App Service, App Service Plan, ACR")
**Agent observed evidence:** existing `infra/main.bicep`/`app.bicep` target Azure Container Apps; kept untouched
**Locked downstream:** D-18 (container registry applies)

## 2026-11-17 — IaC tool (D-07)
**Choice:** Bicep (stated in the request: "Bicep Template Generation")
**Decided by:** user via chat

## 2026-11-17 — Container registry (D-18)
**Choice:** Azure Container Registry (stated in the request)
**Decided by:** user via chat

## 2026-11-17 — CI/CD platform (D-16)
**Choice:** Azure DevOps Pipelines (form default accepted; the request allowed "Azure DevOps or GitHub Actions")
**Agent observed evidence:** sibling apps `rpa-mts-inspections` and `people-api` already use `azure-pipelines.yml`
**Decided by:** user via chat (form defaults)

## 2026-11-17 — Region, cost ceiling, RPO/RTO (D-08, D-12, D-13)
**Choice:** none — left blank by the user
**Consequence:** templates take these as required parameters with no defaults; Phase 4 deployment stays blocked until
they are decided. No values were assumed.
