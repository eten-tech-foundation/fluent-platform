# Remove the Aquifer provider key from the mobile app

**Date:** 2026-09-11
**Repos affected:** `fluent-mobile`, `fluent-api`
**Parent:** [Licensed Content Protection Assessment §3 "High: Aquifer API key is embedded in the APK"](../2026-09-02-licensed-content-protection-assessment.md#3-principal-gaps), [remediation plan](../plan.md)
**Priority:** P1

## Problem

`AQUIFER_API_KEY` is put into Expo `extra` in `app.config.ts` and read from
`expo-constants` at runtime, which means it's recoverable directly from the
built APK/app config
(`fluent-mobile/app.config.ts:49-60`, `fluent-mobile/src/config/aquiferApi.ts:40-56`).
Mobile code calls Aquifer directly to retrieve alternate Bible translations
and other content
(`fluent-mobile/src/services/prepareOfflineResourceManifest.ts:311-330`).

This directly conflicts with the API-side stance that the Aquifer key
should never be shipped to a client (`fluent-api/src/env.ts:134-142`
describes it as server-held, same as the DBL key). The production Prepare
Offline UI currently uses a mock manifest, so this path isn't fully wired
into the live UI yet — which makes now the cheapest time to fix it, before
a real feature depends on the client-side call shape.

## Proposal

1. Add Aquifer-backed routes to `fluent-api`, following the same pattern
   already used for DBL/Bible content and for `source-audio` — authenticated,
   project-scoped, server holds the Aquifer key and calls Aquifer
   server-to-server.
2. Migrate `prepareOfflineResourceManifest.ts` (and anywhere else in mobile
   that calls Aquifer directly) to call the new `fluent-api` routes instead
   of Aquifer directly.
3. Remove `AQUIFER_API_KEY` from `app.config.ts` `extra` and delete the
   direct-call client code in `fluent-mobile/src/config/aquiferApi.ts` once
   nothing references it.
4. **Rotate the Aquifer key** after migration — the current key must be
   treated as already compromised/exposed (it's in every installed build
   and every past APK), so a new key is required, not just moving the call
   site.
5. Wire the real Prepare Offline UI to the new API-backed path instead of
   the mock manifest, if that work is in scope for this ticket vs. a
   separate feature ticket — confirm with whoever owns Prepare Offline
   before bundling it in.

## Scope

- `fluent-api`: new Aquifer-proxy domain (routes, service, repository as
  needed), reusing existing auth/project-scoping middleware — no new public/
  internal split, same single API surface and middleware pipeline used
  elsewhere.
- `fluent-mobile/app.config.ts:49-60` (remove `AQUIFER_API_KEY` from
  `extra`)
- `fluent-mobile/src/config/aquiferApi.ts` (delete or reduce to nothing once
  unused)
- `fluent-mobile/src/services/prepareOfflineResourceManifest.ts:311-330`
  (call `fluent-api` instead of Aquifer directly)
- Aquifer key rotation (infra/secrets task, coordinate with whoever holds
  the Aquifer account)

## Testing / verification strategy

- Confirm no mobile network call goes to Aquifer's domain directly after
  the change (e.g. inspect network logs from a test build).
- `fluent-api` integration test: Aquifer-proxy routes require auth + project
  scope, same negative-test shape as the other endpoint tickets in this
  plan (anonymous → 401, wrong project → 403).
- After rotation, confirm the **old** key no longer works against Aquifer
  (if Aquifer's API supports checking key validity) and that no build still
  in the wild silently breaks in a confusing way — coordinate rollout so
  old app versions relying on the direct call (if any are live) don't get
  cut off without warning, or confirm none are.
