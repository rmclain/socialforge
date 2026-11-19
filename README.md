# SocialForge

A standalone native macOS studio for preparing, reviewing, and scheduling
social posts in bulk: branded images and videos, with images, clips, and music
generated on your own ComfyUI. It publishes from the Mac itself: while the app is open,
and, with the background publisher turned on, while it is closed. No Docker,
no server.

- **apps/mac/**: the Mac app (Swift 6, SwiftUI, SwiftData), built with BAMA's template
- **spec/platforms/**: platform capabilities and media rules (embedded in the app)
- **services/api/**: an *optional* publishing service (Node, Fastify, PostgreSQL, pg-boss) for posting while the Mac sleeps
- **site/**: the GitHub Page (https://rmclain.github.io/socialforge/)
- **comfyui/workflows/**: starter ComfyUI workflows (image, image with text, vertical and square video, music) for AI Studio
- **docs/**: brief, stories, architecture, capability matrix, roadmap, test report

What works today, in the look of the Claude Design file (warm dark and light):
- **Dashboard**, **Calendar** (month, week, day, queue, drag to reschedule), **Bulk Publisher** (images + CSV → matched, DST-safe schedule by interval, hours, or picked dates; AI titles and descriptions; approval; schedule)
- **Composer**: one post, per-platform versions and previews. Pinterest, Facebook Pages, Instagram (professional accounts), and Threads publish from this Mac with your own developer apps; LinkedIn and X are drafts
- **Facebook, Instagram, Threads**: text, photos, and Reels with your own Meta apps, tokens in the Keychain; Instagram photos and Threads media use an optional S3-compatible bucket (such as Cloudflare R2). Built from Meta's docs and **not yet verified live**. Setup: [docs/META_SETUP.md](docs/META_SETUP.md)
- **Media Library** for photos, video clips, and music (MP3, M4A, WAV, AIFF, FLAC), with collections, tags, variants, batch actions, and a player
- **Creative Studio** with layers, real-font text, smart resize to every platform size, on-device background removal, smart crop, upscale, and brand toning; drop photos, clips, and music from Finder onto the canvas
- **Video designs**: clips and music tracks on the canvas, a timeline with timed layers, trims, loops, fades, and volume, a per-platform fit check, and MP4 export (H.264, AAC, 30 fps) for TikTok, Reels, Shorts, Pinterest, Facebook, X, and LinkedIn
- **TikTok and YouTube Shorts**: export only (SocialForge makes the video at the right size; you upload it)
- **Editable brand templates**: text, colors, fonts, and logo bound to the brand kit; save, edit, duplicate, import/export; apply to many images at once
- **Brand Kits** with logo, palette, fonts, voice, CTAs, hashtags, import/export
- **AI Studio**: Image, Video, and Music modes on your ComfyUI (with a Text in image option for workflows that draw words), plus OpenAI-compatible image generation; five starter workflows ship in the app and were run end to end on a real ComfyUI server; bring-your-own-key text providers (OpenAI, Anthropic, Gemini, local), a ⌘J assistant that plans with typed, approved steps
- **Automations** (folder, tag, weekly, manual → resize, template, AI copy, queue for review), **Campaigns** with UTM links, **Analytics** from real data with CSV export
- On-Mac publishing with retries, reconciliation, and attempt history, tested end to end against a clearly labeled **mock** Pinterest account. The real Pinterest client is built
from the documented API but **has not been verified live**: that needs your own
Pinterest app. See [docs/CAPABILITIES.md](docs/CAPABILITIES.md).

**Limit of a Mac-only app:** nothing posts while the Mac is asleep or off.
Posts that came due go out when it wakes, marked late in Activity.

## Requirements

- macOS 26 or later, Xcode 27 command line tools (Swift 6.2+)
- Only for the optional service: Node.js 24+ and PostgreSQL 14+ (`brew install postgresql`)

## Run it

```bash
cd apps/mac
./build.sh --open          # builds, signs, installs ~/Applications/SocialForge.app, opens it
```

Then:

1. **Social Accounts > Connect Account > Mock Pinterest (testing only)** to try the
   whole flow, or set up **Settings > Publishing > Your Pinterest app** (App ID and
   secret from developers.pinterest.com, redirect URI
   `http://127.0.0.1:8085/pinterest/callback`) and press Connect Pinterest. For
   Facebook, Instagram, and Threads, follow [docs/META_SETUP.md](docs/META_SETUP.md).
2. **Bulk Publisher**: drop a folder of images and a CSV, choose the account and a
   board, set the cadence, Create Posts, review, Approve, Activate.
3. To publish while the app is closed, turn on **Settings > Publishing > Publish
   while SocialForge is closed** and approve it in System Settings > General >
   Login Items.

## Test

```bash
cd apps/mac
swift test --scratch-path ~/Library/Developer/SocialForge/test-build   # Kit unit tests (Swift Testing)
tools/selftest.sh       # the app's real functions on a /tmp store, including the background publisher
tools/snap.sh           # light and dark screenshots of every page in /tmp/SocialForge-shots
```

Optional service:

```bash
cd services/api
npm install
npm run typecheck
npm test                # API and worker tests on a throwaway local Postgres
```

## Build

```bash
cd apps/mac && ./build.sh                 # release build, signed, installed to ~/Applications
tools/package.sh                          # universal build, Developer ID signature, notarized zip in dist/
```

## Install and update

Download the latest zip from [Releases](https://github.com/rmclain/socialforge/releases), unzip it, and drag
SocialForge to Applications. Installed copies check GitHub releases once a day and offer an **Update**
button; the new version is verified against the same Developer ID team before it replaces the app.
See [docs/RELEASE.md](docs/RELEASE.md).

## Optional: the publishing service

Only needed if posts must go out while the Mac sleeps. It runs with plain Node
and PostgreSQL, on this Mac or any always-on host:

```bash
cd services/api
npm install
npm run dev:local       # private Postgres in .data/, worker in-process, mock provider; prints an access token
```

`/health` and `/version` answer on http://127.0.0.1:8787. In the app, choose
Settings > Publishing > Publish from > Publishing service, and paste the token.
For a real host, copy `services/api/.env.example` to `.env`, fill it in, and run
`npm start` and `npm run worker`. Never commit `.env`.

## Docs

- [Architecture, data flows, and privacy](docs/ARCHITECTURE.md)
- [Platform capability and approval matrix](docs/CAPABILITIES.md)
- [Roadmap and known limitations](docs/ROADMAP.md)
- [Test report](docs/TEST_REPORT.md)
- [Brief](docs/BRIEF.md) · [Stories](docs/STORIES.md)
