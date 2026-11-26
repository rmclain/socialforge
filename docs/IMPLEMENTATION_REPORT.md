# SocialForge Implementation Report

**Date:** 2026-11-26  
**Scope:** End-to-end architecture, security, multi-platform publishing, AI/ComfyUI/MCP integrations, creative workflows, performance, optional publishing service reconciliation, release hardening, and verification.

---

## 1. Executive Summary

SocialForge has been consolidated and hardened from a Pinterest-centric prototype into a cohesive, local-first macOS social media production and scheduling application built with Swift, SwiftUI, AppKit, and SwiftData.

All foundational product principles were preserved:

- Native macOS application (`apps/mac`) with SwiftData persistence and warm orange design language (`UI/DS.swift`, `UI/Grid.swift`, bundled Instrument Serif, light & dark modes).
- Local-first architecture with bring-your-own-credentials (BYOK) in the macOS Keychain — no mandatory cloud account, subscription, Docker deployment, or SocialForge backend.
- Full support for local AI providers (Ollama, LM Studio, OpenAI-compatible local servers, ComfyUI) and cloud BYOK providers (OpenAI, Anthropic, Google Gemini).
- Optional self-hosted Fastify + PostgreSQL publishing service (`services/api`) reconciled with the Mac app via explicit capability discovery (`GET /v1/capabilities`) and per-post publishing ownership.
- Strict human-approval boundaries on publishing and external agent operations, original media preservation, and strict brand workspace isolation.

Across 84 modified files and 5 new modules (+6,878 / -1,490 lines), every verified automated suite passes: **197 Swift unit tests (33 suites)**, **89 in-app end-to-end self-test checks**, **23 optional Fastify API/worker integration tests**, **38/38 layout probe checks**, and **`grid-lint.sh`**.

---

## 2. Audit Findings and Fixes

A full repository audit identified and resolved high-severity security, data-loss, concurrency, workspace-isolation, and UX issues:

### Security & Credential Hygiene
- **OAuth callback leakage (`site/index.html`)**: Added `<meta name="referrer" content="no-referrer">` and `history.replaceState` to strip `?code=`/`&state=` and hash fragments immediately on load so authorization codes cannot leak via Referer headers or browser history.
- **OAuth CSRF bypass (`MetaPublishing.swift`)**: `OAuthRedirect.code(..., expectedRedirectURI:)` now rejects bare authorization codes, missing/mismatched `state` parameters, and mismatched redirect URIs.
- **Token exposure in query strings (`MetaPublishing.swift`)**: Moved Meta/Threads `client_secret` and `access_token` out of GET URL query parameters into POST form bodies and `Authorization: Bearer` headers.
- **Loopback OAuth listener races (`OnMacPublishing.swift`)**: Hardened `OAuthLoopback` to await `.ready` before opening the browser, ignore stray requests (e.g., `/favicon.ico`), validate HTTP framing (`\r\n\r\n`) and callback path, and respect task cancellation.
- **Remote AI transport security (`AIProviders.swift`, `MCPClient.swift`)**: Enforced HTTPS on remote endpoints (`aiEndpointTransportProblem`), permitting plain HTTP only for loopback/private local addresses (`localhost`, `127.0.0.1`, `::1`, `.local`, RFC 1918 LAN).
- **CSV formula injection (`Analytics.swift`)**: Neutralized leading `=`, `+`, `-`, `@`, `\t`, `\r` characters in exported CSV cells.
- **Prompt injection defense (`PostCopy.swift`)**: Wrapped `BrandVoice` fields inside structured JSON `<brand_guide>` data blocks via `AIJSON.dataBlock` and sanitized unknown platform strings.
- **Updater bundle verification (`Updater.swift`)**: Verified matching `CFBundleIdentifier` alongside TeamIdentifier, fixed prerelease version comparisons, and invalidated ephemeral `URLSession` instances.
- **Keychain hardening (`AppModel.swift`)**: Checked `OSStatus` on Keychain operations, added per-profile/per-account scoped credential keys, and avoided Keychain reads inside SwiftUI `body`.

