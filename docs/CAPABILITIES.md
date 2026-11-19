# Platform capability and approval matrix

Source of truth: `spec/platforms/*.json` (checked 2026-11-19). The app never
offers an option the platform or the connected account cannot use.

| Platform | SocialForge status | Content types | Permissions needed | Image (recommended · max) | Text limits (enforced) | Platform approval needed |
|---|---|---|---|---|---|---|
| Pinterest | Built (on-Mac and optional service). Live API **unverified**; tested against a labeled mock | Image Pin | `boards:read`, `pins:write` (+ `user_accounts:read`, `pins:read`) | 2:3, 1000 × 1500 · 20 MB; JPEG, PNG, WebP, BMP, TIFF | title 100, description 800, alt text 500, link 2048 | App review for Standard access. Trial access writes to the sandbox API only |
| Facebook Pages | Planned (milestone 4) | Photo post | `pages_manage_posts`, `pages_read_engagement` | 4:5, 1080 × 1350 · 10 MB | message 63,206 | Meta app review and business verification |
| LinkedIn | Planned (milestone 4) | Profile post, Company page post | `w_member_social` / `w_organization_social` | 1.91:1, 1200 × 627 | commentary 3,000 | Community Management API access approval |
| X | Planned (milestone 4) | Post, Post with image | `tweet.write`, `users.read`, `media.write` | 16:9, 1600 × 900 · 5 MB | 280 | Paid API tier with write access |

## What "verified" means

`liveVerified` in a spec turns true only after a real post through the live
API has succeeded and been checked. Until then the Accounts page shows
"Built · live API unverified".

## Account-level checks (scenario E)

- A post cannot be approved or activated when its account lacks a required
  scope, is expired or revoked, or its platform is planned. The reason is
  shown with a Reconnect action.
- The optional service re-checks the same rules on `POST /v1/publications` and
  answers 422 with the reasons.
- A 401 or 403 while publishing marks the account expired and fails the post
  with "Reconnect the account".

## Before the Pinterest adapter goes live

1. Create a Pinterest app at developers.pinterest.com and add the redirect URI
   `http://127.0.0.1:8085/pinterest/callback`.
2. In SocialForge, Settings > Publishing > Your Pinterest app: paste the App ID and
   secret (kept in the Keychain). With Trial access, choose API: Sandbox.
3. Press Connect Pinterest, publish one Pin, and confirm the URL.
4. Confirm the `note` field round-trips (the reconciliation key) and that
   `GET /v5/boards/{id}/pins` returns it; adjust `findExisting` if not.
5. Set `"liveVerified": true` in `spec/platforms/pinterest.json` and run `python3 tools/gen-spec.py`.
