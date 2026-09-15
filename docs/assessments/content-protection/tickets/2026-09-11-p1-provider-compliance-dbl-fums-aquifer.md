# Implement provider compliance: DBL copyright, FUMS reporting, Aquifer licenseInfo, attribution display

**Date:** 2026-09-11
**Repos affected:** `fluent-api`, `fluent-mobile`, `fluent-web` (attribution rendering only)
**Parent:** [Licensed Content Protection Assessment §3 "High: API.Bible FUMS/fair-use support is unfinished" and "Medium: Attribution is incomplete"](../2026-09-02-licensed-content-protection-assessment.md#3-principal-gaps), [remediation plan](../plan.md)
**Priority:** P1

## Problem

Three related compliance gaps:

1. **FUMS not surfaced.** The DBL client accepts FUMS (fair-use metadata
   service) metadata but doesn't do anything with it; a future ticket was
   already flagged in-code for reporting
   (`fluent-api/src/lib/services/dbl/dbl.client.ts:125-130`). If FUMS
   reporting or copyright display is part of the API.Bible agreement, the
   app currently can't demonstrate compliance.
2. **Copyright/attribution fields are discarded or unused.**
   - DBL copyright fields are dropped at ingestion
     (`fluent-api/src/workers/ingest-bible-text.worker.ts:87-147`).
   - Aquifer's `licenseInfo` is typed but never consumed
     (search `fluent-mobile/src/services/prepareOfflineResourceManifest.ts`
     and the Aquifer client types).
   - Image UI can render attribution, but current API mapping returns only
     title/URL in several paths.
   - The mobile Bible model has only ID, language, name, abbreviation — no
     copyright/attribution fields at all
     (`fluent-mobile/src/types/api/responses.ts:29-34`).
3. **Terms of Use doesn't mention Scripture copying/redistribution
   restrictions** — it covers AI output only
   (`fluent-mobile/src/app/tabs/TermsOfUsePage.tsx`).

## Proposal

1. **Preserve DBL copyright fields at ingestion.** Update
   `ingest-bible-text.worker.ts` to write copyright/attribution text into
   the license model added by
   [the license-model ticket](2026-09-11-p1-bible-license-rights-model.md)
   instead of discarding it. This task has no dependency on that ticket's
   schema landing first if done as "add the column, then wire the worker"
   in the same PR — coordinate with whoever picks up that ticket if they're
   different people.
2. **Implement FUMS reporting.** Follow through on the in-code TODO at
   `dbl.client.ts:125-130` — surface and report FUMS metadata per
   API.Bible's documented requirement. Confirm the exact reporting contract
   with API.Bible's docs/agreement before implementing (this is a provider
   compliance requirement, not a design choice this repo gets to make
   freely).
3. **Preserve Aquifer `licenseInfo`.** Stop discarding it in the mobile
   manifest/client code; persist or pass it through to wherever attribution
   needs to render.
4. **Display attribution** in Bible/source-text, audio, and image/resource
   interfaces — `fluent-mobile` (source text accordion, audio player,
   resource viewer) and `fluent-web` wherever equivalent content renders.
   Fix the image-attribution API mapping gap so title/URL isn't the only
   data available when a UI wants to show full attribution.
5. **Extend mobile Terms of Use** to state restrictions on copying/
   redistributing licensed Scripture, not just AI-output terms.
6. **Document** which provider/license combinations permit local verse
   storage and derivative translation work — a short reference doc (e.g.
   `fluent-platform/docs/guides/provider-license-terms.md`) that the
   license-model ticket's field values should trace back to.

## Scope

- `fluent-api/src/lib/services/dbl/dbl.client.ts` (FUMS)
- `fluent-api/src/workers/ingest-bible-text.worker.ts` (preserve copyright
  fields)
- `fluent-mobile/src/services/prepareOfflineResourceManifest.ts` and Aquifer
  client types (preserve `licenseInfo`)
- `fluent-mobile/src/types/api/responses.ts:29-34` (add copyright/
  attribution fields to the Bible model)
- `fluent-mobile/src/components/ui/SourceTextAccordion.tsx` and audio/image
  viewer components (render attribution)
- `fluent-mobile/src/app/tabs/TermsOfUsePage.tsx`
- `fluent-web` equivalents wherever it renders the same content types

## Testing / verification strategy

- Ingestion test: fixture DBL response with copyright fields → fields land
  in the license model, not dropped.
- FUMS: verify against API.Bible's documented reporting contract (may
  require a sandbox/test credential — confirm with whoever holds the DBL
  agreement).
- UI: attribution text renders on source-text, audio, and image/resource
  screens where the underlying content has attribution data; verify nothing
  renders (no broken empty state) when attribution data happens to be
  absent for a given item.
- Legal/product sign-off on the updated Terms of Use language before
  release — this is copy that needs review outside engineering.
