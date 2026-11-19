# Test report: 2026-11-19

## Second session (design pass and feature round)

| Check | Result |
|---|---|
| `swift test` | **101 passed** (Kit: brand templates, smart resize, schedules by hours and picked dates, image ops, AI providers and copy with stubbed HTTP, ComfyUI client and workflows, analytics, UTM, command plans) |
| `tools/selftest.sh` | **42/42**: adds built-in templates, brand-bound colors restyling a design, Save as template and save in place, applying a template to 3 images, smart resize, analytics counts, assistant time parsing |
| `tools/grid-lint.sh` | PASS |
| Layout probes | 36/36 PASS |
| Snapshots | 36 PNGs reviewed against WebKit renders of the six design views (`design/SocialForge v2.dc.html`): dashboard, calendar, composer (canvas → Creative Studio), media, AI studio, bulk |

Not verified live: AI providers, ComfyUI, and Pinterest (no keys or servers on the build Mac).

## First session

All results below are from runs on the build Mac (macOS 27.0.1, Swift 6.4.2,
Node 26.13, PostgreSQL 14.24 from Homebrew).

## Mac app

| Check | Command | Result |
|---|---|---|
| Build | `apps/mac/build.sh` | Built, signed (Apple Development), installed; no warnings |
| Unit tests (Swift Testing) | `swift test` | **51 passed**, 11 suites |
| In-app self-test | `tools/selftest.sh` | **33/33 passed**, twice in a row |
| Self-test against the optional service | `APP_BACKEND_URL=… tools/selftest.sh` (earlier build) | 27/27 passed: activated 30, re-activating sent 0, sync consistent |
| Grid lint | `tools/grid-lint.sh` | PASS |
| Layout probes | `swift tools/check-layout.swift /tmp/SocialForge-shots/*-layout.json` | 36/36 PASS |
| Snapshots | `tools/snap.sh` | 36 PNGs (13 pages and 5 Settings tabs, light and dark), reviewed |

What the unit tests cover: sidebar pages; CSV parsing (quotes, newlines, BOM,
short rows, unterminated quotes); matching by filename, SKU, asset id, and row
order, with ambiguous matches in both directions; schedules (30 daily at 9:00,
New York fall-back and spring-forward, a nonexistent 2:30 AM, weekdays only,
skip days, several per day, every other day, appending after a queue);
platform registry drift against `spec/platforms`; text, link, board, format,
size, and aspect validation; duplicate warnings; account capabilities
(scenario E); sync merge (scenario D); media scan, import, hashing, and
duplicates with originals unchanged; first-in-folder-order wins (5 runs);
Fill and Fit layout without stretching; Pinterest variants at exactly
1000 × 1500 with EXIF removed (scenario C); design JSON round trip, template
variables, rendering with real text, missing fonts blocking export; publish
engine backoff, status classification, success, retries up to the limit,
reconciliation after an uncertain timeout (one Pin, not two), auth expiry,
permanent failure; Pinterest authorize URL.

What the self-test covers (the app's real code on a /tmp store): workspace
creation; importing 30 images and a CSV (one duplicate skipped, originals
unchanged); 5 Pinterest variants; all 30 matched to rows; 30 posts at 9:00 New
York time, one per day, with CSV links and variants; validation (a 120-character
title, a missing `pins:write`); approval; rescheduling; Studio undo and PNG
export into the library. On-Mac publishing (scenario A, locally): 6 due posts
published by the app, each exactly once, with attempts recorded, and a second
pass publishing nothing. The background publisher: the agent
(`SocialForge --publish-agent --once`) stands by while the app holds the lock,
then publishes the 4 due posts once the lock is free (10 Pins, no duplicates).

## Optional publishing service

| Check | Command | Result |
|---|---|---|
| Typecheck | `npm run typecheck` (TypeScript 7) | Clean |
| API and worker tests | `npm test` (throwaway Postgres cluster per run) | **21 passed** |
| Live run | `npm run dev:local` | `/health` 200 `{"status":"ok","db":"ok"}`, `/version` 200, `/v1/accounts` without a token 401; stopped afterwards with its Postgres |
| Log redaction | grep the run log | No `Authorization` header or bearer token logged |

The worker tests cover: scenario A (30 Pins, each published once, results
synced back), not publishing early, 503 retry then success, reconciliation
after a timeout, permanent failure, giving up after the retry limit, a canceled
post never publishing, and a 401 marking the account expired and refusing new
posts.

## Not verified

- **Pinterest live API**: no Pinterest app credentials, so no real Pin was created. Mock only.
- **Registering the launch agent with SMAppService**: not done on the build Mac, because it changes your Login Items and needs your approval. The agent mode itself is tested directly.
- **Docker Compose**: removed at your request; never run.
- Snapshots used the fallback capture (no Screen Recording permission), which leaves sidebars and grouped-form backgrounds blank.
