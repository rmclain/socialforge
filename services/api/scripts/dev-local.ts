// Local development without Docker:
//   npm run dev:local
// Starts a private Postgres in .data/pg (Homebrew initdb/pg_ctl), runs the API
// with the worker in-process and the labeled mock Pinterest provider, and prints
// an access token for the "Local Dev" workspace. Stops Postgres on Ctrl-C.
// When SESSION_SIGNING_KEY / TOKEN_ENCRYPTION_KEY are not in .env, it makes
// temporary ones for this run only (never written to disk), so tokens from an
// earlier run stop working after a restart.
import { execFileSync, spawnSync } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { existsSync, mkdirSync } from 'node:fs'
import { resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const pgDir = resolve(root, '.data/pg')
const pgPort = process.env.DEV_PG_PORT ?? '55432'
let startedPg = false

if (!process.env.DATABASE_URL) {
  if (!existsSync(resolve(pgDir, 'PG_VERSION'))) {
    mkdirSync(pgDir, { recursive: true })
    execFileSync('initdb', ['-D', pgDir, '-U', 'postgres', '--auth=trust', '-E', 'UTF8'], { stdio: 'ignore' })
  }
  const running = spawnSync('pg_ctl', ['-D', pgDir, 'status'], { stdio: 'ignore' }).status === 0
  if (!running) {
    execFileSync('pg_ctl', ['-D', pgDir, '-o', `-p ${pgPort} -k ${pgDir} -c listen_addresses=127.0.0.1`, '-l', resolve(pgDir, 'log'), '-w', 'start'], { stdio: 'ignore' })
    startedPg = true
  }
  spawnSync('createdb', ['-h', '127.0.0.1', '-p', pgPort, '-U', 'postgres', 'socialforge'], { stdio: 'ignore' })
  process.env.DATABASE_URL = `postgres://postgres@127.0.0.1:${pgPort}/socialforge`
}
if (!process.env.SESSION_SIGNING_KEY) {
  process.env.SESSION_SIGNING_KEY = randomBytes(32).toString('hex')
  console.error('dev-local: no SESSION_SIGNING_KEY in .env; using a temporary one for this run')
}
if (!process.env.TOKEN_ENCRYPTION_KEY) {
  process.env.TOKEN_ENCRYPTION_KEY = randomBytes(32).toString('base64')
  console.error('dev-local: no TOKEN_ENCRYPTION_KEY in .env; using a temporary one for this run')
}
process.env.MOCK_PROVIDERS ??= '1'
process.env.RUN_WORKER ??= '1'
process.env.MEDIA_DIR ??= resolve(root, '.data/media')

const stopPg = () => {
  if (startedPg) spawnSync('pg_ctl', ['-D', pgDir, '-m', 'fast', 'stop'], { stdio: 'ignore' })
}
process.on('exit', stopPg)

await import('../src/server.ts')

const { eq } = await import('drizzle-orm')
const { createDb } = await import('../src/db/client.ts')
const { workspaces } = await import('../src/db/schema.ts')
const { signSession } = await import('../src/crypto.ts')
const { db, pool } = createDb(process.env.DATABASE_URL)
await db.insert(workspaces).values({ name: 'Local Dev' }).onConflictDoNothing()
const [ws] = await db.select().from(workspaces).where(eq(workspaces.name, 'Local Dev'))
await pool.end()
const token = signSession({ ws: ws.id, iat: Math.floor(Date.now() / 1000) }, process.env.SESSION_SIGNING_KEY)
console.error(`\ndev-local: API on http://127.0.0.1:${process.env.PORT ?? 8787} · workspace "Local Dev"\ndev-local: paste this into SocialForge > Settings > Publishing > Access token:\n${token}\n`)
