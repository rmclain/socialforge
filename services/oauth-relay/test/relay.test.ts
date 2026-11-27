import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  handleCallback,
  handleExchange,
  handleHealth,
  handleProviders,
  handleRefresh,
  handleStart,
  sanitizeUpstreamError,
  type FetchLike,
} from '../src/handlers.ts';

const BASE = 'https://auth.socialforge.example';

const FULL_ENV: Record<string, string> = {
  PUBLIC_ORIGIN: BASE,
  PINTEREST_CLIENT_ID: 'pin-id',
  PINTEREST_CLIENT_SECRET: 'pin-secret-xyz',
  META_APP_ID: 'meta-id',
  META_APP_SECRET: 'meta-secret-xyz',
  INSTAGRAM_APP_ID: 'ig-id',
  INSTAGRAM_APP_SECRET: 'ig-secret-xyz',
  THREADS_APP_ID: 'th-id',
  THREADS_APP_SECRET: 'th-secret-xyz',
  LINKEDIN_CLIENT_ID: 'li-id',
  LINKEDIN_CLIENT_SECRET: 'li-secret-xyz',
  X_CLIENT_ID: 'x-id',
  X_CLIENT_SECRET: 'x-secret-xyz',
  TIKTOK_CLIENT_KEY: 'tt-key',
  TIKTOK_CLIENT_SECRET: 'tt-secret-xyz',
  YOUTUBE_CLIENT_ID: 'yt-id',
  YOUTUBE_CLIENT_SECRET: 'yt-secret-xyz',
};

const VALID_CHALLENGE = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';

