# Roadmap

## Completed

- **M1 Foundation**: 13-page sidebar shell with inspector, brand workspaces, SwiftData store, warm orange design system (`UI/DS.swift`, `UI/Grid.swift`, bundled Instrument Serif), and light/dark appearances.
- **M2 Media and creative**: Local-first media library (drag-and-drop, folders, CSV alongside, SHA-256 deduplication, bounded disk-cached thumbnails, missing-file health check & relink), Creative Studio (layered documents, real-font text, editable brand-bound templates, stable `sizeSetID` size sets, safe-zone overlays, video/audio timeline & export), and Brand Kits (`.sfbrand` export/import, primary brand kit).
- **M3–M6 Multi-platform, Unified Connections, AI & MCP (2026-11-26)**:
  - **Unified Connections hub & wizards**: 5-category Connections page (`Social Accounts`, `AI Providers`, `Media Storage`, `Automation & Agents`, `Publishing Infrastructure`), step-by-step setup wizards, 13-state connection health lifecycle, dynamic account capability layer, shared credential profiles across brand workspaces, and secret-redacted Connection Diagnostics.
  - **Hardened OAuth, Keychain & Token Lifecycle**: RFC 7636 PKCE (`S256`), strict `state` & redirect URI verification, hardened IPv4/IPv6 loopback listener, `TokenLifecycleManager` single-flight refresh deduplication, Keychain status checks & per-profile credential scoping, and hardened `site/index.html` OAuth redirect page (`no-referrer`, URL history stripping).
  - **All 8 social platform adapters**: Official API adapters in `SocialForgeKit` for Pinterest (OAuth + refresh + board sections + Video Pins), Facebook Pages (text, photo, multi-photo, link, Reel), Instagram (Facebook-linked Professional & direct Instagram Business Login, photo, carousel, Reel, 24h quota checks), Threads (text, photo, video, carousel, token refresh), LinkedIn (member & organization pages), X (PKCE + v2 chunked media upload + weighted character counting), TikTok (PKCE + `queryCreatorInfo` + Inbox & Direct Post), and YouTube (PKCE + resumable upload + Shorts/visibility/disclosures).
  - **Production-grade Publishing Engine & Reconciled Optional Service**: 18-state publishing lifecycle, approval-hash invalidation on edit, durable `PublishAttempt` logs, crash recovery, jitter + `Retry-After` + 403 vs 401 distinction, manual reconciliation UI for `.outcomeUnknown`, explicit per-post `publishOwner` & `MissedPostPolicy`, and hardened optional Fastify API (`GET /v1/capabilities`, session expiry, UUID validation, transactional rollback, tenant isolation).
  - **AI Providers, ComfyUI & Outbound/Inbound MCP**: Live model discovery, HTTPS enforcement for remote endpoints, prompt-injection hardening, ComfyUI workflow validation (`/object_info`), job-scoped cancellation, restart recovery & `LoadImage` handoff, Outbound Creative MCP client (stdio + HTTP, allow-list, approval prompts, untrusted output handling), and hardened 17-tool Inbound MCP server with crash-safe idempotency and quarantine.
  - **Cohesive workflows**: Multi-platform Composer & Bulk Publisher (all 8 platforms, saved recipes, campaign UTM, retry failed, error CSV export), DST-safe Calendar & attention-focused Queue, hardened Automations (managed-folder guard, workspace isolation, dedup fingerprints), Analytics CSV formula sanitization, and contextual Overview setup checklist.

## Honest verification status & remaining limitations

- **Live platform APIs**: All 8 social platform adapters, S3/R2 public media hosting, AI cloud/local providers, and ComfyUI are built against official documentation and verified with automated HTTP-stubbed tests (`197` Swift unit tests, `89` in-app self-test checks, `23` Fastify API tests). **None of the 8 social platforms have been live-verified with real provider credentials or real live posts yet.** Every platform is explicitly labeled `Adapter built · unverified live` in the UI until verified with real credentials.
- **Background publisher (`SMAppService`)**: The launch agent binary mode (`SocialForge --publish-agent --once`) and lock handoff are verified end-to-end in the self-test, but `SMAppService` registration in macOS System Settings › Login Items requires interactive user approval on a real Mac.
- **Notarized distribution**: Release scripts (`tools/package.sh`, `tools/release.sh`) support universal builds, hardened runtime, Developer ID signing, and `notarytool` notarization, and refuse to claim notarization without a Developer ID Application certificate and `NOTARY_PROFILE`.
- **Mac-only wake requirement**: On-Mac publishing posts while the Mac is awake (and catches up on wake according to each post's `MissedPostPolicy`). Publishing while the Mac is asleep or offline requires the optional self-hosted Fastify service in `services/api/`.
- **Optional service multi-platform coverage**: `services/api/` currently supports Pinterest (plus the labeled mock provider) and advertises its exact capabilities via `GET /v1/capabilities`; other platforms publish directly from the Mac app.
- **Screenshots without Screen Recording permission**: `tools/snap.sh` falls back to window rendering when the terminal lacks Screen Recording permission; granting Screen Recording produces full-fidelity window chrome captures.

## Next milestones

| Milestone | Scope |
|---|---|
| Live Provider Certification | Run live OAuth, media upload, and test posts across all 8 platforms with real developer apps (sandbox/test accounts) and update `liveVerified` flags only after observed success |
| Remote Service Multi-Platform Parity | Extend `services/api/` beyond Pinterest to support Meta, LinkedIn, X, TikTok, and YouTube remote publishing when users want asleep-Mac scheduling for all platforms |
| Provider Engagement Metrics Sync | Add opt-in read-only metrics ingestion for published posts where platform APIs grant analytics scopes |
| Automated UI Test Target & Accessibility Audit | Add an XCUITest target, VoiceOver/keyboard-only audit pass, and 5,000-asset profiling benchmarks on real media libraries |
| Notarized Public Release | Sign and notarize a universal Developer ID build via `tools/release.sh` and verify auto-update end-to-end |
