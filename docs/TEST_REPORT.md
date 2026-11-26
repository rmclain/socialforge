# Test Report

## 2026-11-26 — Production Readiness, Unified Connections & Multi-Platform Pass

All checks below were executed on the build Mac (`arm64e-apple-macos`, Swift 6.2/6.4.2, Node.js, Homebrew PostgreSQL) after the final edits.

### Mac App (`apps/mac`)

| Check | Command | Result |
|---|---|---|
| Swift Unit Tests (`SocialForgeKitTests`) | `cd apps/mac && swift test --scratch-path /tmp/socialforge-test-build` | **197 passed in 33 suites** (1.171 s; 2 live-only suites skipped) |
| Grid Layout Lint | `cd apps/mac && ./tools/grid-lint.sh` | **PASS** (0 off-grid lines) |
| Release Build & Sign | `cd apps/mac && ./build.sh` | **PASS** (53.76 s; `~/Applications/SocialForge.app` signed with Apple Development) |
| In-App E2E Self-Test | `cd apps/mac && ./tools/selftest.sh` | **SELFTEST PASS 89 checks** |
| UI Snapshots | `cd apps/mac && ./tools/snap.sh` | **38/38 PNGs captured** (13 pages + 6 Settings tabs, light and dark) |
| Layout Probes | `cd apps/mac && swift tools/check-layout.swift /tmp/SocialForge-shots/*-layout.json` | **38/38 PASS** (`home-dark` & `home-light`: 4 probes in 1 area) |
| Platform Spec Sync | `python3 tools/gen-spec.py` | **PASS** |
| Secret Scan | `git diff` secret regex check | **CLEAN** |

**What the new unit tests cover** (in addition to all earlier suites):
- Unified connections lifecycle, RFC 7636 PKCE (`S256`), single-flight `TokenLifecycleManager` concurrent refresh deduplication, and `DiagnosticRedactor.sanitize` secret scrubbing.
- Official HTTP-stubbed platform adapters: Pinterest (refresh token, Video Pins, paginated board sections), Meta (Facebook Pages text/photo/Reel, Instagram photo+S3 cleanup & Reel, Threads text/media, strict `OAuthRedirect` state/URI checks, strict `MetaReconcile` rejecting empty/duplicate captions), LinkedIn (member/org image post), X (v2 chunked media upload + weighted character length), TikTok (`queryCreatorInfo` + Inbox upload), YouTube (resumable upload), and S3/R2 full round-trip `verifyConnection()`.
- AI providers (`discoverAIModels`, 401 vs 403, HTTPS transport enforcement, redaction), ComfyUI (`validateWorkflow`, job-scoped cancellation that preserves other running jobs, `LoadImage`), and Outbound/Inbound MCP (tool allow-list, workspace path restrictions, symlink/special-file rejection, JSON-RPC `-32600`).

**What the 89-check in-app self-test covers** (on an isolated `/tmp` SwiftData store):
- All original workflows (workspaces, 30-image + CSV import with duplicate handling, originals preserved, Pinterest variants, validation, approval, rescheduling, Studio undo/export/templates/brand restyle/smart resize/size sets, calendar double-click, analytics, welcome sheet, brand folder routing, media deletion protection, Inbound MCP queue & apply, on-Mac publishing Scenario A + background `--publish-agent` lock handoff).
- New Scenario D/E/H/I checks: editing an approved post invalidates approval back to Needs Review; manual reconciliation confirms `.outcomeUnknown` as published; Inbound MCP crash-recovery replay creates zero duplicate posts; automation blocks watching SocialForge's managed library folder; 5 isolated brand workspaces have zero cross-workspace post leakage.

### Optional Publishing Service (`services/api`)

| Check | Command | Result |
|---|---|---|
| TypeScript Typecheck | `cd services/api && npm run typecheck` | **PASS** (0 errors) |
| API & Worker Integration Tests | `cd services/api && npm test` | **23/23 passed in 3 suites** (41.8 s, throwaway Postgres cluster) |

New API tests verify `GET /v1/capabilities` + security headers, 404 (not 500) on non-UUID publication IDs, session token expiry/malformed rejection, and cross-workspace tenant isolation.

### Not Verified Live

- **Live social platform APIs (all 8 platforms)**: Tested with stubbed HTTP only; no real provider credentials or live posts were executed.
- **Live AI providers, ComfyUI, and S3/R2 storage**: Tested with stubbed HTTP only.
- **`SMAppService` Login Items registration**: Launch agent binary mode (`--publish-agent --once`) and lock handoff are verified in `selftest.sh`; System Settings Login Items registration requires interactive approval.
- **Developer ID notarization**: Requires a Developer ID Application certificate and `NOTARY_PROFILE`.

---

## Earlier History (2026-11-19 Baseline)

- **Second session**: `swift test` 101 passed, `selftest.sh` 42/42 passed, `grid-lint.sh` PASS, 36/36 layout probes PASS.
- **First session**: `swift test` 51 passed (11 suites), `selftest.sh` 33/33 passed, `services/api` 21/21 passed.
