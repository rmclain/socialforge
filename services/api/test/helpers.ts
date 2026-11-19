import { execFileSync, spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomBytes, createHash } from 'node:crypto'
import { buildApp } from '../src/app.ts'
import { loadConfig } from '../src/config.ts'
import { signSession } from '../src/crypto.ts'
import { runMigrations } from '../src/db/client.ts'
import { workspaces } from '../src/db/schema.ts'
import { createServices, type Services } from '../src/services.ts'

async function freePort (): Promise<number> {
  return new Promise((resolve) => {
    const s = createServer().listen(0, '127.0.0.1', () => {
      const port = (s.address() as { port: number }).port
      s.close(() => resolve(port))
    })
  })
}

/**
 * A Postgres for tests: TEST_DATABASE_URL when set (CI, Compose), otherwise a
 * throwaway cluster from the local initdb/pg_ctl, deleted afterwards.
 */
export async function startPostgres (): Promise<{ url: string, stop: () => void }> {
  if (process.env.TEST_DATABASE_URL) return { url: process.env.TEST_DATABASE_URL, stop: () => {} }
  const dir = mkdtempSync(join(tmpdir(), 'sf-pg-'))
  const port = await freePort()
  execFileSync('initdb', ['-D', dir, '-U', 'postgres', '--auth=trust', '-E', 'UTF8', '--no-sync'], { stdio: 'ignore' })
  execFileSync('pg_ctl', ['-D', dir, '-o', `-p ${port} -k ${dir} -c listen_addresses=127.0.0.1 -c fsync=off`, '-l', join(dir, 'log'), '-w', 'start'], { stdio: 'ignore' })
  execFileSync('createdb', ['-h', '127.0.0.1', '-p', String(port), '-U', 'postgres', 'socialforge_test'], { stdio: 'ignore' })
  return {
    url: `postgres://postgres@127.0.0.1:${port}/socialforge_test`,
    stop: () => {
      spawnSync('pg_ctl', ['-D', dir, '-m', 'immediate', 'stop'], { stdio: 'ignore' })
      rmSync(dir, { recursive: true, force: true })
    },
  }
}

export interface TestContext {
  svc: Services
  app: Awaited<ReturnType<typeof buildApp>>
  token: string
  workspaceId: string
  stop: () => Promise<void>
}

export async function setup (env: Record<string, string> = {}): Promise<TestContext> {
  const pg = await startPostgres()
  const config = loadConfig({
    DATABASE_URL: pg.url,
    SESSION_SIGNING_KEY: randomBytes(32).toString('hex'),
    TOKEN_ENCRYPTION_KEY: randomBytes(32).toString('base64'),
    MOCK_PROVIDERS: '1',
    MEDIA_DIR: mkdtempSync(join(tmpdir(), 'sf-media-')),
    PUBLISH_RETRY_DELAY_SECONDS: '1',
    PUBLISH_RETRY_MAX_DELAY_SECONDS: '2',
    PUBLISH_RETRY_LIMIT: '3',
    WORKER_POLL_SECONDS: '0.5',
    ...env,
  })
  const svc = await createServices(config)
  await runMigrations(svc.db)
  const [ws] = await svc.db.insert(workspaces).values({ name: `Test ${randomBytes(4).toString('hex')}` }).returning()
  const app = await buildApp(svc, { logger: false })
  return {
    svc,
    app,
    workspaceId: ws.id,
    token: signSession({ ws: ws.id, iat: 0 }, config.sessionSigningKey),
    stop: async () => {
      await app.close()
      await svc.close()
      pg.stop()
    },
  }
}

/** A tiny valid PNG (1×1), so uploads pass the content checks. */
export function png (seed = 0): { body: Buffer, sha: string } {
  const base = Buffer.from('89504e470d0a1a0a0000000d4948445200000001000000010806000000' + '1f15c4890000000d49444154789c6360f8cf00000301010018dd8db00000000049454e44ae426082', 'hex')
  const body = Buffer.concat([base, Buffer.from([seed])])
  return { body, sha: createHash('sha256').update(body).digest('hex') }
}

export async function waitFor<T> (fn: () => Promise<T | null | undefined | false>, ms = 30_000, step = 250): Promise<T> {
  const until = Date.now() + ms
  for (;;) {
    const v = await fn()
    if (v) return v
    if (Date.now() > until) throw new Error('timed out waiting')
    await new Promise((r) => setTimeout(r, step))
  }
}
