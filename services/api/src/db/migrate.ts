// Applies drizzle/*.sql in order. Safe to run on every deploy.
import { loadConfig } from '../config.ts'
import { createDb, runMigrations } from './client.ts'

const config = loadConfig()
const { db, pool } = createDb(config.databaseUrl)
await runMigrations(db)
await pool.end()
console.log('migrations applied')
