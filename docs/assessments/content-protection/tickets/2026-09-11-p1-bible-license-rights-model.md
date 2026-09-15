# Establish a Bible/resource license and rights model

**Date:** 2026-09-11
**Repos affected:** `fluent-api`
**Parent:** [Licensed Content Protection Assessment §3 "High: No license-rights model"](../2026-09-02-licensed-content-protection-assessment.md#3-principal-gaps), [remediation plan](../plan.md)
**Priority:** P1

## Problem

The `bibles` table stores provider and external identity but nothing about
what the license actually permits — no license ID/category, copyright
statement, attribution requirement, offline-storage permission,
derivative-use permission, distribution/quotation limits, validity dates,
or revocation status (`fluent-api/src/db/schema.ts:214-237`). `bible_texts`
stores only Bible/book/chapter/verse/text
(`fluent-api/src/db/schema.ts:345-375`).

DBL's API response types already contain copyright fields; ingestion
discards them (`fluent-api/src/workers/ingest-bible-text.worker.ts:87-147`).
Catalog sync currently trusts that `getBibles()` returns an appropriately
licensed catalog for the configured key rather than inspecting a license
field per Bible (`fluent-api/src/domains/bibles/sync/dbl-bible-sync.ts:19-30`).

Without this model, every other enforcement point in this plan (the P0/P1
endpoint tickets, offline protection, export controls) has no data to make
a real per-Bible decision — they can only do "authenticated and
project-linked," not "this specific Bible/resource permits offline storage"
or "this license has expired."

## Proposal

Add rights/license metadata, per the assessment's Priority 1 field list:

- `licenseId` and license category
- Copyright statement and attribution text
- Provider/source
- `allowOnlineDisplay`
- `allowOfflineStorage`
- `allowAudio`
- `allowDerivativeWork`
- `allowExport`
- Maximum offline scope or quotation size (if the license imposes one)
- Rights start/end dates
- Revocation state
- Provider terms/version

**Before finalizing the schema**, confirm this field list against the
actual API.Bible/DBL and Aquifer provider agreements — the assessment is
explicit that it's a technical review, not a legal determination of what
any specific license grants. Loop in whoever holds the provider agreements
before the migration is written.

Evaluate these rules at every point content moves, not only in the UI:

- Ingestion (should a Bible/book even be pulled in, or flagged, based on its
  license fields at DBL sync time — see
  [the provider-compliance ticket](2026-09-11-p1-provider-compliance-dbl-fums-aquifer.md)
  for the ingestion-side work that consumes this model)
- API delivery (do the P0/P1 endpoint tickets' entitlement checks also
  check `allowOnlineDisplay` / revocation / expiry, not just project
  linkage)
- Offline download (does `allowOfflineStorage` gate whether mobile sync is
  even allowed to fetch a given Bible — feeds into
  [the offline-protection ticket](2026-09-11-p1-protect-offline-content-mobile.md))
- Export (does `allowExport` gate USFM or other export paths)

## Scope

- `fluent-api/src/db/schema.ts:214-237` (`bibles` table — add license
  columns)
- New migration
- `fluent-api/src/domains/bibles/sync/dbl-bible-sync.ts` (populate license
  fields from DBL catalog metadata at sync time, don't just trust the key's
  scope)
- Any admin/internal tooling that lists or edits Bible catalog entries,
  updated to surface the new fields

## Testing / verification strategy

- Migration applies cleanly against a representative existing dataset with
  no license data (all-null / documented-default state for pre-existing
  rows — decide the default explicitly, don't leave it implicit).
- Sync test: a fixture DBL response with copyright/license fields populates
  the new columns correctly.
- This ticket alone has no user-facing behavior change — it's the data
  model other tickets consume. Don't wire enforcement here; that belongs in
  the tickets that reference it above, so this lands independently and
  small.