### Data Loss, Persistence & Workspace Isolation
- **Workspace leakage**: Scoped `SocialAccount` lookups in `PublishRunner`, `BrandKitInspector`, `CampaignInspector`, `AutomationInspector`, `SearchResults`, `agentUpdateMedia`, `mediaUsage`, and `AutomationEngine.tick()` strictly to the owning `workspaceID`. Switching workspaces now resets transient drafts and selections cleanly.
- **Automation self-recursion guard (`AutomationsView.swift`)**: Added `folderOverlapProblem` blocking automations from watching SocialForge's managed storage root, SwiftData store folder, or any brand library folder; added re-entrancy locking, `processedFingerprints` deduplication, `weekly`/`tag` trigger fixes, and non-stamping dry runs.
- **Orphaned & deleted media (`AppModel.swift`, `MediaImport.swift`, `AIStudioView.swift`)**: `deleteMedia` now removes variant files on disk; `mediaUsage` protects `BrandKit.logoPath`; AI Studio delete checks usage and prompts for confirmation; media readability is validated before keeping files in `Originals/`; temp directories are cleaned up reliably.
- **Non-destructive database recovery (`App.swift`)**: Replaced startup `fatalError` with timestamped database backup before recovery and enforced `0700` directory permissions.
- **Settings wiping backend token (`SettingsView.swift`, `AppModel.swift`)**: Fixed Publishing Service "Check" overwriting the saved bearer token and prevented test/snapshot `Store.isOverridden` runs from mutating `UserDefaults`.
- **Silent approval & scheduling traps (`HomeView.swift`, `Models.swift`, `AccountsView.swift`)**: Distinguished `Approved` from `Scheduled` (added "Approve & Schedule" and "approved but unscheduled" attention banners), added `approvedFingerprint` so editing an approved post automatically returns it to `Needs Review`, and fixed Accounts Reconnect dispatching to each account's actual platform instead of hardcoded Pinterest.

---

## 3. Unified Connection Architecture & Provider Matrix

Connections are consolidated around a shared lifecycle and diagnostics model in `SocialForgeKit/Connections.swift` and surfaced in the redesigned 5-category Connections hub (`Pages/AccountsView.swift`):

1. **Social Accounts** — Pinterest, Facebook Pages, Instagram (Facebook Login & Instagram Business Login), Threads, LinkedIn (Personal & Organization), X, TikTok, YouTube.
2. **AI Providers** — OpenAI, Anthropic, Google Gemini, OpenAI-compatible endpoints, Ollama, LM Studio, ComfyUI.
3. **Media Storage** — S3-compatible storage and Cloudflare R2 (multiple profiles, path-style and virtual-hosted addressing).
4. **Automation & Agents** — Local SocialForge Inbound MCP server + Outbound Creative MCP clients (ArtCraft / custom stdio & HTTP servers).
5. **Publishing Infrastructure** — On-Mac foreground publisher, background LaunchAgent (`SMAppService`), and optional remote Fastify publishing service.

### Shared Lifecycle & Diagnostics
- **13-state `ConnectionStatus`**: `notConfigured`, `configuredUntested`, `connecting`, `connected`, `connectedWithLimitations`, `expiringSoon`, `reauthRequired`, `missingPermissions`, `unreachable`, `rateLimited`, `configurationError`, `revoked`, `disabled`.
- **Dynamic account capability layer (`DynamicAccountCapabilities`)**: Complements static `spec/platforms/*.json` rules with live account type, granted vs. missing scopes, sandbox vs. production mode, publishing route, and public media hosting availability.
- **Multi-profile & cross-workspace sharing**: `SocialAccount.credentialProfileID` decouples provider credentials from brand workspace associations so one authenticated identity can serve multiple workspaces without duplicating tokens or breaking other workspaces on disconnect.
- **Guided Setup Wizards & Sanitized Diagnostics**: Step-by-step setup wizard per provider with prerequisites, developer console links, copyable redirect URIs, credential fields, test/discovery, and a `ConnectionDiagnosticReport` + Copy Diagnostics action scrubbed by `DiagnosticRedactor.sanitize` (redacting Bearer tokens, API keys, OAuth codes, refresh tokens, AWS signatures, and signed query strings).

---

## 4. OAuth and Credential Security Improvements

