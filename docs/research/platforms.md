# Platform research (2026-11-19)

Scope for the first build: Pinterest end to end. The other first-class
providers are noted so the connector design fits them. Every fact below
comes from the provider's public developer docs as last known. Each must be
re-checked against the live docs before the live adapter is switched on;
`spec/platforms/*.json` records the source link and the date checked.

## Pinterest (API v5): first slice

| Topic | Fact | Source |
|---|---|---|
| Auth | OAuth 2.0 authorization code. Authorize at `https://www.pinterest.com/oauth/`, exchange at `POST https://api.pinterest.com/v5/oauth/token` (HTTP Basic with client id and secret). Refresh tokens rotate. | developers.pinterest.com/docs/getting-started/authentication |
| Scopes needed | `user_accounts:read`, `boards:read`, `pins:read`, `pins:write` | same |
| Boards | `GET /v5/boards` (paged with `bookmark`) | developers.pinterest.com/docs/api/v5/boards-list |
| Create Pin | `POST /v5/pins` with `board_id`, `media_source` (`image_url` or `image_base64`), `link`, `title`, `description`, `alt_text` | developers.pinterest.com/docs/api/v5/pins-create |
| Text limits | title 100, description 800, alt text 500 characters | same |
| Media | Recommended 2:3 (1000 x 1500). JPEG, PNG, WEBP, BMP, TIFF accepted. Max file 20 MB. | help.pinterest.com, "Product Pin specs" |
| Trial access | New apps get Trial access: writes go to `api-sandbox.pinterest.com` and are not public until Standard access is approved. | developers.pinterest.com/docs/getting-started/set-up-app |
| Idempotency | No idempotency key on create. Reconcile an uncertain result by listing recent Pins on the board and matching `link` + `title` before retrying. | (design decision) |
| Rate limits | Per-app and per-user limits; 429 returns retry hints. Back off exponentially. | developers.pinterest.com/docs/reference/ratelimits |

## Others (milestone 4, not built yet)

- **Facebook Pages**: Graph API `/{page-id}/photos` and `/feed`; needs
  `pages_manage_posts`, `pages_read_engagement`, and app review.
- **LinkedIn**: Posts API (`/rest/posts`) with `w_member_social` or
  `w_organization_social`; images are uploaded first through the Images API.
- **X**: API v2 `POST /2/tweets`; media upload via v2 media endpoint; the
  posting tier depends on the paid access level.

## What this means for the build

1. The backend owns tokens, so the app never holds a client secret.
2. Capabilities come from a registry, not code, so a provider without a
   feature (or an account without a scope) never shows that option.
3. Until Pinterest approves the app, the live adapter is "unverified" and the
   tests run against a mock modeled on the documented request and response
   shapes.

## Design reference

`design/SocialForge v2.dc.html` (Claude Design): dark glass sidebar, warm
orange accent `#ff8a5c`, Instrument Serif for display type, SF Pro for UI,
three columns (sidebar, workspace, inspector), and an "automation bar" that
reads a plain sentence ("Post these 30 images to my Pinterest board, one
each day at 9 AM...") and shows how it was understood.
