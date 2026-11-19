// Makes an access token for the Mac app (Settings > Publishing > Access token).
//   npm run token -- "Oak & Ember"
// Creates the workspace when it does not exist. Prints only the token.
import { eq } from 'drizzle-orm'
import { loadConfig } from '../src/config.ts'
import { signSession } from '../src/crypto.ts'
import { createDb, runMigrations } from '../src/db/client.ts'
import { workspaces } from '../src/db/schema.ts'

const name = process.argv[2] ?? 'My Workspace'
const config = loadConfig()
const { db, pool } = createDb(config.databaseUrl)
await runMigrations(db)
await db.insert(workspaces).values({ name }).onConflictDoNothing()
const [ws] = await db.select().from(workspaces).where(eq(workspaces.name, name))
await pool.end()
console.error(`workspace: ${ws.name} (${ws.id})`)
console.log(signSession({ ws: ws.id, iat: Math.floor(Date.now() / 1000) }, config.sessionSigningKey))
