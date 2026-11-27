# SocialForge Stateless OAuth Relay

Stateless Vercel serverless functions enabling **One-Click Sign In** for SocialForge on macOS across Pinterest, Facebook Pages, Instagram, Threads, LinkedIn, X, TikTok, and YouTube — with zero database and zero token storage.

See [docs/OAUTH_RELAY_SETUP.md](../../docs/OAUTH_RELAY_SETUP.md) for the complete Vercel deployment and developer-portal checklist.

## Endpoints

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/health` | `GET` | Health & stateless status check |
| `/api/providers` | `GET` | Lists enabled platforms, canonical HTTPS callback URIs, and PKCE flags (never returns secrets) |
| `/api/oauth/start` | `GET` | Redirects browser (`302`) to the platform's official OAuth authorize screen |
| `/api/oauth/callback/[platform]` | `GET` | Strips `?code=&state=` from history and bounces the single-use code to `socialforge://oauth/callback` |
| `/api/oauth/exchange` | `POST` | Exchanges authorization code for OAuth tokens over TLS using server-side Vercel env secrets |
| `/api/oauth/refresh` | `POST` | Statelessly refreshes expiring tokens using server-side Vercel env secrets |

## Test

```bash
npm test
```