- **RFC 7636 PKCE (`S256`)**: Implemented `PKCEPair` in `SocialForgeKit/Connections.swift` and wired PKCE into X, TikTok, and YouTube OAuth flows.
- **Single-flight token refresh (`TokenLifecycleManager`)**: Actor-based per-credential refresh deduplication ensures concurrent publishing jobs or UI refresh triggers never race or overwrite rotated refresh tokens.
- **Strict callback validation**: `OAuthRedirect.code(..., expectedRedirectURI:)` enforces matching state and redirect URI on manual callbacks; `OAuthLoopback` enforces path, framing, and state on automatic loopback callbacks.
- **Credential persistence**: Secrets remain in the macOS Keychain accessible to both the foreground app and signed `--publish-agent` mode; non-sensitive configuration remains in SwiftData/preferences. Disconnecting preserves drafts, schedules, and media while removing or detaching credentials cleanly.

---

## 5. Social Platform Integration Status & Verification Matrix

> **Honesty commitment:** No social platform is marked `liveVerified: true` without observed real-world OAuth and live publishing runs. Every platform below is explicitly labeled `Adapter built · unverified live` in the application UI until tested with real developer credentials.

| Platform | Auth & Refresh | Supported Content Types | Dynamic / Spec Rules | Automated Verification | Live Status |
|---|---|---|---|---|---|
| **Pinterest** | OAuth 2.0 + refresh-token rotation; Sandbox & Production | Image Pin, Video Pin, board & paginated board sections | `pins:write`, `boards:read`; 100-char title, 800-char desc | Stubbed HTTP unit tests + Mock E2E self-test + Fastify worker tests | **Not yet live verified** |
| **Facebook Pages** | Meta OAuth (Facebook Login / Business Config) | Text, Photo, Multi-Photo, Link, Reel | Managed Pages only; `pages_manage_posts`; strict media failure (no silent text fallback) | Stubbed HTTP unit tests | **Not yet live verified** |
| **Instagram** | Facebook Login (linked Page) **and** direct Instagram Business Login | Photo, Carousel, Reel; 24h quota limit check | Professional account required; public S3/R2 hosting required for photo/carousel; Reels upload directly | Stubbed HTTP unit tests | **Not yet live verified** |
| **Threads** | Standalone Threads OAuth + long-lived token refresh | Text, Image, Video, Carousel | 500-char text; public S3/R2 URL required for media; HTTPS redirect URI | Stubbed HTTP unit tests | **Not yet live verified** |
| **LinkedIn** | OAuth 2.0 (`w_member_social`, `w_organization_social`) | Personal & Organization text, image, document/video posts | Fixed `maxBytes` (5 MB image spec bug); member & org discovery | Stubbed HTTP unit tests | **Not yet live verified** |
| **X** | OAuth 2.0 PKCE (`S256`) + refresh | Text, Image, Video (v2 chunked media upload) | Weighted character counter (`XTextLength.weightedCount`: URLs=23, CJK/emoji=2); rate-limit header parsing | Stubbed HTTP unit tests | **Not yet live verified** |
| **TikTok** | OAuth 2.0 PKCE (`S256`) + refresh | Video (Inbox upload & Direct Post) | Mandatory `queryCreatorInfo()` preflight; caption limit enforced; disclosure fields & manual fallback for unaudited apps | Stubbed HTTP unit tests | **Not yet live verified** |
| **YouTube** | Google OAuth 2.0 PKCE (`S256`) + refresh | Standard Video & Shorts (resumable upload) | Channel discovery, visibility, `madeForKids`, Shorts 9:16/duration checks, quota diagnostics | Stubbed HTTP unit tests | **Not yet live verified** |
| **Mock Provider** | Local only (clearly badged `Mock provider · testing only`) | Simulated Pin publishing | Explicit testing separation | Tested E2E in self-test & Fastify worker | **Verified locally (Mock)** |

---

## 6. AI Providers, ComfyUI, and Outbound/Inbound MCP

### AI Providers (`AIProviders.swift`, `PostCopy.swift`, `CommandPanel.swift`)
- Live model discovery (`discoverAIModels`) for OpenAI/OpenAI-compatible `/v1/models`, Ollama `/api/tags`, Gemini `/v1beta/models`, and curated Anthropic models.
- Distinct HTTP 401 vs. 403 error classification, bounded retry with `Retry-After` on 429/502/503/504, `AIError.cancelled`, reasoning/cached token tracking (`AIUsage`), and DALL-E 3/2 vs. `gpt-image-1` parameter handling.
- Added `"caption"` limit lookup in `PostCopyGenerator.limits(_:)` enforcing Instagram & TikTok 2,200-char limits, plus post-hashtag truncation.
- Fixed `CommandPanel` so re-planning always resets `allowApproval = false`, eliminates duplicate post creation when plans emit both `create_posts` and `schedule_posts`, and scopes `generate_copy`/`approve_posts` strictly to the current plan's posts.

