# Protect offline Bible text and downloaded resources on mobile

**Date:** 2026-09-11
**Repos affected:** `fluent-mobile`
**Parent:** [Licensed Content Protection Assessment §3 "High: Local Bible text is plaintext and persistent"](../2026-09-02-licensed-content-protection-assessment.md#3-principal-gaps), [remediation plan](../plan.md)
**Priority:** P1

## Problem

Once synced, Bible text sits in a plaintext, device-wide SQLite table with
no ownership metadata, and survives logout:

- DB opened without SQLCipher or any encryption key
  (`fluent-mobile/src/db/index.ts:20-35`).
- `bible_texts` has no `user_id`, project, license, or expiration column
  (`fluent-mobile/src/db/schema.ts:70-80`).
- On logout: the auth token is revoked/removed, but the Bible-text DB is
  **not** cleared, downloaded resources are **not** deleted, and project/
  assignment data remains
  (`fluent-mobile/src/services/accountSession.ts:37-79`).
- **Clear cache** in Settings only removes paused recording segments — it
  does not touch synced Scripture or downloaded resources
  (`fluent-mobile/src/app/screens/SettingsScreen.tsx:90-104`).

A revoked user can't use the app's UI anymore, but the content they already
synced is still physically present and readable with filesystem access to
the device.

## Proposal

1. **Encrypt at rest.** Encrypt the local database, or at minimum the
   licensed-content tables (`bible_texts` and any downloaded-resource
   tables), and encrypt downloaded licensed audio/resource files on disk —
   not just the DB.
2. **Add ownership metadata.** Add `user_id`/project/license columns (or an
   equivalent join) to `bible_texts` and downloaded-resource records, so
   content can be identified and purged by whose it is and what license it
   came under.
3. **Purge on**:
   - Account removal
   - Project membership revocation
   - License expiration or revocation (per
     [the license-model ticket](2026-09-11-p1-bible-license-rights-model.md)'s
     rights start/end dates and revocation state)
   - The server marking content unavailable
4. **Add a real "Remove downloaded content" action**, distinct from the
   existing paused-recording cache cleanup in `SettingsScreen.tsx`, that
   actually deletes synced Scripture and downloaded resources.
5. **Narrow or disable Android backup** for the licensed-content storage
   paths so `adb backup` / cloud backup can't extract it outside the app
   sandbox.

Be explicit in the PR/design that this raises extraction cost and supports
contractual controls — it does not, and cannot, prevent a determined user
with a rooted/compromised device, since the app must eventually decrypt
content locally to display it. Don't oversell this as airtight DRM.

## Scope

- `fluent-mobile/src/db/index.ts` (encrypted DB open, e.g. SQLCipher)
- `fluent-mobile/src/db/schema.ts:70-80` (`bible_texts` ownership columns;
  same for downloaded-resource tables)
- New migration(s)
- `fluent-mobile/src/services/accountSession.ts:37-79` (logout purge)
- `fluent-mobile/src/app/screens/SettingsScreen.tsx:90-104` (real "Remove
  downloaded content" action)
- `fluent-mobile/src/services/downloadStorage.ts` (encrypt files at rest,
  purge-by-owner support)
- Android backup config (`app.config.ts` / native Android manifest,
  `android:allowBackup` / backup rules XML)

## Testing / verification strategy

- Logout flow test: after logout, `bible_texts` and downloaded-resource
  storage are empty (or unreadable without a key that's also gone) — not
  just that the auth token was cleared.
- Migration test: existing plaintext data on upgrade is either migrated
  into encrypted storage or purged — decide and document which, don't leave
  old plaintext rows sitting alongside a new encrypted table.
- Manual device-filesystem check (e.g. via `adb shell` on a debug build) to
  confirm the DB file is not human-readable plaintext post-change.
- Verify `adb backup` (or equivalent) no longer extracts licensed-content
  files after the Android backup config change.
- "Remove downloaded content" button test: confirms actual file/DB
  deletion, not just a UI state reset.
