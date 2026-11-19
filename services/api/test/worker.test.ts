import { after, before, beforeEach, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { eq, inArray } from 'drizzle-orm'
import { mockProviderPosts, publicationAttempts, publications, socialAccounts } from '../src/db/schema.ts'
import { startWorker } from '../src/worker.ts'
import { png, setup, waitFor, type TestContext } from './helpers.ts'

/**
 * Scenario A and D against the mock provider: posts scheduled through the API
 * are published by the worker on their own, with retries and reconciliation.
 */
describe('publishing worker', () => {
  let t: TestContext
  let accountId: string
  let mediaId: string
  const auth = () => ({ authorization: `Bearer ${t.token}` })
  let n = 0

  before(async () => {
    t = await setup()
    accountId = (await t.app.inject({ method: 'GET', url: '/v1/accounts', headers: auth() })).json().accounts[0].id
    const { body, sha } = png(9)
    mediaId = (await t.app.inject({ method: 'PUT', url: `/v1/media/${sha}`, headers: { ...auth(), 'content-type': 'image/png' }, payload: body })).json().mediaId
    await startWorker(t.svc, () => {})
  })
  after(async () => { await t.stop() })
  beforeEach(() => { t.svc.mock.script = [] })

  async function schedule (count: number, inMs = 500): Promise<string[]> {
    const pubs = Array.from({ length: count }, (_, i) => {
      const k = `${++n}`
      return {
        clientId: `c${k}`, idempotencyKey: `sf-test-${k}`, accountId, platform: 'pinterest',
        scheduledAt: new Date(Date.now() + inMs + i * 20).toISOString(), timeZone: 'America/New_York', mediaId,
        payload: { title: `Product ${k}`, description: 'Hand-thrown.', link: `https://shop.example.com/p/${k}`, altText: 'A mug', boardId: 'board_winter' },
      }
    })
    const res = await t.app.inject({ method: 'POST', url: '/v1/publications', headers: auth(), payload: { publications: pubs } })
    assert.equal(res.statusCode, 201, res.body)
    return res.json().publications.map((p: { id: string }) => p.id)
  }

  const rows = (ids: string[]) => t.svc.db.select().from(publications).where(inArray(publications.id, ids))
  const attempts = (id: string) => t.svc.db.select().from(publicationAttempts).where(eq(publicationAttempts.publicationId, id)).orderBy(publicationAttempts.attempt)

  it('Scenario A: publishes 30 scheduled Pins, each once, with results recorded', async () => {
    const ids = await schedule(30)
    const done = await waitFor(async () => {
      const r = await rows(ids)
      return r.every((p) => p.status === 'published') && r
    }, 60_000)
    assert.equal(done.length, 30)
    assert.ok(done.every((p) => p.publishedUrl?.startsWith('https://mock.pinterest.local/pin/')))
    const posts = await t.svc.db.select().from(mockProviderPosts).where(inArray(mockProviderPosts.idempotencyKey, done.map((p) => p.idempotencyKey)))
    assert.equal(posts.length, 30, 'exactly one post per publication')
    // Scenario D: the app syncs results later through the API.
    const synced = (await t.app.inject({ method: 'GET', url: '/v1/publications', headers: auth() })).json().publications
    assert.equal(synced.filter((p: { status: string }) => p.status === 'published').length >= 30, true)
  })

  it('does not publish before the scheduled time', async () => {
    const [id] = await schedule(1, 4_000)
    await new Promise((r) => setTimeout(r, 1_500))
    assert.equal((await rows([id]))[0].status, 'scheduled')
    await waitFor(async () => (await rows([id]))[0].status === 'published', 20_000)
  })

  it('retries a 503 with backoff, then succeeds', async () => {
    t.svc.mock.script = ['retryable', 'ok']
    const [id] = await schedule(1)
    await waitFor(async () => (await rows([id]))[0].status === 'published', 30_000)
    const a = await attempts(id)
    assert.deepEqual(a.map((x) => x.outcome), ['retryable', 'success'])
    assert.equal(a[0].httpStatus, 503)
  })

  it('reconciles an uncertain attempt instead of posting twice', async () => {
    t.svc.mock.script = ['uncertain-after-create']
    const [id] = await schedule(1)
    await waitFor(async () => (await rows([id]))[0].status === 'published', 30_000)
    assert.deepEqual((await attempts(id)).map((x) => x.outcome), ['uncertain', 'reconciled'])
    const [pub] = await rows([id])
    const posts = await t.svc.db.select().from(mockProviderPosts).where(eq(mockProviderPosts.idempotencyKey, pub.idempotencyKey))
    assert.equal(posts.length, 1)
  })

  it('fails a permanent error at once', async () => {
    t.svc.mock.script = ['permanent']
    const [id] = await schedule(1)
    const [pub] = await waitFor(async () => { const r = await rows([id]); return r[0].status === 'failed' && r }, 20_000)
    assert.match(pub.lastError ?? '', /400/)
    assert.equal((await attempts(id)).length, 1)
  })

  it('gives up after the retry limit', async () => {
    t.svc.mock.script = ['retryable', 'retryable', 'retryable', 'retryable']
    const [id] = await schedule(1)
    const [pub] = await waitFor(async () => { const r = await rows([id]); return r[0].status === 'failed' && r }, 60_000)
    assert.match(pub.lastError ?? '', /gave up after 4 attempts/)
    assert.equal((await attempts(id)).length, 4)
  })

  it('a canceled post is never published', async () => {
    const [id] = await schedule(1, 2_000)
    await t.app.inject({ method: 'POST', url: `/v1/publications/${id}/cancel`, headers: auth(), payload: {} })
    await new Promise((r) => setTimeout(r, 3_500))
    assert.equal((await rows([id]))[0].status, 'canceled')
    assert.equal((await attempts(id)).length, 0)
  })

  it('an auth failure marks the account expired and stops (scenario E on the server)', async () => {
    t.svc.mock.script = ['auth']
    const [id] = await schedule(1)
    const [pub] = await waitFor(async () => { const r = await rows([id]); return r[0].status === 'failed' && r }, 20_000)
    assert.match(pub.lastError ?? '', /Reconnect/)
    const [acct] = await t.svc.db.select().from(socialAccounts).where(eq(socialAccounts.id, accountId))
    assert.equal(acct.status, 'expired')
    // New posts for an expired account are refused up front.
    const res = await t.app.inject({ method: 'POST', url: '/v1/publications', headers: auth(), payload: { publications: [{
      clientId: 'late', idempotencyKey: 'sf-late-1234', accountId, platform: 'pinterest', scheduledAt: new Date().toISOString(),
      timeZone: 'UTC', mediaId, payload: { title: 't', description: '', link: '', altText: '', boardId: 'board_winter' },
    }] } })
    assert.equal(res.statusCode, 422)
    assert.match(res.json().message, /reconnect/)
  })
})
