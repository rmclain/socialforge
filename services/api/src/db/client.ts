import { drizzle, type NodePgDatabase } from 'drizzle-orm/node-postgres'
import { migrate } from 'drizzle-orm/node-postgres/migrator'
import pg from 'pg'
import * as schema from './schema.ts'

export type DB = NodePgDatabase<typeof schema>

export function createDb (url: string): { db: DB, pool: pg.Pool } {
  const pool = new pg.Pool({ connectionString: url, max: 10, idleTimeoutMillis: 30_000 })
  return { db: drizzle(pool, { schema }), pool }
}

export async function runMigrations (db: DB): Promise<void> {
  await migrate(db, { migrationsFolder: new URL('../../drizzle', import.meta.url).pathname })
}

export { schema }
