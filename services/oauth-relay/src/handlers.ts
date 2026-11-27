import {
  ALL_PLATFORMS,
  PROVIDERS,
  callbackURI,
  isRelayPlatform,
  resolveOrigin,
  type ProviderCredentials,
  type RelayPlatform,
} from './providers.ts';

export type FetchLike = typeof fetch;

export interface RelayContext {
  env: Record<string, string | undefined>;
  fetchImpl: FetchLike;
}

const defaultCtx = (): RelayContext => ({
  env: process.env,
  fetchImpl: globalThis.fetch,
});

const SECURITY_HEADERS: Record<string, string> = {
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Cache-Control': 'no-store, max-age=0',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      ...SECURITY_HEADERS,
    },
  });
}

function html(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';",
      ...SECURITY_HEADERS,
    },
  });
}

function escapeHTML(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

/** Strips secrets before returning upstream error text to the Mac client. */
export function sanitizeUpstreamError(raw: string, secrets: string[]): string {
  let out = raw.slice(0, 600);
  for (const s of secrets) {
    if (s && s.length >= 6) {
      out = out.split(s).join('[REDACTED]');
    }
  }
  out = out.replace(/(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi, '$1 [REDACTED]');
  out = out.replace(/(access_token|refresh_token|client_secret)["'=:\s]+[^"&\s,}]+/gi, '$1=[REDACTED]');
  return out;
}

function isValidState(state: string): boolean {
  return /^[A-Za-z0-9._~-]{8,256}$/.test(state);
}

function isValidChallenge(cc: string): boolean {
  return /^[A-Za-z0-9_-]{43,128}$/.test(cc);
}

// MARK: - GET /api/health

export async function handleHealth(): Promise<Response> {
  return json({
    status: 'ok',
    service: 'socialforge-oauth-relay',
    version: '1.0.0',
    stateless: true,
  });
}

const REQUIRED_ENV_VARS: Record<RelayPlatform, string[]> = {
  pinterest: ['PINTEREST_CLIENT_ID', 'PINTEREST_CLIENT_SECRET'],
  facebook: ['META_APP_ID', 'META_APP_SECRET'],
  instagram_login: ['INSTAGRAM_APP_ID', 'INSTAGRAM_APP_SECRET'],
  threads: ['THREADS_APP_ID', 'THREADS_APP_SECRET'],
  linkedin: ['LINKEDIN_CLIENT_ID', 'LINKEDIN_CLIENT_SECRET'],
  x: ['X_CLIENT_ID'],
  tiktok: ['TIKTOK_CLIENT_KEY', 'TIKTOK_CLIENT_SECRET'],
  youtube: ['YOUTUBE_CLIENT_ID', 'YOUTUBE_CLIENT_SECRET'],
};

// MARK: - GET /api/test

export async function handleTest(request: Request, ctx: RelayContext = defaultCtx()): Promise<Response> {
  if (request.method !== 'GET') return json({ error: 'Method not allowed' }, 405);
  const u = new URL(request.url);
  const origin = resolveOrigin(request, ctx.env);

  if (u.searchParams.get('simulate_callback') === '1') {
    const testURL = new URL(`${origin}/api/oauth/callback/pinterest`);
    testURL.searchParams.set('code', 'sf_test_code_only');
    testURL.searchParams.set('state', 'sf_test_state_1234');
    return handleCallback(new Request(testURL.toString()), 'pinterest', ctx);
  }

  const platforms = ALL_PLATFORMS.map((platform) => {
    const spec = PROVIDERS[platform];
    const creds = spec.credentials(ctx.env);
    const missingEnvVars = REQUIRED_ENV_VARS[platform].filter((k) => !(ctx.env[k] ?? '').trim());
    return {
      platform,
      displayName: spec.displayName,
      enabled: creds !== null,
      callbackURI: callbackURI(origin, platform),
      pkceRequired: spec.pkceRequired,
      supportsRefresh: spec.supportsRefresh,
      missingEnvVars,
    };
  });

  const enabledPlatforms = platforms.filter((p) => p.enabled).map((p) => p.platform);
  return json({
    ok: true,
    service: 'socialforge-oauth-relay',
    version: '1.0.0',
    stateless: true,
    timestamp: new Date().toISOString(),
    origin,
    publicOriginConfigured: Boolean((ctx.env.PUBLIC_ORIGIN ?? '').trim()),
    deepLinkScheme: 'socialforge://oauth/callback',
    summary: {
      enabledCount: enabledPlatforms.length,
      totalPlatforms: platforms.length,
      enabledPlatforms,
    },
    endpoints: {
      status: `${origin}/`,
      health: `${origin}/api/health`,
      providers: `${origin}/api/providers`,
      test: `${origin}/api/test`,
      simulateCallback: `${origin}/api/test?simulate_callback=1`,
    },
    platforms,
  });
}

// MARK: - GET /

export async function handleHome(request: Request, ctx: RelayContext = defaultCtx()): Promise<Response> {
  if (request.method !== 'GET') return json({ error: 'Method not allowed' }, 405);
  const origin = resolveOrigin(request, ctx.env);
  const rows = ALL_PLATFORMS.map((platform) => {
    const spec = PROVIDERS[platform];
    const enabled = spec.credentials(ctx.env) !== null;
    const cb = callbackURI(origin, platform);
    const envNames = REQUIRED_ENV_VARS[platform].join(', ');
    return `<tr>
      <td><strong>${escapeHTML(spec.displayName)}</strong></td>
      <td><span class="dot ${enabled ? 'on' : 'off'}"></span>${enabled ? 'Enabled' : 'Not configured'}</td>
      <td><code>${escapeHTML(cb)}</code></td>
      <td class="muted">${escapeHTML(envNames)}</td>
    </tr>`;
  }).join('');

  const enabledCount = ALL_PLATFORMS.filter((p) => PROVIDERS[p].credentials(ctx.env) !== null).length;

  const page = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>SocialForge OAuth Relay — Status &amp; Diagnostics</title>
<style>
  :root { color-scheme: dark light; --bg: #0f0f13; --card: #19191e; --stroke: rgba(255,255,255,.1); --text: #f1f1f5; --text2: #9d9da8; --accent: #ff7a45; --on-accent: #1d0d05; --green: #3ddc84; }
  @media (prefers-color-scheme: light) { :root { --bg: #f4efe9; --card: #fbf8f5; --stroke: rgba(0,0,0,.09); --text: #1c1b1f; --text2: #6b6a72; --accent: #e8662f; --on-accent: #fff; --green: #1f9d57; } }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 36px 20px; background: var(--bg); color: var(--text); font: 14.5px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
  .wrap { max-width: 960px; margin: 0 auto; }
  .card { background: var(--card); border: 1px solid var(--stroke); border-radius: 16px; padding: 24px; margin-bottom: 18px; }
  h1 { margin: 0 0 6px; font-size: 26px; font-weight: 650; }
  p { margin: 0 0 14px; color: var(--text2); }
  .badge { display: inline-flex; align-items: center; gap: 7px; font-size: 13px; padding: 5px 11px; border-radius: 999px; border: 1px solid var(--stroke); margin-bottom: 14px; }
  .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 7px; vertical-align: middle; }
  .dot.on { background: var(--green); }
  .dot.off { background: var(--text2); opacity: .45; }
  .row { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; }
  .btn { display: inline-flex; align-items: center; padding: 9px 14px; border-radius: 10px; font-weight: 600; font-size: 13.5px; text-decoration: none; cursor: pointer; border: 1px solid var(--stroke); background: transparent; color: var(--text); }
  .btn.primary { background: var(--accent); color: var(--on-accent); border-color: transparent; }
  table { width: 100%; border-collapse: collapse; font-size: 13.5px; }
  th, td { text-align: left; padding: 10px 8px; border-bottom: 1px solid var(--stroke); vertical-align: top; }
  th { font-size: 11.5px; text-transform: uppercase; letter-spacing: .05em; color: var(--text2); }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; word-break: break-all; }
  .muted { color: var(--text2); font-size: 12px; }
  pre { margin: 14px 0 0; padding: 14px; border-radius: 10px; border: 1px solid var(--stroke); background: rgba(0,0,0,.18); overflow-x: auto; font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; display: none; }
  pre.show { display: block; }
</style>
</head>
<body>
<div class="wrap">
  <div class="card">
    <div class="badge"><span class="dot on" style="margin:0"></span> Online · Stateless · ${enabledCount} of ${ALL_PLATFORMS.length} platforms enabled</div>
    <h1>SocialForge OAuth Relay</h1>
    <p>Stateless OAuth 2.0 broker for SocialForge on macOS. Stores zero databases, zero user accounts, and zero tokens — single-use codes bounce directly back into your Mac app via <code>socialforge://oauth/callback</code>.</p>
    <div class="row">
      <button class="btn primary" id="run-test" type="button">Run Self-Test (/api/test)</button>
      <a class="btn" href="/api/test">JSON /api/test</a>
      <a class="btn" href="/api/health">JSON /api/health</a>
      <a class="btn" href="/api/providers">JSON /api/providers</a>
      <a class="btn" href="/api/test?simulate_callback=1">Test socialforge:// Bounce</a>
    </div>
    <pre id="test-output"></pre>
  </div>

  <div class="card">
    <h2 style="margin:0 0 12px;font-size:17px">Configured Platforms &amp; HTTPS Callback URLs</h2>
    <table>
      <thead><tr><th>Platform</th><th>Status</th><th>HTTPS Callback URL</th><th>Required Vercel Env Vars</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
  </div>
</div>
<script>
document.getElementById("run-test").addEventListener("click", function () {
  var out = document.getElementById("test-output");
  out.textContent = "Running GET /api/test…";
  out.className = "show";
  fetch("/api/test", { cache: "no-store" })
    .then(function (r) { return r.json(); })
    .then(function (data) { out.textContent = JSON.stringify(data, null, 2); })
    .catch(function (err) { out.textContent = "Error: " + String(err); });
});
</script>
</body>
</html>`;
  return html(page, 200);
}

// MARK: - GET /api/providers

export async function handleProviders(request: Request, ctx: RelayContext = defaultCtx()): Promise<Response> {
  if (request.method !== 'GET') return json({ error: 'Method not allowed' }, 405);
  const origin = resolveOrigin(request, ctx.env);
  const providers = ALL_PLATFORMS.map((platform) => {
    const spec = PROVIDERS[platform];
    const creds = spec.credentials(ctx.env);
    return {
      platform,
      displayName: spec.displayName,
      enabled: creds !== null,
      redirectURI: callbackURI(origin, platform),
      pkceRequired: spec.pkceRequired,
      supportsRefresh: spec.supportsRefresh,
      scopes: spec.defaultScopes,
    };
  });
  return json({
    service: 'socialforge-oauth-relay',
    version: '1.0.0',
    stateless: true,
    origin,
    providers,
  });
}

// MARK: - GET /api/oauth/start

export async function handleStart(request: Request, ctx: RelayContext = defaultCtx()): Promise<Response> {
  if (request.method !== 'GET') return json({ error: 'Method not allowed' }, 405);
  const u = new URL(request.url);
  const platformParam = (u.searchParams.get('platform') ?? '').trim().toLowerCase();
  const state = (u.searchParams.get('state') ?? '').trim();
  const codeChallenge = (u.searchParams.get('code_challenge') ?? '').trim();
  const mode = (u.searchParams.get('mode') ?? '').trim();

  if (!isRelayPlatform(platformParam)) {
    return json({ error: `Unsupported platform: ${platformParam || '(missing)'}` }, 400);
  }
  if (!isValidState(state)) {
    return json({ error: 'Invalid or missing state parameter.' }, 400);
  }

  const spec = PROVIDERS[platformParam];
  const creds = spec.credentials(ctx.env);
  if (!creds) {
    return json({ error: `${spec.displayName} is not enabled on this OAuth relay yet.` }, 503);
  }
  if (spec.pkceRequired && !isValidChallenge(codeChallenge)) {
    return json({ error: `${spec.displayName} requires a valid PKCE S256 code_challenge.` }, 400);
  }

  const origin = resolveOrigin(request, ctx.env);
  const redirectURI = callbackURI(origin, platformParam);
  const target = spec.authorizeURL({
    creds,
    redirectURI,
    state,
    codeChallenge: codeChallenge || undefined,
    mode: mode || undefined,
  });

  return new Response(null, {
    status: 302,
    headers: {
      Location: target,
      ...SECURITY_HEADERS,
    },
  });
}

// MARK: - GET /api/oauth/callback/[platform]

export async function handleCallback(
  request: Request,
  platformParam: string,
  ctx: RelayContext = defaultCtx()
): Promise<Response> {
  if (request.method !== 'GET') return json({ error: 'Method not allowed' }, 405);
  const normalized = platformParam.trim().toLowerCase();
  if (!isRelayPlatform(normalized)) {
    return html('<!doctype html><meta charset="utf-8"><title>Unsupported platform</title><p>Unsupported OAuth platform.</p>', 400);
  }

  const spec = PROVIDERS[normalized];
  const u = new URL(request.url);
  const code = u.searchParams.get('code') ?? '';
  const state = u.searchParams.get('state') ?? '';
  const error = u.searchParams.get('error') ?? '';
  const errorDescription = u.searchParams.get('error_description') ?? '';

  // Build deep-link back to the native Mac app. Only short-lived single-use authorization code
  // and state are passed — NEVER access or refresh tokens.
  const deepLink = new URL('socialforge://oauth/callback');
  deepLink.searchParams.set('platform', normalized);
  deepLink.searchParams.set('relay', '1');
  if (state) deepLink.searchParams.set('state', state);
  if (code) deepLink.searchParams.set('code', code);
  if (error) deepLink.searchParams.set('error', error);
  if (errorDescription) deepLink.searchParams.set('error_description', errorDescription);

  const origin = resolveOrigin(request, ctx.env);
  const canonicalCallback = new URL(callbackURI(origin, normalized));
  if (code) canonicalCallback.searchParams.set('code', code);
  if (state) canonicalCallback.searchParams.set('state', state);
  if (error) canonicalCallback.searchParams.set('error', error);
  if (errorDescription) canonicalCallback.searchParams.set('error_description', errorDescription);

  const deepLinkJSON = JSON.stringify(deepLink.toString());
  const copyURLJSON = JSON.stringify(canonicalCallback.toString());
  const failed = Boolean(error) || !code;

  const title = failed ? `${spec.displayName} sign-in did not complete` : `Return to SocialForge`;
  const subtitle = failed
    ? escapeHTML(errorDescription || error || 'No authorization code was returned. You can close this tab and try again in SocialForge.')
    : `Authorization for ${escapeHTML(spec.displayName)} succeeded. Opening SocialForge on your Mac…`;

  const page = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>${escapeHTML(title)} — SocialForge</title>
<style>
  :root { color-scheme: dark light; --bg: #111114; --card: #1c1c21; --stroke: rgba(255,255,255,.1); --text: #f2f2f5; --text2: #a0a0aa; --accent: #ff7a45; --on-accent: #1d0d05; }
  @media (prefers-color-scheme: light) { :root { --bg: #f4efe9; --card: #fbf8f5; --stroke: rgba(0,0,0,.09); --text: #1c1b1f; --text2: #6b6a72; --accent: #e8662f; --on-accent: #fff; } }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 24px; background: var(--bg); color: var(--text); font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
  .card { width: min(480px, 100%); background: var(--card); border: 1px solid var(--stroke); border-radius: 16px; padding: 28px; box-shadow: 0 24px 64px rgba(0,0,0,.35); }
  h1 { margin: 0 0 8px; font-size: 22px; font-weight: 650; }
  p { margin: 0 0 20px; color: var(--text2); }
  .row { display: flex; flex-wrap: wrap; gap: 10px; }
  .btn { display: inline-flex; align-items: center; justify-content: center; padding: 10px 16px; border-radius: 10px; font-weight: 600; font-size: 14px; text-decoration: none; cursor: pointer; border: 1px solid var(--stroke); background: transparent; color: var(--text); }
  .btn.primary { background: var(--accent); color: var(--on-accent); border-color: transparent; }
  .fine { margin-top: 16px; font-size: 12.5px; color: var(--text2); }
</style>
</head>
<body>
<main class="card">
  <h1>${escapeHTML(title)}</h1>
  <p>${subtitle}</p>
  <div class="row">
    ${failed ? '' : `<a class="btn primary" id="open-app" href="${escapeHTML(deepLink.toString())}">Open SocialForge</a>`}
    ${failed ? '' : `<button class="btn" id="copy-url" type="button">Copy callback URL</button>`}
  </div>
  <p class="fine">This relay is stateless and never stores your tokens. Single-use authorization codes expire in minutes.</p>
</main>
<script>
(function () {
  try { history.replaceState(null, "", location.pathname); } catch (_) {}
  var deepLink = ${deepLinkJSON};
  var copyURL = ${copyURLJSON};
  var failed = ${failed ? 'true' : 'false'};
  if (!failed) {
    setTimeout(function () { window.location.href = deepLink; }, 120);
  }
  var copyBtn = document.getElementById("copy-url");
  if (copyBtn) {
    copyBtn.addEventListener("click", function () {
      navigator.clipboard.writeText(copyURL).then(function () {
        copyBtn.textContent = "Copied — paste in SocialForge";
      });
    });
  }
})();
</script>
</body>
</html>`;

  return html(page, 200);
}

// MARK: - POST /api/oauth/exchange

interface TokenResponseBody {
  access_token: string;
  refresh_token?: string;
  expires_in?: number;
  scope?: string;
  token_type?: string;
  user_id?: string;
  sandbox?: boolean;
}

export async function handleExchange(request: Request, ctx: RelayContext = defaultCtx()): Promise<Response> {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return json({ error: 'Invalid JSON request body.' }, 400);
  }

  const platformParam = String(body.platform ?? '').trim().toLowerCase();
  const code = String(body.code ?? '').trim();
  const codeVerifier = String(body.code_verifier ?? '').trim();
  const requestedRedirect = String(body.redirect_uri ?? '').trim();
  const sandbox = Boolean(body.sandbox);

  if (!isRelayPlatform(platformParam)) {
    return json({ error: `Unsupported platform: ${platformParam || '(missing)'}` }, 400);
  }
  if (!code || code.length > 4096) {
    return json({ error: 'Missing or invalid authorization code.' }, 400);
  }

  const spec = PROVIDERS[platformParam];
  const creds = spec.credentials(ctx.env);
  if (!creds) {
    return json({ error: `${spec.displayName} is not enabled on this OAuth relay.` }, 503);
  }

  const origin = resolveOrigin(request, ctx.env);
  const expectedRedirect = callbackURI(origin, platformParam);
  if (requestedRedirect && requestedRedirect !== expectedRedirect) {
    return json({ error: 'redirect_uri does not match this relay callback endpoint.' }, 400);
  }
  if (spec.pkceRequired && !codeVerifier) {
    return json({ error: `${spec.displayName} requires code_verifier for PKCE token exchange.` }, 400);
  }

  try {
    const token = await exchangeWithProvider(platformParam, creds, {
      code,
      redirectURI: expectedRedirect,
      codeVerifier: codeVerifier || undefined,
      sandbox,
    }, ctx.fetchImpl);
    return json(token, 200);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return json({ error: sanitizeUpstreamError(msg, [creds.clientSecret]) }, 502);
  }
}

// MARK: - POST /api/oauth/refresh

export async function handleRefresh(request: Request, ctx: RelayContext = defaultCtx()): Promise<Response> {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return json({ error: 'Invalid JSON request body.' }, 400);
  }

  const platformParam = String(body.platform ?? '').trim().toLowerCase();
  const refreshToken = String(body.refresh_token ?? '').trim();
  const accessToken = String(body.access_token ?? '').trim();
  const sandbox = Boolean(body.sandbox);

  if (!isRelayPlatform(platformParam)) {
    return json({ error: `Unsupported platform: ${platformParam || '(missing)'}` }, 400);
  }
  const spec = PROVIDERS[platformParam];
  if (!spec.supportsRefresh) {
    return json({ error: `${spec.displayName} does not support relay token refresh.` }, 400);
  }
  const creds = spec.credentials(ctx.env);
  if (!creds) {
    return json({ error: `${spec.displayName} is not enabled on this OAuth relay.` }, 503);
  }

  try {
    const token = await refreshWithProvider(platformParam, creds, {
      refreshToken: refreshToken || undefined,
      accessToken: accessToken || undefined,
      sandbox,
    }, ctx.fetchImpl);
    return json(token, 200);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return json({ error: sanitizeUpstreamError(msg, [creds.clientSecret, refreshToken, accessToken]) }, 502);
  }
}

