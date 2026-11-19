# Architecture

SocialForge is a standalone Mac app. Planning, media, design, and publishing
all happen on the Mac. An optional Node service exists for one case a Mac
cannot cover: posting while the Mac is asleep.

## Pieces

```
SocialForge.app
┌─────────────────────────────────────────────────────────────┐
│ SwiftUI app (Sources/SocialForge)                           │
│   sidebar · workspace · inspector · menus                   │
│   PublishRunner: publishes due posts while the app is open  │
│ SocialForgeKit (no UI, unit tested)                         │
│   CSV, matching, schedules, validation, transforms,         │
│   design documents, PublishEngine, PinterestTarget, mock    │
│ SwiftData store + Library folder (Application Support)      │
│ Contents/Library/LaunchAgents/…publisher.plist              │
│   → the same binary with --publish-agent, while app closed  │
└─────────────────────────────────────────────────────────────┘
        │ HTTPS (Pinterest API v5, tokens from the Keychain)
        ▼
   Pinterest            (optional) services/api: Fastify + PostgreSQL + pg-boss
```

`spec/platforms/*.json` is the single source for limits and capabilities.
`tools/gen-spec.py` embeds it in the app; a unit test fails if the copy drifts.
The optional service reads the same files and enforces the same rules.

## Mac app

| Area | Where |
|---|---|
| Entry (app or agent), window, menus, store | `Sources/SocialForge/App.swift` |
| SwiftData models (workspace-scoped) | `Sources/SocialForge/Models.swift` |
| App state | `AppModel.swift`, `BulkSession.swift`, `StudioModel.swift` |
| On-Mac publishing | `PublishRunner.swift` (runner, lock, agent), `OnMacPublishing.swift` (mode, accounts, OAuth loopback, SMAppService) |
| Pages and inspectors | `Sources/SocialForge/Pages/` |
| Logic without UI | `Sources/SocialForgeKit/` |
| Snapshot, seed, self-test modes | `Snapshot.swift`, `SeedData.swift`, `SelfTest.swift` |

Data model: `Workspace`, `MediaAsset` (original), `MediaVariant` (derived),
`Publication` (one post for one account; Draft → Needs Review → Approved →
Scheduled → Publishing → Published / Failed / Paused / Canceled),
`PublishAttempt` (one row per try, never overwritten), `SocialAccount`,
`BrandKit`, `Design` (a JSON `CreativeDocument`), `ActivityEntry`. Every record
carries its workspace id.

Media: files are copied into `~/Library/Application Support/SocialForge/Library/Originals/<sha256>/`
with write-then-rename; the source is never written to. Imports hash with
bounded concurrency off the main actor; of identical files, the first in
folder order is kept and the rest are reported as duplicates. Thumbnails are
decoded at display size and cached with a memory cost limit.

Supported import formats: JPEG, PNG, HEIC/HEIF, WebP, TIFF, GIF, BMP images;
MP4 and MOV video (stored and listed; video transforms are on the roadmap).

Transforms (ImageIO + Core Graphics): one scale on both axes (never
stretched), Fill crops around a focal point, Fit pads with a background,
output in sRGB, EXIF/GPS stripped by default.

Creative documents are JSON (canvas, background, image/text/shape layers).
Text is drawn with Core Text at export using the named installed font; a
missing font blocks export rather than silently changing the layout.

Schedules: a rule (start day, local times, every N days, weekdays, skip days,
IANA time zone) expands to instants with Foundation's calendar, so 9:00 stays
9:00 local across daylight saving changes.

## Publishing on the Mac

1. **Activate** moves approved posts to Scheduled in the local store.
2. **PublishRunner** looks for posts that are Scheduled, due, and not waiting
   for a retry. It runs every 30 seconds and right after the Mac wakes. In the
   app, it starts at launch.
3. **One runner at a time.** Whoever holds `Library/publisher.lock` (an
   advisory `flock`) publishes. The app takes the lock while it is open. The
   launch agent (`SocialForge --publish-agent`, registered with
   `SMAppService.agent`) tries every 60 seconds and on wake. It publishes only
   when the app is closed, and lets go after each pass. The runner reads
   through a fresh `ModelContext`, so it sees what the other process wrote.
4. **PublishEngine** makes one attempt and decides what's next:
   - success → Published, with the Pin URL
   - `retryable` (5xx, 429, network) → back to Scheduled, retried at 1, 2, 4, 8 minutes… (5 attempts)
   - `uncertain` (timeout after sending) → the next attempt first asks the platform whether the Pin exists (by the `sf:<key>` note), and records `reconciled` instead of posting twice
   - `auth` (401/403) → the account is marked expired, and the post fails with "Reconnect"
   - `permanent` → the post fails at once
5. A post that came due while the Mac slept goes out on wake. Activity notes
   how late it was.

Adding a platform: implement `PublishTarget` (`publish`, `findExisting`,
`boards`), add its sign-in, and add `spec/platforms/<id>.json` with
`"status": "available"`.

## Data flows and privacy

| Data | Where it lives | Leaves the Mac? |
|---|---|---|
| Original media and variants | Library folder on the Mac | Only the image of each post, sent to the platform when it publishes |
| Post copy, links, times | SwiftData store on the Mac | Sent to the platform at publish time |
| Pinterest app ID and secret | Login Keychain | Only to Pinterest's token endpoint |
| Pinterest access and refresh tokens | Login Keychain | Only to Pinterest's API |
| OAuth redirect | A one-shot listener on 127.0.0.1:8085 | Never exposed beyond this Mac |
| ComfyUI address | Preferences | The test call goes only to that address; remote servers must use HTTPS |
| AI provider keys | Not used yet (milestone 5); planned for the Keychain | — |

- Imported CSV and media metadata are data, never instructions.
- The mock account is created only when you choose it, and is labeled "Mock provider · development only".
- With the optional service, approved posts and their images go to that service instead, and platform tokens live in its database (AES-256-GCM).

## Decisions

- **Mac-only by default** (your choice, 2026-11-19). The trade-off is that
  nothing posts while the Mac sleeps. The optional service covers that later.
  Docker was removed.
- **Your own Pinterest app.** Pinterest's token exchange needs a client secret,
  and a downloaded app cannot keep a shared secret private. So each user brings
  their own app ID and secret, kept in their Keychain. A shared app would need
  a small token relay (roadmap).
- **One binary, two roles.** The launch agent is the app binary with
  `--publish-agent`. It shares the code, the store, and the signature.
- **SwiftPM package, not an Xcode project** (BAMA template). Switch to XcodeGen
  when UI test targets or extensions arrive.
- **Instrument Serif** from the design is not installed, so headings use the
  system serif (New York) and templates default to Baskerville.

## Optional publishing service (services/api)

Fastify API + pg-boss worker on PostgreSQL: `/health`, `/version`, `/v1/accounts`,
`/v1/media/:sha256`, `/v1/publications` (idempotent on key, validated against
the spec), cancel, attempts. The same retry, reconciliation, and auth rules as
on the Mac. Tables are in `services/api/drizzle/0000_init.sql`. It runs with
`npm run dev:local` (private Postgres in `.data/`) or `npm start` plus
`npm run worker` with a `.env`.
