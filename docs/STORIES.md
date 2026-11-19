# SocialForge stories

Snapshot pages are named after sidebar pages (`home`, `calendar`, `bulk`,
`media`, `studio`, ...), each captured light and dark by `--snapshot`.

## M1 Foundation: shell, navigation, workspaces

### S-001 Move between the thirteen pages from the sidebar
As the user, I click a sidebar item (or press Command-1 to Command-9) and the center workspace and inspector change to that page.
Screens: all snapshot pages
Acceptance:
- [snap] The sidebar shows Home, Calendar, Composer, Media Library, Creative Studio, AI Studio, then Publishing (Bulk Publisher, Automations, Campaigns, Analytics), then Workspace (Social Accounts, Brand Kits, Settings).
- [snap] Pages not built yet say what they will do and which milestone brings them; they have no buttons that do nothing.
- [unit] Every `Page` case has a title, a symbol, and a section.
UX: Sidebar labels are nouns; the window title is the page name; the inspector toggles with Option-Command-I.
Status: done

### S-002 Create and switch workspaces
As the user, I add a workspace (a brand or client) from the workspace menu at the top of the sidebar and switch between them.
Screens: home
Depends: S-001
Acceptance:
- [unit] A new workspace is saved and survives a restart (SwiftData).
- [snap] The workspace switcher shows the workspace's initial in its brand color, and its name.
- [unit] Media and posts belong to exactly one workspace.
UX: "New Workspace…" opens a small sheet with Name and Color; Return creates it.
Status: done

### S-003 See what is coming up on Home
As the user, I open Home and see counts of queued, awaiting-approval, and failed posts, and the next five posts.
Screens: home
Depends: S-002
Acceptance:
- [snap] Greeting headline in Instrument Serif, summary line, "Up next" list with platform badge and time.
- [unit] Counts come from the stored publications, not fixed numbers.
UX: Empty state says "Nothing scheduled yet" with a button to Bulk Publisher.
Status: done

### S-004 Set backend URL and check the connection in Settings
As the user, I enter the publishing service address and press Check; it shows the version and "Up" or the error.
Screens: settings
Acceptance:
- [unit] The client calls `/health` and `/version` and decodes them.
- [snap] Settings has General, Publishing service, AI providers (shows "Not configured"), ComfyUI.
UX: Field validates on Return; errors are inline, not alerts.
Status: done

## M2 Media and transforms

### S-010 Import a folder of images
As the user, I drop a folder (or choose File > Import) and the images are copied into the library with thumbnails, without changing the originals.
Screens: media
Acceptance:
- [unit] Recursive scan picks up JPEG, PNG, HEIC, WEBP, TIFF and skips other files with a reason.
- [unit] SHA-256 hash flags exact duplicates; duplicates are reported, not imported twice.
- [unit] Source files are byte-identical after import.
- [snap] Grid of thumbnails with filename, size and a selection count.
Status: done

### S-011 Make a Pinterest variant of selected images
As the user, I select images and pick a preset (Pinterest 2:3, Instagram square/portrait, Facebook, LinkedIn, X) and choose Fit or Fill.
Screens: media
Depends: S-010
Acceptance:
- [unit] Output has the exact preset size, keeps aspect (no stretching), and the original is unchanged.
- [unit] Fit pads with the chosen background; Fill center-crops (or uses a focal point).
- [unit] EXIF is stripped by default; the color profile is converted to sRGB.
- [unit] Work runs off the main actor with bounded concurrency and can be cancelled.
Status: done

## M3 Pinterest bulk publishing

### S-020 Match images to CSV rows
As the user, I add a CSV and map its columns (filename, url, title, description, alt text) and see each image matched, unmatched, or ambiguous.
Screens: bulk
Depends: S-010
Acceptance:
- [unit] Matching by filename ignores case and extension; a SKU column matches a filename containing it.
- [unit] Two rows that could match one image are reported as ambiguous and left unmatched.
- [unit] Quoted CSV fields with commas and newlines parse correctly.
- [snap] Column mapping and a sample row in the inspector.
Status: done

