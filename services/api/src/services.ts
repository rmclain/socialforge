import { PgBoss } from 'pg-boss'
import type pg from 'pg'
import type { Config } from './config.ts'
import { decrypt } from './crypto.ts'
import { createDb, type DB } from './db/client.ts'
import type { socialAccounts } from './db/schema.ts'
import { MockPinterestProvider } from './providers/mock.ts'
import { PinterestProvider } from './providers/pinterest.ts'
import type { ProviderAccount, SocialProvider } from './providers/types.ts'
import { loadSpecs, type PlatformSpec } from './spec.ts'
import { createStore, type MediaStore } from './storage.ts'

export const PUBLISH_QUEUE = 'publish'

/** Everything the API and the worker share. Built once per process. */
export interface Services {
  config: Config
  db: DB
  pool: pg.Pool
  boss: PgBoss
  store: MediaStore
  specs: Map<string, PlatformSpec>
  mock: MockPinterestProvider
  pinterest: PinterestProvider
  providerFor (account: typeof socialAccounts.$inferSelect): SocialProvider
  providerAccount (account: typeof socialAccounts.$inferSelect): ProviderAccount
  close (): Promise<void>
}

export async function createServices (config: Config): Promise<Services> {
  const { db, pool } = createDb(config.databaseUrl)
  const boss = new PgBoss({ connectionString: config.databaseUrl, max: 5 })
  boss.on('error', (err) => console.error('pg-boss error', err.message))
  await boss.start()
  await boss.createQueue(PUBLISH_QUEUE, {
    retryLimit: config.retry.limit,
    retryDelay: config.retry.delaySeconds,
    retryBackoff: true,
    retryDelayMax: config.retry.maxDelaySeconds,
    expireInSeconds: 300,
  })
  const mock = new MockPinterestProvider(db)
  const pinterest = new PinterestProvider(config.pinterest?.apiBase)
  return {
    config,
    db,
    pool,
    boss,
    store: createStore(config.storage),
    specs: loadSpecs(config.specDir),
    mock,
    pinterest,
    providerFor (account) {
      if (account.isMock) return mock
      if (account.platform === 'pinterest') return pinterest
      throw new Error(`No provider for ${account.platform}`)
    },
    providerAccount (account) {
      return {
        id: account.id,
        providerAccountId: account.providerAccountId,
        accessToken: account.accessTokenEnc ? decrypt(account.accessTokenEnc, config.tokenEncryptionKey) : null,
        scopes: account.scopes,
      }
    },
    async close () {
      await boss.stop({ graceful: true, timeout: 10_000 })
      await pool.end()
    },
  }
}
