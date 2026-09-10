# Licensed Content Protection Assessment

**Assessment date:** 2026-09-01  
**Repositories reviewed:** `fluent-api`, `fluent-mobile`  
**Primary content type:** Licensed and copyrighted Bible text

## Executive summary

The current protection posture is mixed:

- Project translations, recordings, exports, translation resources, and newer source-audio routes have meaningful authentication, project membership checks, and short-lived download URLs.
- Source Bible text has substantially weaker protection. The endpoint used by mobile is intentionally anonymous, accepts up to 1,200 chapters per request, and is protected only by a process-local IP rate limiter.
- Once synchronized, Bible text is stored in an unencrypted, device-wide SQLite database, remains after logout or session revocation, and has no user or license ownership metadata.
- The system does not persist or enforce copyright terms, attribution, offline rights, expiration, or API.Bible FUMS/fair-use metadata.
- Mobile authentication tokens are protected with Android secure storage, production cleartext HTTP is disabled, and the UI does not offer copy/share functionality. These controls do not compensate for the anonymous API endpoint and plaintext retention.

**Bottom line:** copyrighted source Bible text should currently be treated as readily extractable, both from the API and from a device with filesystem access. The strongest existing controls apply to user-created project content rather than source Scripture.

## 1. Current content flow

1. `fluent-api` obtains the Bible catalog and chapter content from API.Bible/DBL using a server-held API key.
2. Bible ingestion is triggered for books selected for a project rather than automatically ingesting the entire Bible. This is useful data minimization (`fluent-api/src/domains/projects/projects.service.ts:152-205`).
3. Chapter content is parsed and stored as individual verse rows in PostgreSQL. Copyright metadata returned by DBL is not retained (`fluent-api/src/workers/ingest-bible-text.worker.ts:87-147`).
4. Mobile authenticates to retrieve its projects and chapter assignments.
5. Mobile derives the Bible chapters it needs from locally synchronized assignments (`fluent-mobile/src/db/repository.ts:571-599`).
6. Mobile then retrieves those texts through the anonymous bulk-text endpoint (`fluent-mobile/src/services/api.ts:166-174`).
7. The verses are stored indefinitely in the local SQLite `bible_texts` table and read by the UI offline (`fluent-mobile/src/db/schema.ts:70-80`).

The assignment restriction in step 5 is client behavior, not server enforcement. A custom client can skip that step and request arbitrary chapters.

## 2. Protections currently in place

### 2.1 Active protections

#### API authentication and project authorization

- The ordinary single-chapter text endpoint requires an active authenticated account (`fluent-api/src/domains/bibles/bible-texts/bible-texts.route.ts:52-95`).
- Project and assignment synchronization endpoints require authentication, permission checks, and `requireSelf()`. A user cannot normally request another user's assignment feed (`fluent-api/src/domains/users/chapter-assignments/users-chapter-assignments.route.ts:73-85`).
- Translation notes, questions, images, and their offline manifest require authentication, `PROJECT_VIEW`, and project access.
- The newer source-audio endpoints require authentication, project access, and confirmation that the requested Bible/book is linked to that project (`fluent-api/src/domains/source-audio/source-audio.route.ts:77-120`, `fluent-api/src/domains/source-audio/source-audio.repository.ts:10-34`).
- Draft verse recordings are project/assignment authorized and served through 15-minute signed URLs.
- USFM exports require project-unit access, validate selected books, bind asynchronous jobs and downloads to the requester, and use short-lived presigned URLs (`fluent-api/src/domains/usfm/usfm-auth.middleware.ts:20-52`, `fluent-api/src/domains/usfm/usfm.route.ts:437-467`, `fluent-api/src/domains/usfm/usfm.route.ts:483-513`).

#### Bulk endpoint abuse throttling

The anonymous bulk endpoint has:

- A maximum of 1,200 requested chapters per request.
- A configurable limit, defaulting to 20 requests per minute per client IP.
- Proxy-aware IP extraction.
- `429` and `Retry-After` responses.

Evidence: `fluent-api/src/domains/bibles/bible-texts/bible-texts.types.ts:14-24` and `fluent-api/src/middlewares/rate-limit.ts:68-114`.