### S-021 Pick an account and board
(Live Pinterest OAuth built, unverified; tested with the labeled mock account.)
As the user, I choose a connected Pinterest account and one of its boards; options the account cannot use are disabled with the reason.
Screens: bulk, accounts
Acceptance:
- [unit] The capability registry disables Pinterest posting without `pins:write`.
- [snap] Accounts page shows each account's scopes, status and a Reconnect button when expired.
Status: done

### S-022 Build a schedule: one post a day at 9:00
As the user, I set a start date, every N days, a local time, and skip weekends, and every post gets a date and time.
Screens: bulk, calendar
Depends: S-020
Acceptance:
- [unit] Times stay at 9:00 local across a DST change (America/New_York, Nov 1 and Mar 8).
- [unit] Skipped weekdays and dates are never used; items append after an existing queue.
- [unit] Regenerating the schedule keeps the media and copy.
Status: done

### S-023 Review and validate before activating
As the user, I see each post's title, description, link, date and warnings, edit several at once, and nothing activates while errors remain.
Screens: bulk
Depends: S-022
Acceptance:
- [unit] Validation flags titles over 100, descriptions over 800, missing links, and images under the minimum size.
- [unit] Duplicate images or identical links in one run produce a warning.
- [snap] Rows show status chips (Needs Review, Approved) and warning icons.
Status: done

### S-024 Approve and activate the schedule
As the user, I press Activate, confirm the count, and the approved posts are sent to the publishing service.
Screens: bulk
Depends: S-023, S-030
Acceptance:
- [unit] Only approved posts are sent; each carries an idempotency key.
- [self] The calendar shows them as Scheduled.
Status: done

### S-025 See the schedule on a calendar
As the user, I open Calendar and see posts in Month, Week, or Queue view with thumbnails and status.
Screens: calendar
Depends: S-022
Acceptance:
- [snap] Month grid with up to three posts per day and "+N more".
- [unit] Filtering by account, campaign and status narrows the list.
Status: done

### S-030 Backend publishes on time with the Mac closed
As the user, I close the Mac and the service publishes each post at its time, retrying transient failures.
Acceptance:
- [unit] Jobs use an idempotency key; a duplicate submission creates no second post.
- [unit] 5xx and 429 retry with exponential backoff; 401 and validation errors fail at once and mark the account.
- [unit] Each attempt is recorded with request id, result, and the Pin URL.
- [unit] Against the mock Pinterest provider, 30 scheduled posts all publish (scenario A).
Status: done

### S-031 App syncs results when reopened
As the user, I reopen the app and the calendar shows Published with a link, or Failed with the reason (scenario D).
Depends: S-030
Acceptance:
- [unit] Sync merges server status into local publications by id without duplicating them.
Status: done

## Creative Studio basics

### S-040 Put an editable headline on an image
As the user, I open an image in Creative Studio, add a text layer, change font, size and color, and export a PNG.
Screens: studio
Acceptance:
- [unit] A design document encodes to JSON and back with its layers.
- [unit] Template variables (`{{title}}`, `{{price}}`) fill from a post's fields.
- [unit] Export renders at the canvas size with real fonts; a missing font is reported, not substituted silently.
- [snap] Canvas, layer list, and text inspector.
Status: done

### S-041 Create a brand kit
As the user, I save brand colors, fonts, voice notes, and CTAs, and they appear in the studio and composer.
Screens: brandkits
Acceptance:
- [unit] Brand kit is saved per workspace.
Status: done

## Later
Composer with per-platform variants (M4), Facebook Pages, LinkedIn and X adapters (M4), text and image AI providers and ComfyUI jobs (M5), ArtCraft MCP manager and automations (M6), accounts, Stripe billing, credits, analytics (M7), XcodeGen UI tests and notarized installer (M8).

## Dropped
- Browser-bot posting: against platform rules; official APIs only.