describe('SocialForge Stateless OAuth Relay', () => {
  it('GET /api/health reports stateless ok with security headers', async () => {
    const res = await handleHealth();
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('Referrer-Policy'), 'no-referrer');
    assert.equal(res.headers.get('Cache-Control'), 'no-store, max-age=0');
    const body = (await res.json()) as Record<string, unknown>;
    assert.equal(body.status, 'ok');
    assert.equal(body.stateless, true);
  });

  it('GET /api/providers lists enabled/disabled platforms and never leaks secrets', async () => {
    const env = {
      PUBLIC_ORIGIN: BASE,
      PINTEREST_CLIENT_ID: 'pin-id',
      PINTEREST_CLIENT_SECRET: 'super-secret-pin-value',
      LINKEDIN_CLIENT_ID: 'li-id',
      LINKEDIN_CLIENT_SECRET: 'super-secret-li-value',
    };
    const res = await handleProviders(new Request(`${BASE}/api/providers`), { env, fetchImpl: globalThis.fetch });
    assert.equal(res.status, 200);
    const text = await res.text();
    assert.ok(!text.includes('super-secret-pin-value'));
    assert.ok(!text.includes('super-secret-li-value'));
    const body = JSON.parse(text) as { providers: Array<{ platform: string; enabled: boolean; redirectURI: string }> };
    const pin = body.providers.find((p) => p.platform === 'pinterest');
    const x = body.providers.find((p) => p.platform === 'x');
    assert.equal(pin?.enabled, true);
    assert.equal(pin?.redirectURI, `${BASE}/api/oauth/callback/pinterest`);
    assert.equal(x?.enabled, false);
  });

  it('GET /api/oauth/start redirects configured providers and enforces state + PKCE', async () => {
    // Missing state rejected
    const badState = await handleStart(new Request(`${BASE}/api/oauth/start?platform=pinterest`), {
      env: FULL_ENV,
      fetchImpl: globalThis.fetch,
    });
    assert.equal(badState.status, 400);

    // Valid Pinterest redirect
    const pinRes = await handleStart(
      new Request(`${BASE}/api/oauth/start?platform=pinterest&state=state-12345678`),
      { env: FULL_ENV, fetchImpl: globalThis.fetch }
    );
    assert.equal(pinRes.status, 302);
    const loc = new URL(pinRes.headers.get('Location') ?? '');
    assert.equal(loc.origin, 'https://www.pinterest.com');
    assert.equal(loc.searchParams.get('client_id'), 'pin-id');
    assert.equal(loc.searchParams.get('redirect_uri'), `${BASE}/api/oauth/callback/pinterest`);
    assert.equal(loc.searchParams.get('state'), 'state-12345678');

    // X requires PKCE code_challenge
    const xMissingPKCE = await handleStart(
      new Request(`${BASE}/api/oauth/start?platform=x&state=state-12345678`),
      { env: FULL_ENV, fetchImpl: globalThis.fetch }
    );
    assert.equal(xMissingPKCE.status, 400);

    const xValid = await handleStart(
      new Request(`${BASE}/api/oauth/start?platform=x&state=state-12345678&code_challenge=${VALID_CHALLENGE}`),
      { env: FULL_ENV, fetchImpl: globalThis.fetch }
    );
    assert.equal(xValid.status, 302);
    const xLoc = new URL(xValid.headers.get('Location') ?? '');
    assert.equal(xLoc.searchParams.get('code_challenge'), VALID_CHALLENGE);
    assert.equal(xLoc.searchParams.get('code_challenge_method'), 'S256');
  });

  it('GET /api/oauth/callback/[platform] bounces single-use code to socialforge:// and strips browser history', async () => {
    const res = await handleCallback(
      new Request(`${BASE}/api/oauth/callback/pinterest?code=authcode99&state=state-12345678`),
      'pinterest',
      { env: FULL_ENV, fetchImpl: globalThis.fetch }
    );
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('Referrer-Policy'), 'no-referrer');
    const body = await res.text();
    assert.ok(body.includes('socialforge://oauth/callback'));
    assert.ok(body.includes('platform=pinterest'));
    assert.ok(body.includes('code=authcode99'));
    assert.ok(body.includes('history.replaceState'));
    assert.ok(!body.includes('pin-secret-xyz'));
  });

  it('POST /api/oauth/exchange exchanges Pinterest code with Basic auth and rejects mismatched redirect_uri', async () => {
    let seenAuth = '';
    let seenURL = '';
    const mockFetch: FetchLike = async (input, init) => {
      seenURL = String(input);
      seenAuth = (init?.headers as Record<string, string>)?.Authorization ?? '';
      return new Response(
        JSON.stringify({ access_token: 'pina_123', refresh_token: 'pinr_456', expires_in: 2592000, scope: 'pins:write' }),
        { status: 200, headers: { 'Content-Type': 'application/json' } }
      );
    };

    const mismatch = await handleExchange(
      new Request(`${BASE}/api/oauth/exchange`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ platform: 'pinterest', code: 'c1', redirect_uri: 'https://evil.example/cb' }),
      }),
      { env: FULL_ENV, fetchImpl: mockFetch }
    );
    assert.equal(mismatch.status, 400);

    const ok = await handleExchange(
      new Request(`${BASE}/api/oauth/exchange`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ platform: 'pinterest', code: 'c1', redirect_uri: `${BASE}/api/oauth/callback/pinterest` }),
      }),
      { env: FULL_ENV, fetchImpl: mockFetch }
    );
    assert.equal(ok.status, 200);
    assert.equal(seenURL, 'https://api.pinterest.com/v5/oauth/token');
    assert.ok(seenAuth.startsWith('Basic '));
    const token = (await ok.json()) as Record<string, unknown>;
    assert.equal(token.access_token, 'pina_123');
    assert.equal(token.refresh_token, 'pinr_456');
  });

  it('POST /api/oauth/exchange upgrades Facebook short-lived token to 60-day token', async () => {
    const calls: string[] = [];
    const mockFetch: FetchLike = async (input, init) => {
      calls.push(`${String(input)} :: ${String(init?.body ?? '')}`);
      if (calls.length === 1) {
        return new Response(JSON.stringify({ access_token: 'fb_short' }), { status: 200 });
      }
      return new Response(JSON.stringify({ access_token: 'fb_long_60d', expires_in: 5184000 }), { status: 200 });
    };
    const res = await handleExchange(
      new Request(`${BASE}/api/oauth/exchange`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ platform: 'facebook', code: 'fbcode' }),
      }),
      { env: FULL_ENV, fetchImpl: mockFetch }
    );
    assert.equal(res.status, 200);
    assert.equal(calls.length, 2);
    const body = (await res.json()) as Record<string, unknown>;
    assert.equal(body.access_token, 'fb_long_60d');
    assert.equal(body.expires_in, 5184000);
  });

  it('POST /api/oauth/refresh refreshes LinkedIn, TikTok, YouTube, X, Pinterest, and Threads tokens cleanly', async () => {
    const mockFetch: FetchLike = async () =>
      new Response(JSON.stringify({ access_token: 'fresh_tok', refresh_token: 'fresh_ref', expires_in: 3600 }), {
        status: 200,
      });

    for (const platform of ['pinterest', 'linkedin', 'x', 'tiktok', 'youtube'] as const) {
      const res = await handleRefresh(
        new Request(`${BASE}/api/oauth/refresh`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ platform, refresh_token: 'old_ref' }),
        }),
        { env: FULL_ENV, fetchImpl: mockFetch }
      );
      assert.equal(res.status, 200, `refresh failed for ${platform}`);
      const body = (await res.json()) as Record<string, unknown>;
      assert.equal(body.access_token, 'fresh_tok');
    }

    const th = await handleRefresh(
      new Request(`${BASE}/api/oauth/refresh`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ platform: 'threads', access_token: 'old_th' }),
      }),
      { env: FULL_ENV, fetchImpl: mockFetch }
    );
    assert.equal(th.status, 200);
  });

  it('sanitizes secrets from upstream errors', () => {
    const cleaned = sanitizeUpstreamError(
      'Invalid client_secret=pin-secret-xyz and Bearer abcdefgh12345678',
      ['pin-secret-xyz']
    );
    assert.ok(!cleaned.includes('pin-secret-xyz'));
    assert.ok(!cleaned.includes('abcdefgh12345678'));
    assert.ok(cleaned.includes('[REDACTED]'));
  });
});
