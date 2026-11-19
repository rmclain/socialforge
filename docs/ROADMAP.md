# Roadmap

## Done (first build, 2026-11-19)

- **M1 Foundation**: 13-page sidebar shell with inspector, workspaces, SwiftData store, Settings (publishing service, AI providers placeholder, ComfyUI connection test, appearance), Ember accent from the design.
- **M2 Media and creative**: library import (folders, drag and drop, CSV alongside), SHA-256 duplicates, thumbnails, metadata, six export presets, Creative Studio with layered documents, real-font text, templates with variables, undo/redo, PNG export, brand kits.
- **M3 Pinterest bulk publishing**: CSV mapping and matching with ambiguity reports, account/board choice with capability checks, DST-safe cadence, validation, multi-edit, approval, activation; calendar (month, week, queue, drag to reschedule); publishing service with idempotent jobs, retries, reconciliation, attempt history, sync.
- **On-Mac publishing** (your choice of a Mac-only app): PublishEngine with retries, reconciliation, and attempt history; the background publisher (launch agent via SMAppService) for when the app is closed; Docker removed.

- **Design pass and feature round (2026-11-19, second session)**: the Claude Design look on every page (Instrument Serif bundled), editable brand templates with brand-bound colors, fonts, and logo, batch template application, smart resize, Vision/Core Image transforms, Composer with per-platform versions, AI Studio with ComfyUI and BYOK providers, AI copy in Bulk Publisher, a typed command assistant, Automations, Campaigns, and Analytics.

## Known limitations

- AI providers (OpenAI, Anthropic, Gemini, local) and ComfyUI are built against their documented APIs and tested with stubbed HTTP only; no live key or server was used. Use Test in Settings to verify yours.
- Extend and Relight in Creative Studio need an AI image provider with those operations; they are shown disabled with the reason.
- Composer drafts Facebook, LinkedIn, and X versions, but only Pinterest can be scheduled (milestone 4).
- Automations run while SocialForge is open (folder checks every 5 minutes); they always stop at Needs Review.

- Mac-only: nothing posts while the Mac is asleep or off; due posts go out on wake. The optional service in services/api covers that case.
- The background publisher must be turned on in Settings and approved in System Settings > Login Items; it was not registered on the build Mac (tested by running the agent mode directly).
- Pinterest needs your own Pinterest app (ID and secret in the Keychain); a shared app would need a small token relay.
- Pinterest live API: built, **not verified** (needs app credentials and review). Token refresh is not implemented yet; an expired token marks the account expired.
- With the optional service, editing a scheduled post needs cancel and re-activate.
- Video files import and list, but have no transforms or posting yet.
- No AI generation yet: titles come from the CSV or filename. AI Studio, Composer, Automations, Campaigns, and Analytics pages say which milestone brings them.
- The optional service's tokens come from `npm run token`; there are no user accounts or sign-in yet.
- Snapshots without Screen Recording permission use a fallback that leaves sidebars and some form backgrounds blank; grant permission to your terminal for faithful captures.
- No XcodeGen UI test target yet; UI flows are covered by the in-app self-test and snapshots.
- Instrument Serif (from the design) is not bundled.

## Next

| Milestone | Scope |
|---|---|
| M3 finish | Verify Pinterest live; refresh-token rotation; a "posts due soon" notification and an optional wake request before scheduled times; partial-import error report export |
| M4 Multi-platform | Composer with per-platform variants and previews; Facebook Pages, LinkedIn, X adapters and OAuth (PKCE for X) |
| M5 AI creative | BYOK text/image providers in the Keychain, cost estimates, ComfyUI workflow import, parameter mapping, queue with WebSocket progress, AI background → editable text pipeline (scenario B) |
| M6 ArtCraft and automation | MCP connection manager with restricted roots and approvals, PhotoCraft integration, folder-watch automations, typed natural-language command panel with previews |
| M7 Commercial | User accounts and sign-in, Stripe Checkout and Billing Portal, entitlements enforced by the service, credit ledger with idempotent charges, analytics from provider metrics |
| M8 Polish | XcodeGen UI tests, performance runs on 5,000 assets, accessibility audit, notarized Developer ID build and installer |
