# Add policy-driven platform capture/extraction hardening

**Date:** 2026-09-11
**Repos affected:** `fluent-mobile`
**Parent:** [Licensed Content Protection Assessment §3 "Medium: Device-level extraction defenses are absent" and §4 "Priority 2: Add policy-driven platform protections"](../2026-09-02-licensed-content-protection-assessment.md#3-principal-gaps), [remediation plan](../plan.md)
**Priority:** P2 — defense in depth, do after Wave 1/2 land

## Problem

No configuration currently exists for: disabling Android backup/data
extraction (partially covered by
[the offline-protection ticket](2026-09-11-p1-protect-offline-content-mobile.md)'s
backup-narrowing task — this ticket covers the remaining device-level
controls), screenshot/screen-recording prevention, a privacy cover in the
Android recent-apps view, rooted-device detection, certificate pinning, or
explicit release obfuscation/hardening. Screenshots and screen recording
work by default; there's no copy/share feature to begin with, but that's
different from actively blocking capture.

## Proposal

Apply these selectively by license, using the `allowOfflineStorage`/
`allowDerivativeWork`/etc. fields from
[the license-model ticket](2026-09-11-p1-bible-license-rights-model.md) —
not globally. Open/public-domain content should NOT get these restrictions;
only content whose license actually calls for them.

1. **Screen capture protection** (Android `FLAG_SECURE` / Expo's
   screen-capture-prevention API) on screens displaying restricted-license
   Bible/resource content.
2. **Recent-apps privacy cover** so restricted content doesn't appear in the
   OS app-switcher thumbnail.
3. **Keep copy/share disabled** for restricted licenses (already true
   today by omission — make it an explicit, tested policy rather than an
   accident of no feature existing yet, so a future PR adding a share
   feature doesn't silently reintroduce the gap).
4. **Root/Play Integrity signals as risk indicators, not authorization.**
   Use Play Integrity API (or equivalent) to flag rooted/compromised
   devices for reduced trust (e.g. skip offline caching of restricted
   content on a flagged device) — do not use this as the sole gate for
   whether content is served at all, since it's a signal, not a guarantee.
5. **Certificate pinning and release obfuscation** — explicitly called out
   in the assessment as defense-in-depth that should come *after* Wave 1/2,
   not before. Scope as a follow-up sub-task once the rest of this ticket
   lands, not a blocking part of it.

## Scope

- `fluent-mobile/app.config.ts` (screen-capture config, Android manifest
  flags)
- Screen-level components for restricted-license source-text, audio, and
  resource views — gate `FLAG_SECURE` per-screen based on the license data,
  not app-wide
- New: Play Integrity (or equivalent) integration point
- Follow-up (not required to close this ticket): certificate pinning, build
  obfuscation config

## Testing / verification strategy

- Manual verification on a test device: screenshot attempt on a restricted-
  license screen is blocked (blank/black capture); an open-license screen
  is unaffected.
- Recent-apps thumbnail check on a restricted screen.
- Integrity-signal test: a flagged (rooted/emulator) test device produces
  the reduced-trust behavior without being fully blocked from the app.
- Confirm license-gating logic reads real license data
  (`allowOfflineStorage` etc.), not a hardcoded restricted/open split —
  this ticket depends on
  [the license-model ticket](2026-09-11-p1-bible-license-rights-model.md)
  being in place first.