This limiter has tests for proxy handling, bucket isolation, expiration, and memory limits. All 14 targeted tests passed during this audit.

#### API credentials

- The DBL/API.Bible credential remains on the API server and is sent only in server-to-provider requests (`fluent-api/src/lib/services/dbl/dbl.client.ts:138-164`).
- The API-side Aquifer integration similarly describes its key as server-held and unsuitable for client exposure (`fluent-api/src/env.ts:134-142`).

#### Mobile authentication and network security

- Fluent bearer tokens are stored in `expo-secure-store`, backed by Android Keystore/encrypted storage rather than the main SQLite database (`fluent-mobile/src/services/keychain.ts:25-47`).
- Authenticated requests add the bearer token centrally. Error logging intentionally avoids raw non-JSON response bodies (`fluent-mobile/src/services/httpClient.ts:18-50`).
- Protected screens are gated by restored authentication state (`fluent-mobile/src/routes/_layout.tsx:39-67`).
- Production builds disable cleartext HTTP at the Android platform level. Development and preview builds allow it (`fluent-mobile/app.config.ts:18-22`, `fluent-mobile/app.config.ts:85-96`).

#### Content minimization in the mobile UI

- Mobile sync requests only chapters represented by local assignments instead of automatically retrieving all available Bible text.
- Source text is hidden behind a **View source text** control and displayed one verse at a time in a bounded area (`fluent-mobile/src/components/ui/SourceTextAccordion.tsx:28-79`).
- No clipboard, text-sharing, or Scripture export feature was found.
- React Native text is not explicitly made selectable.
- USFM export uses translated content, not source Bible text. The source-text table supplies verse structure and IDs, while exported content comes from `translated_verses.content` (`fluent-api/src/domains/usfm/usfm.repository.ts:123-159`).

#### Cache and logging behavior

- API `GET` responses receive `no-store`, `no-cache`, and related headers by default (`fluent-api/src/server/server.ts:203-213`).
- Normal request logs contain method, path, status, and duration, not response bodies or Scripture text.
- Bible repository errors log IDs and chapter counts rather than verse text (`fluent-api/src/domains/bibles/bible-texts/bible-texts.repository.ts:84-90`).

### 2.2 Passive protections

These reduce exposure but are not robust access controls:

- The DBL synchronization code describes the imported catalog as “open-license Bibles” (`fluent-api/src/domains/bibles/sync/dbl-bible-sync.ts:19-30`).
- Ingestion is limited to project-selected books.
- Android's normal application sandbox prevents ordinary apps from reading Fluent's private database and files.
- Mobile UI/navigation generally exposes content through authenticated assignment workflows.
- The app does not provide convenient copy, share, save-image, or source-text export actions.
- Offline files are placed into per-project directories, and deletion validates that a path is within the expected project sandbox (`fluent-mobile/src/services/downloadStorage.ts:47-73`).

CORS is configured, but it should not be counted as copyrighted-content protection: non-browser clients can call the API regardless of CORS.

## 3. Principal gaps

### Critical: Anonymous bulk Bible-text access

The mobile endpoint is explicitly anonymous and can return up to 1,200 requested chapters (`fluent-api/src/domains/bibles/bible-texts/bible-texts.route.ts:97-110`, `fluent-api/src/domains/bibles/bible-texts/bible-texts.route.ts:158-168`).

There is no:

- User authentication.
- Project or organization check.
- Assignment check.
- Bible entitlement check.
- License check.
- Per-Bible restriction.
- Server-generated allowed chapter set.

The default limit permits up to 20 very large requests per minute per application process. Because state is in memory, additional API instances each maintain independent counters. Bucket eviction and changing IPs further weaken this as a scraping defense.

The response is also a `POST`, while the global anti-cache middleware applies only to `GET`.

### High: No license-rights model

The `bibles` table stores provider and external identity but no:

- License identifier or category.
- Copyright statement.
- Attribution requirements.
- Permission for offline storage.
- Permission for recording or derivative use.
- Distribution or quotation limits.
- Validity or expiration dates.
- Revocation status.
- Provider terms version.

