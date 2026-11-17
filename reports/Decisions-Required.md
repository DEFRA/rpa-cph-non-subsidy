# Decisions Required — rpa-cph-non-subsidy (Azure App Service hosting)

> Major architecture decisions belong to the owner, not the agent (see `.github/skills/decision-hardstop.md`).
> This file was created during Phase 3 because the Discovery/Plan artifacts for this app do not exist (waiver logged in `Decision-Log.md`).

**Generated:** 2026-11-17 by Phase 3 — Generate Infra
**Decision Log:** `Decision-Log.md` (immutable history)
**Baseline evidence:** `reports/rpa-cph-non-subsidy.md`, `docs/`, existing `infra/` (Container Apps option)

## Status summary

| ID | Decision | Status | Required for |
|----|----------|--------|--------------|
| D-06 | Hosting platform | ✅ DECIDED 2026-11-17 — Azure App Service (Linux container) | Phase 3 |
| D-07 | IaC tool | ✅ DECIDED 2026-11-17 — Bicep | Phase 3 |
| D-08 | Region & data residency | ⏸ PENDING — left blank by the owner | Phase 3 values, **blocks Phase 4** |
| D-10 | Multi-tenancy approach | 🚫 N/A — single-tenant internal portal; no tenant partitioning in code or data model | Phase 3 |
| D-12 | Cost ceiling | ⏸ PENDING — left blank by the owner | Phase 3 sizing, **blocks Phase 4** |
| D-13 | DR — RPO / RTO | ⏸ PENDING — left blank by the owner; templates deploy a single region with no DR topology | Phase 3 sizing, **blocks Phase 4** |
| D-16 | CI/CD platform | ✅ DECIDED 2026-11-17 — Azure DevOps Pipelines (form default accepted) | Phase 3 |
| D-18 | Container registry | ✅ DECIDED 2026-11-17 — Azure Container Registry | Phase 3 |

---

## D-08: Region & data residency
**Status:** ⏸ PENDING
`location` is a required parameter with no default in `infra/appservice/main.bicep` and `webapp.bicep`. Supply an
approved region (and residency constraints) before any what-if or deployment. Zone redundancy, SKU availability and
quota depend on it.

## D-12: Cost ceiling
**Status:** ⏸ PENDING
Plan SKU, instance counts, autoscale maximum, SQL vCores, NAT gateway and ACR SKU are required parameters with no
defaults. No monthly ceiling is assumed and no cost estimate is claimed.

## D-13: DR — RPO / RTO
**Status:** ⏸ PENDING
No recovery target was supplied. The templates create one region, one SQL database and one key-ring account; backup
redundancy and zone redundancy are explicit parameters. Geo-replication, a secondary region and customer-managed
failover are **not** included.

## D-10: Multi-tenancy approach
**Status:** 🚫 N/A — the application has a single Entra tenant (`AzureAd:TenantId`) and no per-tenant data partitioning.
