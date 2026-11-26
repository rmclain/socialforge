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

What works today, in the warm dark and light macOS design language:
- **Overview Dashboard**, **Calendar & Publishing Queue** (month, week, day, attention-focused queue tabs, DST-safe drag-to-reschedule, manual reconciliation for unknown outcomes), **Bulk Publisher** (images + CSV/TSV/semicolon → matched, DST-safe schedule by interval, hours, or picked dates; multi-account & multi-platform; saved recipes; AI copy; approval; schedule; retry failed; export errors CSV)
- **Unified Connections Hub**: Social Accounts (all 8 platforms: Pinterest, Facebook Pages, Instagram via Facebook Login or Instagram Business Login, Threads, LinkedIn, X, TikTok, YouTube), AI Providers (OpenAI, Anthropic, Google Gemini, OpenAI-compatible/Ollama/LM Studio, ComfyUI), Media Storage (S3 / Cloudflare R2), Automation & Agents (Inbound MCP + Controlled External Creative MCP), and Publishing Infrastructure — with guided setup wizards and sanitized diagnostics
- **Composer**: one canonical post adapted across all 8 platforms with per-platform previews, carousel multi-media picker, AI copy generation, campaign UTM tagging, TikTok/YouTube disclosure fields, and explicit Publish Now confirmation
- **Social Platform Adapters**: official API adapters implemented and unit-tested with stubbed HTTP for all 8 platforms (Pinterest, Facebook Pages, Instagram, Threads, LinkedIn, X, TikTok, YouTube), plus a clearly labeled local **Mock Pinterest** account for offline testing. None of the 8 live third-party APIs has been live-verified yet (`liveVerified: false`); see [docs/CAPABILITIES.md](docs/CAPABILITIES.md) and [docs/META_SETUP.md](docs/META_SETUP.md)
- **Media Library** for photos, video clips, and music (MP3, M4A, WAV, AIFF, FLAC), with collections, tags, variants, bounded disk+memory thumbnail cache for large libraries, missing-file badges, and Library Health & Relink
- **Creative Studio** with layers, real-font Core Text rendering (Instrument Serif bundled), smart resize across platform sizes, safe-zone overlay, on-device Vision/Core Image transforms, and video/audio timeline with MP4 export (H.264, AAC, 30 fps)
- **Editable Brand Templates & Brand Kits** with primary brand kit selection, logo, palette, fonts, voice, CTAs, hashtags, `.sfbrand` import/export
- **AI Studio**: Image, Video, and Music modes on your ComfyUI (with pre-submit workflow node/model validation, Flux/LoadImage support, job-scoped cancellation, and restart-recovery job tracking), plus BYOK cloud/local AI providers with live model discovery and a ⌘J typed command assistant
- **Automations** (workspace-isolated folder, tag, weekly, manual → resize, template, AI copy, queue for review; blocks managed storage recursion; never auto-publishes), **Campaigns** with per-platform UTM links, **Analytics** from real data with sanitized CSV export
- **Inbound & Outbound MCP**: hardened `SocialForge --mcp` stdio server (17 tools including campaigns, templates, platforms, account capabilities, validation, schedule availability; crash-safe idempotency; symlink/FIFO protection; quarantine for corrupt files; never approves or publishes) plus a controlled Outbound MCP client for user-configured creative servers (stdio/HTTP, tool allow-lists, workspace path restrictions, untrusted output handling)

**Limit of a Mac-only app:** nothing posts while the Mac is asleep or off.
Posts that came due follow your Missed-Post policy (publish on wake, reschedule, or require review). For always-on publishing while your Mac sleeps, enable the optional service under `services/api/`.

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
   board, set the cadence, Create Posts, review, Approve, Activate. The CSV has one
   row per image: `filename` (matched to the image's file name, any extension) and
   `url` (where the post links), plus optional `title`, `description`, and `alt_text`.
   Start from [docs/samples/media-links.csv](docs/samples/media-links.csv), or
   **File > Save Sample CSV…** in the app.
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

## Use it from Claude Code, Codex, or another agent (MCP)

`SocialForge --mcp` is an MCP server on stdio. Add it once (the exact commands, with your path, are in Settings > Agents, or Assistant > Connect Claude or Codex…):

```sh
claude mcp add --scope user socialforge -- ~/Applications/SocialForge.app/Contents/MacOS/SocialForge --mcp
codex mcp add socialforge -- ~/Applications/SocialForge.app/Contents/MacOS/SocialForge --mcp
```

Tools: `list_brands`, `list_accounts`, `list_media`, `search_media`, `list_posts`, `list_campaigns`, `list_templates`, `list_platforms`, `list_boards`, `inspect_account_capabilities`, `validate_posts`, `inspect_schedule_availability`, `get_request_status` read the library;
`import_media`, `create_posts`, `create_campaign_draft`, `update_media` are queued in `~/Library/Application Support/SocialForge/Agent Inbox` (with `0700`/`0600` permissions and crash-safe idempotency)
and applied by the app while it is open (or at its next launch). Posts an agent makes always wait in Needs Review;
agents cannot approve or publish.

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
