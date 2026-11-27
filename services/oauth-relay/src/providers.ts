export type RelayPlatform =
  | 'pinterest'
  | 'facebook'
  | 'instagram_login'
  | 'threads'
  | 'linkedin'
  | 'x'
  | 'tiktok'
  | 'youtube';

export const ALL_PLATFORMS: readonly RelayPlatform[] = [
  'pinterest',
  'facebook',
  'instagram_login',
  'threads',
  'linkedin',
  'x',
  'tiktok',
  'youtube',
] as const;

export interface ProviderCredentials {
  clientId: string;
  clientSecret: string;
  extra?: Record<string, string>;
}

export interface ProviderConfig {
  platform: RelayPlatform;
  displayName: string;
  pkceRequired: boolean;
  supportsRefresh: boolean;
  defaultScopes: string[];
  /** Reads credentials from process.env (or injected env map for testing). Returns null if not configured. */
  credentials(env: Record<string, string | undefined>): ProviderCredentials | null;
  authorizeURL(params: {
    creds: ProviderCredentials;
    redirectURI: string;
    state: string;
    codeChallenge?: string;
    mode?: string;
  }): string;
}

const trim = (v: string | undefined): string => (v ?? '').trim();

export const PROVIDERS: Record<RelayPlatform, ProviderConfig> = {
  pinterest: {
    platform: 'pinterest',
    displayName: 'Pinterest',
    pkceRequired: false,
    supportsRefresh: true,
    defaultScopes: ['user_accounts:read', 'boards:read', 'pins:read', 'pins:write'],
    credentials(env) {
      const clientId = trim(env.PINTEREST_CLIENT_ID);
      const clientSecret = trim(env.PINTEREST_CLIENT_SECRET);
      if (!clientId || !clientSecret) return null;
      const apiBase = trim(env.PINTEREST_API_BASE) || 'https://api.pinterest.com';
      return { clientId, clientSecret, extra: { apiBase } };
    },
    authorizeURL({ creds, redirectURI, state }) {
      const u = new URL('https://www.pinterest.com/oauth/');
      u.searchParams.set('client_id', creds.clientId);
      u.searchParams.set('redirect_uri', redirectURI);
      u.searchParams.set('response_type', 'code');
      u.searchParams.set('scope', this.defaultScopes.join(','));
      u.searchParams.set('state', state);
      return u.toString();
    },
  },

  facebook: {
    platform: 'facebook',
    displayName: 'Facebook & Instagram',
    pkceRequired: false,
    supportsRefresh: false,
    defaultScopes: [
      'pages_show_list',
      'pages_read_engagement',
      'pages_manage_posts',
      'instagram_basic',
      'instagram_content_publish',
      'business_management',
    ],
    credentials(env) {
      const clientId = trim(env.META_APP_ID);
      const clientSecret = trim(env.META_APP_SECRET);
      if (!clientId || !clientSecret) return null;
      const configId = trim(env.META_CONFIG_ID);
      return { clientId, clientSecret, extra: configId ? { configId } : undefined };
    },
    authorizeURL({ creds, redirectURI, state }) {
      const u = new URL('https://www.facebook.com/v25.0/dialog/oauth');
      u.searchParams.set('client_id', creds.clientId);
      u.searchParams.set('redirect_uri', redirectURI);
      u.searchParams.set('response_type', 'code');
      u.searchParams.set('state', state);
      if (creds.extra?.configId) {
        u.searchParams.set('config_id', creds.extra.configId);
      } else {
        u.searchParams.set('scope', this.defaultScopes.join(','));
      }
      return u.toString();
    },
  },

  instagram_login: {
    platform: 'instagram_login',
    displayName: 'Instagram Business Login',
    pkceRequired: false,
    supportsRefresh: true,
    defaultScopes: ['instagram_business_basic', 'instagram_business_content_publish'],
    credentials(env) {
      const clientId = trim(env.INSTAGRAM_APP_ID);
      const clientSecret = trim(env.INSTAGRAM_APP_SECRET);
      if (!clientId || !clientSecret) return null;
      return { clientId, clientSecret };
    },
    authorizeURL({ creds, redirectURI, state }) {
      const u = new URL('https://www.instagram.com/oauth/authorize');
      u.searchParams.set('client_id', creds.clientId);
      u.searchParams.set('redirect_uri', redirectURI);
      u.searchParams.set('response_type', 'code');
      u.searchParams.set('scope', this.defaultScopes.join(','));
      u.searchParams.set('state', state);
      return u.toString();
    },
  },

  threads: {
    platform: 'threads',
    displayName: 'Threads',
    pkceRequired: false,
    supportsRefresh: true,
    defaultScopes: ['threads_basic', 'threads_content_publish'],
    credentials(env) {
      const clientId = trim(env.THREADS_APP_ID);
      const clientSecret = trim(env.THREADS_APP_SECRET);
      if (!clientId || !clientSecret) return null;
      return { clientId, clientSecret };
    },
    authorizeURL({ creds, redirectURI, state }) {
      const u = new URL('https://threads.net/oauth/authorize');
      u.searchParams.set('client_id', creds.clientId);
      u.searchParams.set('redirect_uri', redirectURI);
      u.searchParams.set('response_type', 'code');
      u.searchParams.set('scope', this.defaultScopes.join(','));
      u.searchParams.set('state', state);
      return u.toString();
    },
  },

  linkedin: {
    platform: 'linkedin',
    displayName: 'LinkedIn',
    pkceRequired: false,
    supportsRefresh: true,
    defaultScopes: ['openid', 'profile', 'w_member_social'],
    credentials(env) {
      const clientId = trim(env.LINKEDIN_CLIENT_ID);
      const clientSecret = trim(env.LINKEDIN_CLIENT_SECRET);
      if (!clientId || !clientSecret) return null;
      return { clientId, clientSecret };
    },
    authorizeURL({ creds, redirectURI, state, mode }) {
      const scopes =
        mode === 'organization'
          ? ['openid', 'profile', 'w_member_social', 'w_organization_social', 'r_organization_admin']
          : this.defaultScopes;
      const u = new URL('https://www.linkedin.com/oauth/v2/authorization');
      u.searchParams.set('response_type', 'code');
      u.searchParams.set('client_id', creds.clientId);
      u.searchParams.set('redirect_uri', redirectURI);
      u.searchParams.set('scope', scopes.join(' '));
      u.searchParams.set('state', state);
      return u.toString();
    },
  },

  x: {
    platform: 'x',
    displayName: 'X',
    pkceRequired: true,
    supportsRefresh: true,
    defaultScopes: ['tweet.read', 'tweet.write', 'users.read', 'media.write', 'offline.access'],
    credentials(env) {
      const clientId = trim(env.X_CLIENT_ID);
      if (!clientId) return null;
      // X supports both public PKCE clients (empty secret) and confidential clients.
      return { clientId, clientSecret: trim(env.X_CLIENT_SECRET) };
    },
    authorizeURL({ creds, redirectURI, state, codeChallenge }) {
      const u = new URL('https://x.com/i/oauth2/authorize');
      u.searchParams.set('response_type', 'code');
      u.searchParams.set('client_id', creds.clientId);
      u.searchParams.set('redirect_uri', redirectURI);
      u.searchParams.set('scope', this.defaultScopes.join(' '));
      u.searchParams.set('state', state);
      u.searchParams.set('code_challenge', codeChallenge ?? '');
      u.searchParams.set('code_challenge_method', 'S256');
      return u.toString();
    },
  },

  tiktok: {
    platform: 'tiktok',
    displayName: 'TikTok',
    pkceRequired: true,
    supportsRefresh: true,
    defaultScopes: ['user.info.basic', 'video.upload', 'video.publish'],
    credentials(env) {
      const clientId = trim(env.TIKTOK_CLIENT_KEY);
      const clientSecret = trim(env.TIKTOK_CLIENT_SECRET);
      if (!clientId || !clientSecret) return null;
      return { clientId, clientSecret };
    },
    authorizeURL({ creds, redirectURI, state, codeChallenge }) {
      const u = new URL('https://www.tiktok.com/v2/auth/authorize/');
      u.searchParams.set('client_key', creds.clientId);
      u.searchParams.set('redirect_uri', redirectURI);
      u.searchParams.set('response_type', 'code');
      u.searchParams.set('scope', this.defaultScopes.join(','));
      u.searchParams.set('state', state);
      u.searchParams.set('code_challenge', codeChallenge ?? '');
      u.searchParams.set('code_challenge_method', 'S256');
      return u.toString();
    },
  },

  youtube: {
    platform: 'youtube',
    displayName: 'YouTube',
    pkceRequired: true,
    supportsRefresh: true,
    defaultScopes: [
      'https://www.googleapis.com/auth/youtube.upload',
      'https://www.googleapis.com/auth/youtube.readonly',
    ],
    credentials(env) {
      const clientId = trim(env.YOUTUBE_CLIENT_ID);
      const clientSecret = trim(env.YOUTUBE_CLIENT_SECRET);
      if (!clientId || !clientSecret) return null;
      return { clientId, clientSecret };
    },
    authorizeURL({ creds, redirectURI, state, codeChallenge }) {
      const u = new URL('https://accounts.google.com/o/oauth2/v2/auth');
      u.searchParams.set('client_id', creds.clientId);
      u.searchParams.set('redirect_uri', redirectURI);
      u.searchParams.set('response_type', 'code');
      u.searchParams.set('scope', this.defaultScopes.join(' '));
      u.searchParams.set('access_type', 'offline');
      u.searchParams.set('prompt', 'consent');
      u.searchParams.set('state', state);
      u.searchParams.set('code_challenge', codeChallenge ?? '');
      u.searchParams.set('code_challenge_method', 'S256');
      return u.toString();
    },
  },
};

export function isRelayPlatform(value: string): value is RelayPlatform {
  return (ALL_PLATFORMS as readonly string[]).includes(value);
}

export function resolveOrigin(request: Request, env: Record<string, string | undefined>): string {
  const configured = trim(env.PUBLIC_ORIGIN).replace(/\/+$/, '');
  if (configured) return configured;
  const u = new URL(request.url);
  const proto = request.headers.get('x-forwarded-proto')?.split(',')[0]?.trim() || u.protocol.replace(/:$/, '');
  const host = request.headers.get('x-forwarded-host')?.split(',')[0]?.trim() || request.headers.get('host') || u.host;
  return `${proto}://${host}`;
}

export function callbackURI(origin: string, platform: RelayPlatform): string {
  return `${origin}/api/oauth/callback/${platform}`;
}
