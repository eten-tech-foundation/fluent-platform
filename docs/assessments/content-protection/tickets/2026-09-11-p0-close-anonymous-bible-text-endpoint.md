# Close the anonymous bulk Bible-text endpoint

**Date:** 2026-09-11
**Repos affected:** `fluent-api`, `fluent-mobile`
**Parent:** [Licensed Content Protection Assessment §3 "Critical: Anonymous bulk Bible-text access"](../2026-09-02-licensed-content-protection-assessment.md#3-principal-gaps), [remediation plan](../plan.md)
**Priority:** P0 — blocking, treat as an active leak

## Problem

`fluent-api`'s bulk Bible-text endpoint is intentionally anonymous, accepts
up to 1,200 requested chapters per call, and has no user, project,
assignment, or license check at all — only a process-local IP rate limiter
(20 req/min/IP by default, in-memory, so it doesn't hold across API
instances and resets on IP change).

Evidence:
- Anonymous route: `fluent-api/src/domains/bibles/bible-texts/bible-texts.route.ts:97-110`, `:158-168`
- 1,200-chapter cap: `fluent-api/src/domains/bibles/bible-texts/bible-texts.types.ts:14-24`
- Rate limiter: `fluent-api/src/middlewares/rate-limit.ts:68-114`
- Mobile calls it via `publicRequest`: `fluent-mobile/src/services/api.ts:166-174`
- Mobile derives the chapter list from local assignments, but that's client
  behavior only — nothing server-side enforces it
  (`fluent-mobile/src/db/repository.ts:571-599`)

A custom client can call this endpoint directly and pull arbitrary Bible
text with no credentials at all. This is the single largest gap in the
assessment and should close before any of the license-model or offline-
protection work, since none of that matters if the text can be pulled
unauthenticated regardless.

## Proposal

Per the assessment's Priority 0 recommendation, in order:

1. Require `authenticateUser` on the route (reuse the existing middleware
   already used by `fluent-api/src/domains/bibles/bible-texts/bible-texts.route.ts:52-95`,
   the single-chapter endpoint — don't invent a second auth mechanism).
2. Change the request shape from "arbitrary Bible ID + chapter list" to
   project- or assignment-based: the client sends a project/assignment
   reference, not a raw chapter enumeration.
3. Server computes the allowed chapter set from the authenticated user's
   own `chapter_assignments` rows — do not trust a client-submitted chapter
   list at all, even a shorter one.
4. Require that the resolved Bible/book is actually linked to the
   requesting project (same shape as the source-audio entitlement check at
   `fluent-api/src/domains/source-audio/source-audio.repository.ts:10-34` —
   that route is the assessment's suggested model to copy).
5. Update `fluent-mobile/src/services/api.ts:166-174` from `publicRequest`
   to `authedRequest`.
6. Keep the IP rate limiter as secondary abuse protection once auth is in
   place, but note its current limitations (in-memory, per-process, IP-based)
   — a shared store (Redis) or gateway-level limiting is the real fix if
   scraping-by-authenticated-account becomes a concern later. Not required
   to close this ticket, but call it out in the PR description as a known
   follow-up.
7. Add `Cache-Control: no-store` explicitly on this endpoint's responses.
   The global anti-cache middleware in `fluent-api/src/server/server.ts:203-213`
   only applies to `GET`, and this is a `POST` — don't assume it's covered.
8. Add negative tests: anonymous request → 401; authenticated but no
   assignment for the requested chapter → chapter omitted or 403 (pick one
   behavior and test it, see Testing below); assignment belongs to a
   different user → not returned; Bible/book not linked to the project →
   not returned.

## Design decision needed before implementation: error vs. filter

When a client asks for chapters the user isn't entitled to (mixed in with
chapters they are entitled to), decide once and document it:

- **Filter silently** — return only the entitled subset. Simpler for mobile
  (matches "derive from local assignments" already being the intended
  behavior), but can mask a client bug where the requested set drifted from
  the real assignment set.
- **Reject the whole request (403)** if any requested chapter isn't covered
  by an assignment. Surfaces client bugs immediately, but requires mobile's
  sync logic to never send a stale/over-broad chapter list.

Recommendation: filter silently for the assignment-derived bulk-sync path
(that's its whole purpose — this mirrors how the source-audio route already
scopes to what's linked), but log a warning server-side when the filtered
set is non-empty and smaller than requested, so drift is observable without
breaking sync.

## Scope

- `fluent-api/src/domains/bibles/bible-texts/bible-texts.route.ts`
- `fluent-api/src/domains/bibles/bible-texts/bible-texts.types.ts` (request
  shape change)
- `fluent-api/src/domains/bibles/bible-texts/bible-texts.repository.ts` (new
  assignment-scoped query, modeled on
  `fluent-api/src/domains/source-audio/source-audio.repository.ts:10-34`)
- `fluent-mobile/src/services/api.ts:166-174`

## Testing / verification strategy

1. Unit/integration tests in `fluent-api` for the route: anonymous → 401;
   authenticated with valid assignment → 200 with expected verses;
   authenticated with assignment for a *different* user's project → chapter
   excluded (or 403, per the decision above); Bible/book not linked to the
   project → excluded; request for >1,200 chapters → existing cap still
   enforced.
2. Existing rate-limiter test suite (14/14 passing per the assessment) must
   stay green — this ticket doesn't remove the limiter, it adds auth in
   front of it.
3. Mobile: verify the sync path still round-trips correctly with
   `authedRequest` against a local `fluent-api` — a stale bearer token
   should surface as a normal 401/re-auth flow, not a silent empty sync.
4. Manually confirm (e.g. via `curl` with no `Authorization` header) that
   the endpoint now returns 401 before merging.