// MARK: - Provider Token Exchanges

async function postForm(
  fetchImpl: FetchLike,
  url: string,
  params: Record<string, string>,
  headers: Record<string, string> = {}
): Promise<Record<string, unknown>> {
  const form = new URLSearchParams(params);
  const res = await fetchImpl(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Accept: 'application/json',
      ...headers,
    },
    body: form.toString(),
  });
  const text = await res.text();
  let parsed: Record<string, unknown> = {};
  try {
    parsed = JSON.parse(text) as Record<string, unknown>;
  } catch {
    // non-JSON upstream error
  }
  if (!res.ok) {
    const detail =
      (parsed.error_description as string | undefined) ||
      (parsed.message as string | undefined) ||
      (typeof parsed.error === 'string' ? parsed.error : undefined) ||
      text ||
      `HTTP ${res.status}`;
    throw new Error(`Provider returned HTTP ${res.status}: ${detail}`);
  }
  return parsed;
}

function basicAuth(id: string, secret: string): string {
  return `Basic ${Buffer.from(`${id}:${secret}`).toString('base64')}`;
}

async function exchangeWithProvider(
  platform: RelayPlatform,
  creds: ProviderCredentials,
  args: { code: string; redirectURI: string; codeVerifier?: string; sandbox: boolean },
  fetchImpl: FetchLike
): Promise<TokenResponseBody> {
  switch (platform) {
    case 'pinterest': {
      const apiBase = args.sandbox
        ? 'https://api-sandbox.pinterest.com'
        : creds.extra?.apiBase || 'https://api.pinterest.com';
      const data = await postForm(
        fetchImpl,
        `${apiBase}/v5/oauth/token`,
        {
          grant_type: 'authorization_code',
          code: args.code,
          redirect_uri: args.redirectURI,
        },
        { Authorization: basicAuth(creds.clientId, creds.clientSecret) }
      );
      return normalizeToken(data, args.sandbox);
    }

    case 'facebook': {
      const shortRes = await postForm(fetchImpl, 'https://graph.facebook.com/v25.0/oauth/access_token', {
        client_id: creds.clientId,
        client_secret: creds.clientSecret,
        redirect_uri: args.redirectURI,
        code: args.code,
      });
      const shortToken = String(shortRes.access_token ?? '');
      if (!shortToken) throw new Error('Facebook did not return an access_token.');
      // Upgrade immediately to a 60-day long-lived token (matching MetaAuth.facebookToken).
      const longRes = await postForm(fetchImpl, 'https://graph.facebook.com/v25.0/oauth/access_token', {
        grant_type: 'fb_exchange_token',
        client_id: creds.clientId,
        client_secret: creds.clientSecret,
        fb_exchange_token: shortToken,
      });
      return normalizeToken(longRes);
    }

    case 'instagram_login': {
      const shortRes = await postForm(fetchImpl, 'https://api.instagram.com/oauth/access_token', {
        client_id: creds.clientId,
        client_secret: creds.clientSecret,
        grant_type: 'authorization_code',
        redirect_uri: args.redirectURI,
        code: args.code,
      });
      const shortToken = String(shortRes.access_token ?? '');
      const userId = shortRes.user_id != null ? String(shortRes.user_id) : undefined;
      if (!shortToken) throw new Error('Instagram did not return an access_token.');
      // Exchange for 60-day long-lived token via POST/form (or official GET with secret only on server).
      const longURL = new URL('https://graph.instagram.com/access_token');
      longURL.searchParams.set('grant_type', 'ig_exchange_token');
      longURL.searchParams.set('client_secret', creds.clientSecret);
      longURL.searchParams.set('access_token', shortToken);
      const longHTTP = await fetchImpl(longURL.toString(), { headers: { Accept: 'application/json' } });
      if (longHTTP.ok) {
        const longData = (await longHTTP.json()) as Record<string, unknown>;
        return { ...normalizeToken(longData), user_id: userId };
      }
      return { ...normalizeToken(shortRes), user_id: userId };
    }

    case 'threads': {
      const shortRes = await postForm(fetchImpl, 'https://graph.threads.net/oauth/access_token', {
        client_id: creds.clientId,
        client_secret: creds.clientSecret,
        grant_type: 'authorization_code',
        redirect_uri: args.redirectURI,
        code: args.code,
      });
      const shortToken = String(shortRes.access_token ?? '');
      const userId = shortRes.user_id != null ? String(shortRes.user_id) : undefined;
      if (!shortToken) throw new Error('Threads did not return an access_token.');
      const longURL = new URL('https://graph.threads.net/access_token');
      longURL.searchParams.set('grant_type', 'th_exchange_token');
      longURL.searchParams.set('client_secret', creds.clientSecret);
      longURL.searchParams.set('access_token', shortToken);
      const longHTTP = await fetchImpl(longURL.toString(), { headers: { Accept: 'application/json' } });
      if (longHTTP.ok) {
        const longData = (await longHTTP.json()) as Record<string, unknown>;
        return { ...normalizeToken(longData), user_id: userId };
      }
      return { ...normalizeToken(shortRes), user_id: userId };
    }

    case 'linkedin': {
      const data = await postForm(fetchImpl, 'https://www.linkedin.com/oauth/v2/accessToken', {
        grant_type: 'authorization_code',
        code: args.code,
        redirect_uri: args.redirectURI,
        client_id: creds.clientId,
        client_secret: creds.clientSecret,
      });
      return normalizeToken(data);
    }

    case 'x': {
      const headers: Record<string, string> = {};
      if (creds.clientSecret) {
        headers.Authorization = basicAuth(creds.clientId, creds.clientSecret);
      }
      const data = await postForm(
        fetchImpl,
        'https://api.x.com/2/oauth2/token',
        {
          grant_type: 'authorization_code',
          code: args.code,
          redirect_uri: args.redirectURI,
          client_id: creds.clientId,
          code_verifier: args.codeVerifier ?? '',
        },
        headers
      );
      return normalizeToken(data);
    }

    case 'tiktok': {
      const data = await postForm(fetchImpl, 'https://open.tiktokapis.com/v2/oauth/token/', {
        client_key: creds.clientId,
        client_secret: creds.clientSecret,
        code: args.code,
        grant_type: 'authorization_code',
        redirect_uri: args.redirectURI,
        code_verifier: args.codeVerifier ?? '',
      });
      return normalizeToken(data);
    }

    case 'youtube': {
      const data = await postForm(fetchImpl, 'https://oauth2.googleapis.com/token', {
        code: args.code,
        client_id: creds.clientId,
        client_secret: creds.clientSecret,
        redirect_uri: args.redirectURI,
        grant_type: 'authorization_code',
        code_verifier: args.codeVerifier ?? '',
      });
      return normalizeToken(data);
    }
  }
}

