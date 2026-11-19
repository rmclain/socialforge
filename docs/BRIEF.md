# SocialForge

A native Mac studio where a small brand or agency turns a folder of product
images and a CSV into a reviewed, scheduled run of social posts that go out
on time even when the Mac is asleep.

Bundle id: `com.socialforge.app` (decided by the agent; change it if you own
a domain).

## Replaces
Spreadsheets plus Canva plus a web scheduler (Buffer, Tailwind, Later), and
one post form per image.

## Main jobs
1. Bulk publish: import images and a CSV, match them, pick a board and a
   cadence, review, approve, and let the backend publish.
2. See and adjust the schedule on a calendar (month, week, queue).
3. Prepare media: resize and crop for each platform without touching the
   originals, and lay text over images with real, editable fonts.

## Data
- Workspace: name, brand colors, voice
- MediaAsset: original file, hash, size, dimensions, tags, product URL, title, alt text
- MediaVariant: asset, preset, output file, dimensions
- SocialAccount: platform, name, granted scopes, status
- ContentItem / PlatformPost: canonical copy, then per-platform title, description, link, board
- ScheduledPublication: post, time zone, local time, UTC instant, status, attempts
- CreativeDocument: canvas size, background, layers (image, text, shape)

## Shape
Sidebar window with a center workspace and a right inspector, macOS 26 or
later. Local-first data in SwiftData. Standalone: the app publishes while
open, and a background helper (launch agent) publishes while it is closed,
as long as the Mac is awake (your choice; no Docker, no server). An optional
Node service can post while the Mac sleeps.

## System hooks
Drag and drop from Finder, a Command-K search, menu commands with shortcuts,
and later a Shortcuts action and a folder-watch automation.

## Reference
`design/SocialForge v2.dc.html` (Claude Design): the visual and layout
reference.

## Look
Its own look from the design file: dark glass sidebar, warm orange accent
`#ff8a5c`, Instrument Serif headlines, SF Pro everywhere else. Light mode
keeps the same accent and hierarchy.

## Not in version one
- Facebook, LinkedIn, X publishing (milestone 4; the connector shape is ready)
- Live AI generation and ComfyUI jobs (milestone 5; UI shows "not configured")
- ArtCraft MCP, automations, Stripe billing, hosted analytics (milestones 6 and 7)