### ComfyUI (`ComfyUI.swift`, `AIStudioView.swift`)
- Multi-server `ComfyServerProfile` support, expanded node discovery (Flux, `SamplerCustomAdvanced`, `RandomNoise`, `EmptyWanLatentVideo`, `LoadImage`, music seed, FPS), and `referenceAssetID` upload handoff from Media Library.
- Pre-submission workflow validation (`validateWorkflow(_:)` via `/object_info`) reporting missing nodes or models without auto-installing anything.
- Job-scoped cancellation (`stop(promptID:)` checks `/queue` and refuses to call server-wide `/interrupt` when a different job is executing), restart recovery via persisted `remoteJobID` + `jobStatus(promptID:)`, resilient polling, and structured provenance JSON on `AIJob`.

### Outbound Creative MCP (`MCPClient.swift`, `OutboundMCPView.swift`)
- Built controlled Outbound MCP client supporting stdio and HTTP JSON-RPC transports for external creative tools (e.g., ArtCraft or custom servers).
- Enforces per-tool allow-lists, workspace path restrictions, explicit user approval prompts, timeouts, secret redaction, and `untrusted = true` result framing before importing output files into the Media Library.

### Hardened Inbound MCP (`AgentMCP.swift`, `AgentInbox.swift`, `AgentTools.swift`, `MCPSession.swift`, `AppModel+Agent.swift`)
- Expanded to **17 tools** (`list_workspaces`, `list_media`, `list_accounts`, `list_posts`, `list_campaigns`, `list_templates`, `list_platforms`, `list_boards`, `inspect_account_capabilities`, `validate_posts`, `inspect_schedule_availability`, `search_media`, `get_request_status`, plus queued write intents `import_media`, `create_posts`, `update_media`, `create_campaign_draft`).
- Enforced `0700`/`0600` inbox permissions, malformed-file `Quarantine/`, strict JSON-RPC `-32600` validation, 2 MB line limit, and symlink/FIFO/directory/2 GB validation in `validatePath`.
- Added re-entrancy locking (`AgentInboxGate`) and crash-safe `agentRequestID` idempotency so replaying an already-applied request after a crash creates zero duplicate posts (verified in SelfTest Scenario H).

---

## 7. Publishing Engine, Background Agent & Optional Service Reconciliation

- **18-state `PublicationStatus`**: Full lifecycle (`draft`, `needsReview`, `approved`, `scheduled`, `preparing`, `uploading`, `awaitingProcessing`, `publishing`, `verifying`, `published`, `retryScheduled`, `authRequired`, `actionRequired`, `outcomeUnknown`, `failed`, `paused`, `canceled`, `manualRequired`) with lightweight-migration-safe raw values.
- **Safe retry & uncertainty handling (`PublishEngine.swift`, `PublishRunner.swift`)**: Distinguishes HTTP 403 permission/policy errors (`.permission`, does not expire account auth) from HTTP 401 (`.authExpired`), honors `Retry-After` with jitter, prevents duplicate posts on uncertain timeouts via `.outcomeUnknown`, tightened `MetaReconcile.match` (rejects empty/duplicate captions), and added a **Manual Reconciliation UI** in the Calendar/Queue inspector.
- **Explicit ownership & missed posts**: Every publication records `publishOwner` (`mac`, `remoteService`, `manual`) and `MissedPostPolicy` (`publishWhenAvailable`, `skipForReview`, `rescheduleInWindow`). `PublishRunner` enforces `publishOwner == .mac`, recovers interrupted `.publishing`/`.uploading` rows on restart, and serializes foreground vs. background `--publish-agent` execution via lock file (`com.socialforge.app.publisher.plist` updated with `ThrottleInterval: 30`).
- **Optional Fastify Service (`services/api/`)**: Added `GET /v1/capabilities` and security headers; fixed `worker.ts` `batchSize: 1` partial-batch failure bug; fixed `publisher.ts` to claim `'scheduled'` only; fixed `POST /v1/publications` rollback on enqueue failure; added UUID param 404 checks, 422 unsupported-platform rejection, session token `exp` + UUID + min-length checks (`crypto.ts`), storage path-traversal guard (`storage.ts`), and `AbortSignal.any` + pagination + MIME validation (`providers/pinterest.ts`).