Evidence: `fluent-api/src/db/schema.ts:214-237`.

Likewise, `bible_texts` stores only Bible/book/chapter/verse/text (`fluent-api/src/db/schema.ts:345-375`).

Although DBL response types contain copyright fields, ingestion discards them. The catalog sync does not inspect a license field; it trusts that `getBibles()` returns an appropriately licensed catalog for the configured key.

### High: API.Bible FUMS/fair-use support is unfinished

The DBL client explicitly says that FUMS metadata is accepted but not surfaced, with a future ticket expected to implement reporting (`fluent-api/src/lib/services/dbl/dbl.client.ts:125-130`).

If FUMS reporting or copyright display is part of the provider agreement, the current application cannot demonstrate compliance.

### High: Local Bible text is plaintext and persistent

The mobile database is opened normally without SQLCipher or an encryption key (`fluent-mobile/src/db/index.ts:20-35`).

Bible text is plaintext in a device-wide table with no `user_id`, project, license, or expiration column (`fluent-mobile/src/db/schema.ts:70-80`).

On logout:

- The current token is revoked or removed.
- The Bible-text database is not cleared.
- Downloaded resources are not automatically deleted.
- Project and assignment data remain.
- **Clear cache** removes only paused recording segments.

Evidence: `fluent-mobile/src/services/accountSession.ts:37-79` and `fluent-mobile/src/app/screens/SettingsScreen.tsx:90-104`.

A revoked user can no longer use the normal UI, but previously synchronized content remains physically present.

### High: Aquifer API key is embedded in the APK

Mobile's `app.config.ts` puts `AQUIFER_API_KEY` into Expo `extra`, after which application code reads it from `expo-constants`. The key is therefore recoverable from the application binary/configuration (`fluent-mobile/app.config.ts:49-60`, `fluent-mobile/src/config/aquiferApi.ts:40-56`).

Direct mobile Aquifer code can retrieve alternate Bible translations and other content (`fluent-mobile/src/services/prepareOfflineResourceManifest.ts:311-330`).

The production Prepare Offline UI is currently still using a mock manifest, so this direct path is not fully wired into that screen. Nevertheless, the key and callable client code exist. This also conflicts with the API-side direction that the Aquifer key should never be shipped to clients.

### Medium: Authenticated-only text/audio is not project-scoped

The single-chapter Bible-text endpoint and legacy direct Bible-audio endpoint require login, but any active user can request any known Bible/book/chapter ID. They do not require project membership or a linked assignment (`fluent-api/src/domains/bibles/bible-audio/bible-audio.route.ts:44-84`).

The newer `/projects/{projectId}/source-audio/...` route has much better authorization and should be the model for licensed content.

### Medium: Attribution is incomplete

- DBL copyright fields are discarded.
- Aquifer `licenseInfo` is typed but not consumed.
- Image UI can render attribution, but current API mapping returns only title/URL in several paths.
- The mobile Bible model contains only ID, language, name, and abbreviation (`fluent-mobile/src/types/api/responses.ts:29-34`).
- The mobile Terms of Use discusses AI output but does not state restrictions on copying or redistributing licensed Scripture (`fluent-mobile/src/app/tabs/TermsOfUsePage.tsx`).

### Medium: Device-level extraction defenses are absent

No explicit configuration was found for:

- Disabling Android backup/data extraction.
- Screenshot or screen-recording prevention.
- A privacy cover in the Android recent-apps view.
- Rooted-device detection.
- Database/file encryption.
- Certificate pinning.
- Explicit release obfuscation/hardening.

Screenshots and screen recording are consequently available by default. No user-friendly sharing feature exists, but that differs from actively blocking capture.

## 4. Recommended path forward

### Priority 0: Close the anonymous source-text endpoint

1. Require `authenticateUser`.
2. Make the request project- or assignment-based rather than accepting arbitrary Bible IDs and chapter lists.
3. Have the server calculate the allowed chapters from the authenticated user's assignments.
4. Require a project entitlement that links the Bible/book to that project.
5. Change mobile from `publicRequest` to `authedRequest`.
6. Keep rate limiting as secondary abuse protection, preferably using a shared store or API gateway.
7. Add explicit `Cache-Control: no-store` to all source-content responses, including `POST`.
8. Add negative tests for anonymous, cross-user, cross-project, and unrelated-Bible requests.

