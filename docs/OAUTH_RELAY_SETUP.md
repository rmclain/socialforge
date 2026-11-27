# Hosted Stateless OAuth Relay (Vercel Free Tier)

This guide walks through deploying SocialForge's **stateless OAuth Relay** (`services/oauth-relay/`) on Vercel's free Hobby plan so users can connect Pinterest, Facebook Pages, Instagram, Threads, LinkedIn, X, TikTok, and YouTube in **one click** — without creating their own developer apps.

## How it stays local-first & private

- **Zero database, zero accounts, zero token storage**: The relay is a set of stateless serverless functions on Vercel. It never persists user tokens, posts, media, or profiles.
- **No tokens in browser URLs**: After you approve access in the browser, the callback page strips `?code=&state=` from browser history, sets `Referrer-Policy: no-referrer`, and bounces only the single-use authorization `code` + `state` back into the Mac app via `socialforge://oauth/callback`.
- **Direct TLS token exchange**: SocialForge verifies `state` locally and sends a direct HTTPS `POST /api/oauth/exchange` to your Vercel relay, which uses your server-side `client_secret` to exchange the code and returns the tokens straight into the user's local **macOS Keychain**.
- **BYOK always remains available**: Users can switch between *One-Click Sign In (Relay)* and *My Own Developer App (BYOK)* per platform at any time.

---

## Step 1 — Deploy `services/oauth-relay` to Vercel (Free Tier)

### Option A: Vercel Dashboard (recommended — auto-deploys on push)

1. Go to <https://vercel.com/new> and import your `rmclain/socialforge` repository.
2. Under **Root Directory**, click **Edit** and select **`services/oauth-relay`**.
3. Leave **Framework Preset** as **Other** and **Build Command** empty (Vercel builds `api/**/*.ts` functions natively with zero build dependencies).
4. Click **Deploy**. Note your live HTTPS URL (for example `https://socialforge-oauth-relay.vercel.app`, or attach a custom domain like `https://auth.socialforge.app`).

### Option B: Vercel CLI (from this Mac)

```bash
cd services/oauth-relay
vercel login
vercel link
vercel --prod
```

Verify the deployment is live:

```bash
curl https://<your-relay-domain>/api/health
curl https://<your-relay-domain>/api/providers
```

---

## Step 2 — Register Callback URLs in Each Platform's Developer Console

Every platform gets a permanent **HTTPS** callback URL hosted by your Vercel deployment (which Pinterest, Meta, Threads, LinkedIn, X, TikTok, and YouTube all accept):

| Platform | Developer Console | Exact HTTPS Callback URL to Register | Vercel Environment Variables |
|---|---|---|---|
| **Pinterest** | <https://developers.pinterest.com/apps/> | `https://<your-domain>/api/oauth/callback/pinterest` | `PINTEREST_CLIENT_ID`, `PINTEREST_CLIENT_SECRET` (optional: `PINTEREST_API_BASE=https://api-sandbox.pinterest.com` while in Trial) |
| **Facebook Pages & Linked Instagram** | <https://developers.facebook.com/apps/> | `https://<your-domain>/api/oauth/callback/facebook` | `META_APP_ID`, `META_APP_SECRET` (optional: `META_CONFIG_ID`) |
| **Instagram Business Login (direct)** | <https://developers.facebook.com/apps/> | `https://<your-domain>/api/oauth/callback/instagram_login` | `INSTAGRAM_APP_ID`, `INSTAGRAM_APP_SECRET` |
| **Threads** | <https://developers.facebook.com/apps/> | `https://<your-domain>/api/oauth/callback/threads` | `THREADS_APP_ID`, `THREADS_APP_SECRET` |
| **LinkedIn** | <https://www.linkedin.com/developers/apps> | `https://<your-domain>/api/oauth/callback/linkedin` | `LINKEDIN_CLIENT_ID`, `LINKEDIN_CLIENT_SECRET` |
| **X** | <https://developer.x.com/en/portal/dashboard> | `https://<your-domain>/api/oauth/callback/x` | `X_CLIENT_ID` (optional: `X_CLIENT_SECRET`) |
| **TikTok** | <https://developers.tiktok.com/apps/> | `https://<your-domain>/api/oauth/callback/tiktok` | `TIKTOK_CLIENT_KEY`, `TIKTOK_CLIENT_SECRET` |
| **YouTube** | <https://console.cloud.google.com/apis/credentials> | `https://<your-domain>/api/oauth/callback/youtube` | `YOUTUBE_CLIENT_ID`, `YOUTUBE_CLIENT_SECRET` |

> **Tip:** You don't have to configure all 8 platforms on day one. Enable just the platforms you want (e.g., start with **Pinterest** and **LinkedIn**). Unconfigured platforms stay disabled on `/api/providers` and seamlessly fall back to BYOK in SocialForge.

---

## Step 3 — Add Environment Variables in Vercel

1. In your Vercel project dashboard, open **Settings › Environment Variables**.
2. Optionally set `PUBLIC_ORIGIN=https://<your-domain>` (recommended if you attach a custom domain so callback URIs always match your canonical domain).
3. Add the ID and Secret environment variables from the table above for each platform you want enabled (check **Production** and **Preview**).
4. Trigger a **Redeploy** (or run `vercel --prod`) so the new environment variables take effect.
5. Verify `GET https://<your-domain>/api/providers` now shows `"enabled": true` for your configured platforms (it never exposes secrets).

---

## Step 4 — Connect SocialForge to Your Relay

### Immediate testing (no rebuild required)
1. Open **SocialForge › Connections › Publishing Infrastructure** (or **Settings › Publishing**).
2. Paste your Vercel URL (`https://<your-domain>`) into **One-Click OAuth Relay (Vercel · Stateless)** and click **Test & Discover Providers**.
3. Return to **Connections › Social Accounts** — every enabled platform now displays a **One-Click Connect** button!

### Shipping One-Click Sign In pre-configured for all users
Once your Vercel relay URL is finalized, set it once in `apps/mac/Info.plist.in`:

```xml
<key>SFOAuthRelayURL</key><string>https://<your-domain></string>
```

Then cut a release (`NOTARY_PROFILE=forgedeck-notary ./tools/release.sh`). Every downloaded copy of SocialForge will automatically discover your relay's enabled platforms out of the box, while still letting advanced users override the relay URL or use BYOK credentials.

---

## Step 5 — Platform App Review Notes (For Public Multi-User One-Click Access)

While you (and listed app testers) can connect immediately in Development/Trial mode, opening One-Click Sign In to *other* users requires passing each platform's production review once:

1. **LinkedIn (Fastest)**: `openid`, `profile`, and `w_member_social` (Share on LinkedIn) are self-serve. Company pages (`w_organization_social`) require applying for the Community Management API.
2. **Pinterest**: Request **Standard Access** in the Pinterest Developer Portal (short screencast + privacy policy URL). Before approval, set `PINTEREST_API_BASE=https://api-sandbox.pinterest.com` to test against Sandbox.
3. **YouTube**: Submit your Google Cloud OAuth consent screen for verification (`youtube.upload` & `youtube.readonly`) to lift the 100-user cap and enable public uploads.
4. **X**: Works immediately with OAuth 2.0 PKCE; write volume depends on your X API tier.
5. **Meta (Facebook Pages, Instagram, Threads)**: Requires Meta App Review + Business Verification to serve users outside your App Roles / Testers list.
6. **TikTok**: Content Posting API audit is required for public Direct Post; unaudited apps can still upload to Creator Inbox drafts / private-only posts.

---

## Local Testing

```bash
cd services/oauth-relay
npm test
```