---

## 8. Creative Studio, Video/Audio, Media Library & UX Improvements

- **Composer (`ComposerView.swift`)**: All 8 platforms, multi-account targeting, inline `ComposerMediaPickerSheet`, carousel/multi-media strip (`extraAssetIDs`), AI Copy generation, native previews, independent platform scheduling, TimeZone picker, Campaign UTM, YouTube/TikTok disclosure fields, and explicit account/platform confirmation dialog before Publish Now.
- **Bulk Publisher (`BulkView.swift`, `BulkSession.swift`, `CSV.swift`)**: Unlocked all 8 platforms and multi-account selection, Saved Bulk Recipes, `;`/`\t` CSV delimiter auto-detection & accurate unterminated-quote line reporting, surfaced `rowWarnings` and `PostValidator.duplicates`, fixed preview-vs-created date mismatch (`after: existingQueueEnd`), Campaign picker, Retry Failed, and Export Errors CSV.
- **Calendar & Queue (`CalendarView.swift`)**: DST-safe Month week counts and Duplicate/MultiPostEditor arithmetic, clickable `"+N"` DayTile popover, past-date & remote-owner drag protection, attention-focused Queue tabs with bulk Approve/Schedule/Retry, Account/Campaign/8-platform filters, Open in Composer, Repurpose, Ownership transfer, and Manual Reconciliation controls.
- **Creative Studio & Video (`StudioModel.swift`, `StudioMotion.swift`, `StudioView.swift`, `VideoExport.swift`)**: Stable `Design.sizeSetID` size-set grouping, video guard in Smart Resize, no double-stored `Exports/` copies, safe-zone overlay toggle, unsaved-changes confirmation, scrollable `LayersPanel`, shape border color picker, removed dead Extend/Relight placeholders, fixed video playback freeze when audio is shorter than video, removed Spacebar stealing text input, fixed `NSCursor` hover leak, clamped overlapping audio fade ramps, and fixed initial frame-0 PTS > 0 black frames.
- **Brand Kits, Campaigns, Analytics, Dashboard & Appearance**: Fixed Brand Kit tag/CTA bleed, Primary Brand Kit badge, `.sfbrand` sanitized logo import, Campaign date validation & per-platform UTM source toggle, Analytics filtered CSV export & Repurpose action, HomeView attention banners + dismissible Setup Checklist + filterable Activity feed, and replaced the leftover todo-app preview in `AppearanceSettings.swift` with a genuine SocialForge preview.

---

## 9. Workspace Isolation, Migration Safety & Data Integrity

- Lightweight-migration-safe additive SwiftData schema (`Models.swift` uses defaulted/optional properties across all new fields so existing stores open seamlessly).
- Non-destructive corruption backup in `App.swift` preserves damaged `.store` files before recovery.
- Verified 5-workspace isolation in `SelfTest` Scenario I (zero leaked posts across workspaces, clean restore on switch back).
- Verified `PublishRunner` strictly matches both `workspaceID` and `serverID` when looking up accounts.

---

## 10. Performance Benchmarks & Fixes

- **Bounded Thumbnail Pipeline (`Thumbnails.swift`)**: Added `DecodeGate(limit: 6)` bounded concurrency, in-flight task deduplication, and persistent JPEG thumbnail disk caching under `Caches/com.socialforge.app/Thumbnails` for large libraries.
- **Library Health & Missing Files (`MediaLibraryView.swift`)**: Added missing-file badges, Missing filter, and `LibraryHealthSheet` with one-click Relink.
- **Main-Actor N+1 & Render Fixes**: Eliminated disk walks inside `AutomationsView.body`, replaced N+1 variant queries in `HomeView` with pre-indexed `variantsByAsset()`, moved TopBar busy/import/variant feedback to a non-blocking status pill, and switched `BulkView` thumbnails to an adaptive grid.

---

## 11. Automated Test Results

All tests below were executed directly on this build Mac after the final code changes:

