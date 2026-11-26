# Platform Capability & Verification Matrix

Source of truth: `spec/platforms/*.json` (embedded via `python3 tools/gen-spec.py` and verified by `PlatformTests.embeddedSpecsMatchSpecFolder`).

Every platform below has an official API adapter implemented in `SocialForgeKit` (`PublishEngine.swift`, `MetaPublishing.swift`, `PlatformAdapters.swift`) and covered by automated HTTP-stubbed unit tests. **None of the 8 live third-party provider APIs has been verified against live credentials (`liveVerified: false`).**

| Platform | SocialForge Status | Live Verified? | Content Types | Auth & Token Lifecycle | Media Hosting Needed? | Key Enforced Limits |
|---|---|---|---|---|---|---|
| **Pinterest** | Built · automated tests (live unverified) + Mock tested E2E | No (`false`) | `image_pin`, `video_pin` | OAuth 2.0 loopback (`127.0.0.1:8085`) + proactive refresh | No (direct upload) | Title 100, Desc 800, Alt 500, Link 2048; Images ≤20 MB (JPEG/PNG) |
| **Facebook Pages** | Built · automated tests (live unverified) | No (`false`) | `text`, `photo`, `multi_photo`, `reel` | Meta OAuth (Facebook Login) + non-expiring Page tokens | No (direct / resumable upload) | Message 63,206; Images ≤10 MB; Video ≤1 GB |
| **Instagram** | Built · automated tests (live unverified) | No (`false`) | `photo`, `reel`, `carousel` | Facebook Login **or** direct Instagram Business Login + 60-day token refresh | Photos/carousels: **Yes (S3/R2)** · Reels: No (resumable upload) | Caption 2,200; JPEG ≤8 MB; 24h publish quota check |
| **Threads** | Built · automated tests (live unverified) | No (`false`) | `text`, `image`, `video`, `carousel` | Threads OAuth (HTTPS callback with state validation) + 60-day refresh | Text: No · Media: **Yes (S3/R2)** | Text 500 |
| **LinkedIn** | Built · automated tests (live unverified) | No (`false`) | `member_post`, `organization_post` | OAuth 2.0 loopback (`127.0.0.1:8085`) + refresh token | No (direct REST image upload) | Commentary 3,000; Image ≤5 MB |
| **X** | Built · automated tests (live unverified) | No (`false`) | `text`, `photo`, `video_post` | OAuth 2.0 + **PKCE (S256)** loopback (`127.0.0.1:8085`) + offline.access refresh | No (v2 chunked upload) | Weighted 280 chars (URLs=23, CJK/emoji=2); Image ≤5 MB |
| **TikTok** | Built · automated tests (live unverified) | No (`false`) | `inbox_video`, `video` | OAuth 2.0 + **PKCE (S256)** + mandatory `creator_info/query` + refresh | No (direct chunk upload) | Caption 2,200; explicit privacy & commercial disclosures |
| **YouTube** | Built · automated tests (live unverified) | No (`false`) | `video`, `short` | Google OAuth 2.0 + **PKCE (S256)** + refresh | No (resumable upload) | Title 100, Desc 5,000; Shorts vertical aspect check; `selfDeclaredMadeForKids` |

## Dynamic Account Capabilities & Safety Rules

- `Capabilities.forAccount` and `SocialAccount.connectionStatus` evaluate static rules alongside granted OAuth scopes, token expiry (`expiringSoon` / `reauthRequired`), sandbox vs production mode, and public S3/R2 availability.
- Editing an approved post's content, media, destination, or disclosures automatically invalidates approval back to `Needs Review` (`Publication.invalidateApprovalIfChanged()`).
- HTTP `403` permission errors mark a post `actionRequired` without falsely wiping the account's auth status; HTTP `401` marks the account `reauthRequired` and posts `authRequired` while preserving all drafts, media, and schedules.
- Providers without deterministic duplicate reconciliation stop in `outcomeUnknown` after uncertain network timeouts and present a Manual Reconciliation UI ("Confirm Published" / "Retry Publish") instead of blindly retrying and risking duplicate posts.

## Optional Remote Publishing Service (`services/api/`)

- Advertises supported platforms via `GET /v1/capabilities` (currently `pinterest` + `mock`).
- The Mac app checks service capabilities before transferring or activating remote posts so unsupported remote platforms never fail mid-flight.