A short-term remediation would be authentication plus server-side assignment validation. A capability-based offline manifest could then provide a cleaner long-term design.

### Priority 1: Establish a rights and license model

Add Bible/resource metadata such as:

- `licenseId` and license category.
- Copyright and attribution text.
- Provider/source.
- `allowOnlineDisplay`.
- `allowOfflineStorage`.
- `allowAudio`.
- `allowDerivativeWork`.
- `allowExport`.
- Maximum offline scope or quotation size.
- Rights start/end dates.
- Revocation state.
- Provider terms/version.
- Required telemetry/FUMS behavior.

Evaluate these rules before ingestion, API delivery, offline download, and export—not only in the UI.

### Priority 1: Implement provider compliance

- Preserve DBL copyright fields.
- Implement required FUMS handling/reporting.
- Preserve Aquifer `licenseInfo`.
- Display attribution in Bible/source-text, audio, and image/resource interfaces.
- Document which provider/license combinations permit local verse storage and derivative translation work.

### Priority 1: Protect offline content

- Encrypt the local database or at least the licensed-content tables.
- Encrypt downloaded licensed audio/resources.
- Explicitly disable or narrowly configure Android backups.
- Associate cached content with user/project/license.
- Purge it when:
  - An account is removed.
  - Project membership is revoked.
  - The license expires or is revoked.
  - The server marks the content unavailable.
- Provide a complete **Remove downloaded content** function, separate from paused-recording cache cleanup.

Because an offline app must eventually decrypt content to display it, this cannot prevent a determined user with a compromised device. It meaningfully raises extraction cost and supports contractual controls.

### Priority 1: Remove provider keys from mobile

Move all Aquifer access behind authenticated, project-scoped Fluent API routes. The API already has most of this pattern. Rotate the mobile-exposed key after the migration.

### Priority 2: Add policy-driven platform protections

Depending on license requirements:

- Apply Android `FLAG_SECURE`/Expo screen-capture protection on restricted Bible and resource screens.
- Add a recent-apps privacy cover.
- Keep copy/share disabled for restricted licenses.
- Allow these features selectively for open/public-domain content rather than globally blocking them.
- Consider Play Integrity/root signals as risk indicators, not absolute authorization.

Certificate pinning and obfuscation can be defense in depth, but they should come after closing the anonymous endpoint, implementing entitlement checks, and protecting offline data.

### Priority 2: Add access accountability

- Audit licensed-content reads with user/project/Bible/license identifiers and volume, but not raw text.
- Alert on unusual Bible/chapter enumeration and large sync volumes.
- Use distributed rate limits and per-user quotas.
- Record license decisions so the organization can show why content was delivered.

## 5. Overall current-state rating

| Area | Current posture |
|---|---|
| Source Bible-text API access | **Weak** |
| Project translations | **Good** |
| User-created verse audio | **Good** |
| Project-scoped source audio | **Good** |
| Legacy direct source audio | **Moderate/weak** |
| Offline Bible-text protection | **Weak** |
| Provider key handling | **Mixed** |
| License/attribution compliance | **Weak/incomplete** |
| Logging exposure | **Reasonable** |
| Export controls | **Good for translated content** |
| Screenshot/copy resistance | **Mostly passive** |

## 6. Audit notes

- At audit time, `fluent-api` was on `ci/db-preflight` at `5b2e11e`, with unrelated local modifications to deployment/package preflight files.
- At audit time, `fluent-mobile` was on `mrace/chore/405-sha-pin-github-actions-gate` at `776144b`.
- No source repository files were changed during the audit.
- API rate-limiter tests: **14/14 passed**.
- Mobile targeted tests could not initialize because the installed dependency tree lacked `react-native-worklets`; the relevant test source was reviewed statically.
- This is a technical current-state assessment, not a legal determination of the rights granted by any specific Bible license or provider agreement.
