import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

/** Settings from the environment. Secrets are read here and nowhere else, and never logged. */
export interface Config {
  port: number
  host: string
  databaseUrl: string
  publicBaseUrl: string
  appVersion: string
  commit: string | null
  sessionSigningKey: string
  tokenEncryptionKey: Buffer
  mockProviders: boolean
  specDir: string
  storage: { kind: 's3', endpoint: string, bucket: string, accessKeyId: string, secretAccessKey: string, region: string }
    | { kind: 'fs', dir: string }
  pinterest: { clientId: string, clientSecret: string, apiBase: string } | null
  retry: { limit: number, delaySeconds: number, maxDelaySeconds: number }
  pollingIntervalSeconds: number
}

const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')) as { version: string }

export class ConfigError extends Error {}

export function loadConfig (env: NodeJS.ProcessEnv = process.env): Config {
  const missing: string[] = []
  const need = (name: string): string => {
    const v = env[name]
    if (!v) missing.push(name)
    return v ?? ''
  }
  const databaseUrl = need('DATABASE_URL')
  const sessionSigningKey = need('SESSION_SIGNING_KEY')
  const encKey = need('TOKEN_ENCRYPTION_KEY')
  if (missing.length) throw new ConfigError(`Missing environment variables: ${missing.join(', ')}. See .env.example.`)

  const tokenEncryptionKey = Buffer.from(encKey, 'base64')
  if (tokenEncryptionKey.length !== 32) {
    throw new ConfigError('TOKEN_ENCRYPTION_KEY must be 32 bytes, base64 encoded (openssl rand -base64 32).')
  }
  if (sessionSigningKey.length < 32) throw new ConfigError('SESSION_SIGNING_KEY must be at least 32 characters.')

  const port = Number(env.PORT ?? 8787)
  const storage: Config['storage'] = env.S3_ENDPOINT
    ? {
        kind: 's3',
        endpoint: env.S3_ENDPOINT,
        bucket: env.S3_BUCKET ?? 'socialforge-media',
        accessKeyId: env.S3_ACCESS_KEY_ID ?? '',
        secretAccessKey: env.S3_SECRET_ACCESS_KEY ?? '',
        region: env.S3_REGION ?? 'auto',
      }
    : { kind: 'fs', dir: resolve(env.MEDIA_DIR ?? '.data/media') }

  return {
    port,
    host: env.HOST ?? '127.0.0.1',
    databaseUrl,
    publicBaseUrl: (env.PUBLIC_BASE_URL ?? `http://127.0.0.1:${port}`).replace(/\/$/, ''),
    appVersion: env.APP_VERSION || pkg.version,
    commit: env.GIT_COMMIT || null,
    sessionSigningKey,
    tokenEncryptionKey,
    mockProviders: env.MOCK_PROVIDERS === '1',
    specDir: resolve(env.SPEC_DIR ?? new URL('../../../spec/platforms', import.meta.url).pathname),
    storage,
    pinterest: env.PINTEREST_CLIENT_ID && env.PINTEREST_CLIENT_SECRET
      ? { clientId: env.PINTEREST_CLIENT_ID, clientSecret: env.PINTEREST_CLIENT_SECRET, apiBase: env.PINTEREST_API_BASE ?? 'https://api.pinterest.com' }
      : null,
    retry: {
      limit: Number(env.PUBLISH_RETRY_LIMIT ?? 5),
      delaySeconds: Number(env.PUBLISH_RETRY_DELAY_SECONDS ?? 30),
      maxDelaySeconds: Number(env.PUBLISH_RETRY_MAX_DELAY_SECONDS ?? 3600),
    },
    pollingIntervalSeconds: Number(env.WORKER_POLL_SECONDS ?? 2),
  }
}