| Suite / Tool | Command | Exact Result | Duration |
|---|---|---|---|
| **Swift Unit Tests** (`SocialForgeKitTests`) | `cd apps/mac && swift test --scratch-path /tmp/socialforge-test-build` | **197/197 tests in 33 suites PASSED** (2 live-only suites intentionally skipped) | 1.171 s |
| **Grid Layout Lint** | `cd apps/mac && ./tools/grid-lint.sh` | **PASS** (`0` violations) | < 1 s |
| **Release App Build & Signing** | `cd apps/mac && ./build.sh` | **PASS** (`~/Applications/SocialForge.app` signed with Apple Development) | 53.76 s |
| **In-App E2E Self-Test** | `cd apps/mac && ./tools/selftest.sh` | **SELFTEST PASS 89 checks** (Scenarios A, D, E, H, I + background agent lock handoff) | ~35 s |
| **UI Snapshots (Light & Dark)** | `cd apps/mac && ./tools/snap.sh` | **38/38 PNGs captured** (13 pages + 6 Settings tabs × light & dark) | ~20 s |
| **Layout Probe Verification** | `cd apps/mac && swift tools/check-layout.swift /tmp/SocialForge-shots/*-layout.json` | **38/38 PASS** (`home-dark` & `home-light`: 4 probes in 1 area) | < 1 s |
| **Fastify API Typecheck** | `cd services/api && npm run typecheck` | **PASS** (0 errors) | ~2 s |
| **Fastify API & Worker Integration** | `cd services/api && npm test` | **23/23 tests in 3 suites PASSED** (throwaway Postgres cluster) | 41.8 s |
| **Platform Spec Sync** | `python3 tools/gen-spec.py` | **PASS** (embedded Swift specs match `spec/platforms/*.json`) | < 1 s |
| **Secret Scan** | `git diff \| grep -iE '(AKIA\|sk-proj-\|AIza\|PRIVATE KEY)'` | **SECRET_SCAN_CLEAN** | < 1 s |

---

## 12. Manual & Live Verification Still Required

The following items require real external accounts, Apple Developer credentials, or interactive macOS system permissions and were intentionally **not** simulated or claimed as live-verified:

1. **Live Social Platform OAuth & Publishing (All 8 Platforms)**: Run each platform's Setup Wizard in **Connections** with real developer app credentials (starting with sandbox/test accounts) and verify live OAuth callback, token refresh, media upload, and test post creation.
2. **Live Public Media Storage (S3 / Cloudflare R2)**: Enter a real R2/S3 bucket in **Connections › Media Storage** and click **Verify Connection** to confirm end-to-end PUT/GET/Content-Type/DELETE against a public bucket.
3. **Live AI & ComfyUI Servers**: Enter real OpenAI/Anthropic/Gemini keys or connect a running Ollama, LM Studio, or ComfyUI instance to verify live model discovery and generation.
4. **SMAppService Login Items Approval**: Enable "Publish while SocialForge is closed" in Connections › Publishing Infrastructure and approve SocialForge in **System Settings › General › Login Items**.
5. **Developer ID Notarization & Auto-Update**: Run `NOTARY_PROFILE=<profile> tools/release.sh` with a Developer ID Application certificate to produce a notarized universal zip and verify in-app update relaunch.

---

## 13. Known Limitations & Honest Status