async function refreshWithProvider(
  platform: RelayPlatform,
  creds: ProviderCredentials,
  args: { refreshToken?: string; accessToken?: string; sandbox: boolean },
  fetchImpl: FetchLike
): Promise<TokenResponseBody> {
  switch (platform) {
    case 'pinterest': {
      if (!args.refreshToken) throw new Error('Missing refresh_token.');
      const apiBase = args.sandbox
        ? 'https://api-sandbox.pinterest.com'
        : creds.extra?.apiBase || 'https://api.pinterest.com';
      const data = await postForm(
        fetchImpl,
        `${apiBase}/v5/oauth/token`,
        {
          grant_type: 'refresh_token',
          refresh_token: args.refreshToken,
        },
        { Authorization: basicAuth(creds.clientId, creds.clientSecret) }
      );
      return normalizeToken(data, args.sandbox);
    }

    case 'instagram_login': {
      if (!args.accessToken) throw new Error('Missing access_token for Instagram refresh.');
      const u = new URL('https://graph.instagram.com/refresh_access_token');
      u.searchParams.set('grant_type', 'ig_refresh_token');
      u.searchParams.set('access_token', args.accessToken);
      const res = await fetchImpl(u.toString(), { headers: { Accept: 'application/json' } });
      if (!res.ok) throw new Error(`Instagram refresh failed (HTTP ${res.status}).`);
      return normalizeToken((await res.json()) as Record<string, unknown>);
    }

    case 'threads': {
      if (!args.accessToken) throw new Error('Missing access_token for Threads refresh.');
      const u = new URL('https://graph.threads.net/refresh_access_token');
      u.searchParams.set('grant_type', 'th_refresh_token');
      u.searchParams.set('access_token', args.accessToken);
      const res = await fetchImpl(u.toString(), { headers: { Accept: 'application/json' } });
      if (!res.ok) throw new Error(`Threads refresh failed (HTTP ${res.status}).`);
      return normalizeToken((await res.json()) as Record<string, unknown>);
    }

    case 'linkedin': {
      if (!args.refreshToken) throw new Error('Missing refresh_token.');
      const data = await postForm(fetchImpl, 'https://www.linkedin.com/oauth/v2/accessToken', {
        grant_type: 'refresh_token',
        refresh_token: args.refreshToken,
        client_id: creds.clientId,
        client_secret: creds.clientSecret,
      });
      return normalizeToken(data);
    }

    case 'x': {
      if (!args.refreshToken) throw new Error('Missing refresh_token.');
      const headers: Record<string, string> = {};
      if (creds.clientSecret) {
        headers.Authorization = basicAuth(creds.clientId, creds.clientSecret);
      }
      const data = await postForm(
        fetchImpl,
        'https://api.x.com/2/oauth2/token',
        {
          grant_type: 'refresh_token',
          refresh_token: args.refreshToken,
          client_id: creds.clientId,
        },
        headers
      );
      return normalizeToken(data);
    }

    case 'tiktok': {
      if (!args.refreshToken) throw new Error('Missing refresh_token.');
      const data = await postForm(fetchImpl, 'https://open.tiktokapis.com/v2/oauth/token/', {
        client_key: creds.clientId,
        client_secret: creds.clientSecret,
        grant_type: 'refresh_token',
        refresh_token: args.refreshToken,
      });
      return normalizeToken(data);
    }

    case 'youtube': {
      if (!args.refreshToken) throw new Error('Missing refresh_token.');
      const data = await postForm(fetchImpl, 'https://oauth2.googleapis.com/token', {
        client_id: creds.clientId,
        client_secret: creds.clientSecret,
        grant_type: 'refresh_token',
        refresh_token: args.refreshToken,
      });
      return normalizeToken(data);
    }

    case 'facebook':
      throw new Error('Facebook Page tokens do not refresh via refresh_token.');
  }
}

function normalizeToken(data: Record<string, unknown>, sandbox?: boolean): TokenResponseBody {
  const access = String(data.access_token ?? '');
  if (!access) throw new Error('Provider response did not include an access_token.');
  const refresh = data.refresh_token ? String(data.refresh_token) : undefined;
  const expiresIn = typeof data.expires_in === 'number' ? data.expires_in : undefined;
  const scope = typeof data.scope === 'string' ? data.scope : undefined;
  const tokenType = typeof data.token_type === 'string' ? data.token_type : 'Bearer';
  const userId = data.open_id ? String(data.open_id) : data.user_id != null ? String(data.user_id) : undefined;
  return {
    access_token: access,
    ...(refresh ? { refresh_token: refresh } : {}),
    ...(expiresIn != null ? { expires_in: expiresIn } : {}),
    ...(scope ? { scope } : {}),
    token_type: tokenType,
    ...(userId ? { user_id: userId } : {}),
    ...(sandbox !== undefined ? { sandbox } : {}),
  };
}
