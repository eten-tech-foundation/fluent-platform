# Scope the authenticated single-chapter text and legacy audio endpoints to project membership

**Date:** 2026-09-11
**Repos affected:** `fluent-api`
**Parent:** [Licensed Content Protection Assessment §3 "Medium: Authenticated-only text/audio is not project-scoped"](../2026-09-02-licensed-content-protection-assessment.md#3-principal-gaps), [remediation plan](../plan.md)
**Priority:** P1 — do alongside or immediately after the P0 bulk-endpoint ticket, same code area

## Problem

Two routes require login but not project membership or a linked assignment,
so any active authenticated user can request any known Bible/book/chapter ID
— not just content tied to a project they belong to:

- Single-chapter Bible-text endpoint:
  `fluent-api/src/domains/bibles/bible-texts/bible-texts.route.ts:52-95`
- Legacy direct Bible-audio endpoint:
  `fluent-api/src/domains/bibles/bible-audio/bible-audio.route.ts:44-84`

The assessment holds up `fluent-api/src/domains/source-audio/` (the newer
`/projects/{projectId}/source-audio/...` route) as the model: authentication
+ project access + confirmation that the requested Bible/book is actually
linked to that project. These two legacy/simple routes should follow the
same pattern instead of stopping at "logged in."

## Proposal

1. Add the same entitlement check used in
   [the P0 ticket](2026-09-11-p0-close-anonymous-bible-text-endpoint.md) (or
   share the repository function it introduces) to the single-chapter
   text route: requester must have a project/assignment relationship — or
   at minimum, project membership — that covers the requested Bible/book.
2. Apply the equivalent check to the legacy Bible-audio route, or confirm
   with the API team whether that route is deprecated in favor of
   `source-audio` and can be removed outright instead of patched. If it's
   still in active use by any client, patch it; if not, file a follow-up to
   delete it rather than maintaining two audio delivery paths.
3. Add negative tests: authenticated user with no project membership for
   the requested Bible/book → 403 (not merely "logged in is enough").

## Scope

- `fluent-api/src/domains/bibles/bible-texts/bible-texts.route.ts:52-95`
- `fluent-api/src/domains/bibles/bible-audio/bible-audio.route.ts:44-84`
- Shared entitlement-check helper, ideally extracted once and reused by this
  ticket, the P0 bulk-endpoint ticket, and `source-audio` rather than
  three separate implementations of "is this Bible/book linked to this
  project."

## Testing / verification strategy

- Integration test: authenticated user, no membership on the project owning
  the requested Bible/book → 403.
- Integration test: authenticated user, valid membership → 200, unchanged
  response shape (this is a scoping change, not a contract change for
  legitimate callers).
- If the legacy audio route is deleted instead of patched, confirm no
  current mobile/web client build still calls it before removing.