- All 8 social platform adapters remain `liveVerified: false` until live-tested with real developer credentials.
- `services/api/` supports Pinterest and Mock remote publishing (advertised honestly via `GET /v1/capabilities`); the other 7 platforms publish directly from the Mac app.
- On-Mac publishing posts while the Mac is awake (or catches up on wake per each post's `MissedPostPolicy`).
- Social platform engagement metrics (impressions, clicks, saves) are not fetched from remote APIs yet; Analytics honestly reports local production, publishing, and AI usage metrics with unavailable states clearly labeled.
- No separate XCUITest target exists yet; UI flows are covered by the 89-check in-app self-test, 38 light/dark snapshots, `grid-lint.sh`, and `check-layout.swift`.

---

## 14. Summary of Files Created and Modified

- **New Modules (5 files)**:
  - `apps/mac/Sources/SocialForgeKit/Connections.swift` — Unified connection model, 13-state lifecycle, PKCE (`S256`), `TokenLifecycleManager`, `DiagnosticRedactor`.
  - `apps/mac/Sources/SocialForgeKit/PlatformAdapters.swift` — Official adapters for LinkedIn, X, TikTok, and YouTube.
  - `apps/mac/Sources/SocialForgeKit/Agent/MCPClient.swift` — Controlled Outbound Creative MCP client (stdio + HTTP, allow-list, path guard).
  - `apps/mac/Sources/SocialForge/OutboundMCPView.swift` — Outbound MCP store and UI inside Connections › Automation & Agents.
  - `apps/mac/Tests/SocialForgeKitTests/ConnectionsAndAdaptersTests.swift` — Unit tests for PKCE, single-flight token refresh, redaction, S3 verification, and all platform adapters.
- **Modified Files (84 files)**:
  - `apps/mac/Sources/SocialForgeKit/`: `PublishEngine.swift`, `MetaPublishing.swift`, `PublicMedia.swift`, `PlatformSpec.swift`, `PlatformKeys.swift`, `Generated/PlatformSpecData.swift`, `AI/AIProviders.swift`, `AI/PostCopy.swift`, `ComfyUI.swift`, `Agent/AgentInbox.swift`, `Agent/AgentTools.swift`, `Agent/MCPSession.swift`, `CSV.swift`, `MediaImport.swift`, `Analytics.swift`, `BackendClient.swift`, `Updater.swift`, `VideoExport.swift`.
  - `apps/mac/Sources/SocialForge/`: `App.swift`, `Models.swift`, `AppModel.swift`, `AppModel+Agent.swift`, `AppModel+UI.swift`, `PublishRunner.swift`, `OnMacPublishing.swift`, `MetaOnMac.swift`, `MetaSettingsView.swift`, `BulkSession.swift`, `CommandPanel.swift`, `ContentView.swift`, `SettingsView.swift`, `AgentMCP.swift`, `StudioModel.swift`, `StudioMotion.swift`, `Thumbnails.swift`, `Updater.swift`, `WelcomeSheet.swift`, `SelfTest.swift`, `UI/AppearanceSettings.swift`, and all 12 page views under `Pages/`.
  - `services/api/`: `src/app.ts`, `src/crypto.ts`, `src/storage.ts`, `src/worker.ts`, `src/publisher.ts`, `src/spec.ts`, `src/providers/pinterest.ts`, `test/api.test.ts`.
  - `spec/platforms/*.json` (all 8 platforms), `site/index.html`, `apps/mac/LaunchAgents/com.socialforge.app.publisher.plist`, `apps/mac/build.sh`, `apps/mac/tools/{selftest.sh,snap.sh,check-layout.swift}`, `tools/{package.sh,release.sh}`, `README.md`, `docs/{ARCHITECTURE.md,CAPABILITIES.md,META_SETUP.md,ROADMAP.md,TEST_REPORT.md}`.

---

## 15. Release Readiness & Operational Runbook

1. **Local verification before cutting a release**:
   ```bash
   cd apps/mac
   swift test
   ./tools/grid-lint.sh
   ./build.sh
   ./tools/selftest.sh
   ./tools/snap.sh
   swift tools/check-layout.swift /tmp/SocialForge-shots/*-layout.json
   ```
   ```bash
   cd services/api
   npm run typecheck && npm test
   ```
2. **Spec sync check**: Run `python3 tools/gen-spec.py` after any change under `spec/platforms/*.json`.
3. **Notarized release**: Bump `CFBundleShortVersionString` in `apps/mac/Info.plist.in`, then run `NOTARY_PROFILE=<profile> tools/release.sh` (use `--draft` to build/upload without publishing GitHub Pages or making the release public). `tools/package.sh` verifies `--deep --strict` signatures and rebuilds `Assets.car` cleanly.

---

## 16. Recommended Next Milestones

1. **Live Provider Certification Pass**: Execute real OAuth + sandbox/test posts across all 8 platforms and flip `liveVerified` flags only after confirmed production/sandbox receipts.
2. **Optional Remote Service Multi-Platform Parity**: Extend `services/api/` beyond Pinterest to cover Meta, LinkedIn, X, TikTok, and YouTube for users wanting asleep-Mac scheduling across all channels.
3. **Provider Analytics Sync**: Add opt-in read-only metrics refresh for published posts where platform scopes permit.
4. **XCUITest & 5,000-Asset Profiling**: Add an XcodeGen XCUITest target, VoiceOver/keyboard-only accessibility audit, and live Instruments profiling against a 5,000-asset media library.
