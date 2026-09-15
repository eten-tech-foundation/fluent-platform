# Licensed content protection — remediation plan

**Date:** 2026-09-11
**Source:** [2026-09-02-licensed-content-protection-assessment.md](2026-09-02-licensed-content-protection-assessment.md)
**Repos affected:** `fluent-api`, `fluent-mobile` (some tickets also touch `fluent-web` where attribution needs to render)

## Why this plan exists

The assessment found copyrighted source Bible text is "readily extractable,
both from the API and from a device with filesystem access." The weakest
point is a single anonymous, unscoped endpoint; the rest of the gaps compound
it (no license model, no offline protection, an embedded provider key). This
plan turns the assessment's Section 4 recommendations into sequenced,
assignable tickets.

## Sequencing

Work is grouped into three waves. Later waves depend on data model or
endpoint changes earlier waves introduce — don't start a later-wave ticket
before its dependency lands, or it will need rework.

### Wave 1 — stop the active leak (do first, independently of everything else)

1. [P0 — Close the anonymous Bible-text endpoint](tickets/2026-09-11-p0-close-anonymous-bible-text-endpoint.md)
2. [P1 — Scope the authenticated single-chapter/audio endpoints](tickets/2026-09-11-p1-scope-authenticated-bible-endpoints.md)

These two close every network path that currently returns source Scripture
without a project/assignment check. They don't depend on any other ticket
here — the entitlement check they add is "does this user have an assignment
that covers this Bible/book/chapter," which is derivable from data that
already exists (`chapter_assignments`, `projects`). Do these before the
license-model work below: closing the leak doesn't need to wait on knowing
*why* a given Bible is restricted, only *whether* the requester is entitled
to it at all.

### Wave 2 — data model + compliance (parallelizable once Wave 1 lands)

3. [P1 — Bible/resource license and rights model](tickets/2026-09-11-p1-bible-license-rights-model.md)
4. [P1 — Provider compliance: DBL copyright, FUMS, Aquifer licenseInfo, attribution](tickets/2026-09-11-p1-provider-compliance-dbl-fums-aquifer.md)
5. [P1 — Protect offline content on mobile](tickets/2026-09-11-p1-protect-offline-content-mobile.md)
6. [P1 — Remove the Aquifer provider key from the mobile app](tickets/2026-09-11-p1-remove-provider-keys-from-mobile.md)

Ticket 3 (the license model) should land before ticket 4 starts consuming
license fields in delivery decisions, but ticket 4's "preserve DBL copyright
fields at ingestion" and "preserve Aquifer licenseInfo" tasks have no
dependency on ticket 3 and can start immediately. Tickets 5 and 6 are
independent of 3 and 4 and of each other — different files, different
concerns (device-side encryption vs. removing an embedded key).

### Wave 3 — defense in depth (after Wave 1 and 2 land)

7. [P2 — Platform capture/extraction hardening](tickets/2026-09-11-p2-platform-capture-hardening.md)
8. [P2 — Content access accountability (audit + anomaly detection)](tickets/2026-09-11-p2-content-access-accountability.md)

These add friction and observability on top of an already-authorized,
already-licensed system. Building them before Wave 1/2 land would mean
auditing and hardening access paths that are about to be redesigned.

## Cross-cutting constraints

- **No public/internal API split.** All entitlement/authorization work in
  this plan happens inside the existing single API surface, using the
  existing `authenticateUser` + `requirePermission` middleware pipeline —
  not a second "public" tier. See the architecture note in
  `fluent-platform/docs/features/` (`fluent-no-public-internal-api-split`
  constraint) if a ticket's implementer is tempted to special-case the
  mobile bulk-sync path as a separate unauthenticated surface.
- **This is a technical remediation plan, not a legal determination.** Ticket
  3 in particular (the license model's field list) should be confirmed
  against actual API.Bible/DBL and Aquifer provider agreements before the
  schema is finalized — the assessment explicitly says it isn't making that
  legal call.
- Every ticket below that changes an API route must add negative tests
  (anonymous, cross-user, cross-project, unrelated-Bible/resource) per the
  assessment's Priority 0 recommendation #8 — not just happy-path coverage.

## Tracking

File one GitHub issue per ticket in its target repo(s), linking back to the
ticket file and this plan. Update the "Overall current-state rating" table
in the assessment (Section 5) once each wave lands, so the rating reflects
implemented state rather than going stale next to the recommendations it
graded.
