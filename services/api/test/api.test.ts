import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { decrypt, encrypt, signSession, verifySession } from '../src/crypto.ts'
import { classifyStatus } from '../src/providers/types.ts'
import { loadSpecs, validatePublication } from '../src/spec.ts'
import { loadConfig } from '../src/config.ts'
import { png, setup, type TestContext } from './helpers.ts'

describe('units', () => {
  it('encrypts tokens with AES-GCM and detects tampering', () => {
    const key = Buffer.alloc(32, 7)
    const sealed = encrypt('secret-token', key)
    assert.notEqual(sealed, 'secret-token')
    assert.equal(decrypt(sealed, key), 'secret-token')
    const bad = Buffer.from(sealed, 'base64'); bad[bad.length - 1] ^= 1
    assert.throws(() => decrypt(bad.toString('base64'), key))
  })

  it('signs and verifies session tokens', () => {
    const t = signSession({ ws: 'abc', iat: 1 }, 'k'.repeat(32))
    assert.deepEqual(verifySession(t, 'k'.repeat(32)), { ws: 'abc', iat: 1 })
    assert.equal(verifySession(t, 'x'.repeat(32)), null)
    assert.equal(verifySession('garbage', 'k'.repeat(32)), null)
  })

  it('classifies provider statuses for retry decisions', () => {
    assert.equal(classifyStatus(503), 'retryable')
    assert.equal(classifyStatus(429), 'retryable')
    assert.equal(classifyStatus(401), 'auth')
    assert.equal(classifyStatus(400), 'permanent')
  })

  it('enforces the shared platform spec on the server', () => {
    const specs = loadSpecs(loadConfig({ DATABASE_URL: 'x', SESSION_SIGNING_KEY: 'k'.repeat(32), TOKEN_ENCRYPTION_KEY: Buffer.alloc(32).toString('base64') }).specDir)
    const pin = { title: 't', description: 'd', link: 'https://a.example', altText: '', boardId: 'b' }
    const img = { bytes: 1000, contentType: 'image/jpeg' }
    assert.deepEqual(validatePublication(specs.get('pinterest'), pin, ['boards:read', 'pins:write'], img), [])
    assert.match(validatePublication(specs.get('pinterest'), { ...pin, title: 'x'.repeat(101) }, ['boards:read', 'pins:write'], img).join(), /title/)
    assert.match(validatePublication(specs.get('pinterest'), pin, ['boards:read'], img).join(), /pins:write/)
    assert.match(validatePublication(specs.get('pinterest'), pin, ['boards:read', 'pins:write'], { bytes: 30e6, contentType: 'image/jpeg' }).join(), /MB/)
    assert.match(validatePublication(specs.get('x'), pin, [], img).join(), /not available/)
  })

  it('refuses to start without required secrets', () => {
    assert.throws(() => loadConfig({}), /DATABASE_URL, SESSION_SIGNING_KEY, TOKEN_ENCRYPTION_KEY/)
    assert.throws(() => loadConfig({ DATABASE_URL: 'x', SESSION_SIGNING_KEY: 'k'.repeat(32), TOKEN_ENCRYPTION_KEY: 'c2hvcnQ=' }), /32 bytes/)
  })
})

describe('HTTP API', () => {
  let t: TestContext
  const auth = () => ({ authorization: `Bearer ${t.token}` })

  before(async () => { t = await setup() })
  after(async () => { await t.stop() })

  it('GET /health answers 200 with the database up', async () => {
    const res = await t.app.inject({ method: 'GET', url: '/health' })
    assert.equal(res.statusCode, 200)
    assert.deepEqual(res.json(), { status: 'ok', db: 'ok' })
  })

  it('GET /version reports the version', async () => {
    const res = await t.app.inject({ method: 'GET', url: '/version' })
    assert.equal(res.statusCode, 200)
    assert.equal(res.json().name, 'socialforge-api')
    assert.match(res.json().version, /^\d+\.\d+\.\d+/)
  })

  it('rejects requests without a valid token', async () => {
    assert.equal((await t.app.inject({ method: 'GET', url: '/v1/accounts' })).statusCode, 401)
    assert.equal((await t.app.inject({ method: 'GET', url: '/v1/accounts', headers: { authorization: 'Bearer nope.nope' } })).statusCode, 401)
  })

  it('lists the labeled mock account and its boards, never its tokens', async () => {
    const res = await t.app.inject({ method: 'GET', url: '/v1/accounts', headers: auth() })
    const [acct] = res.json().accounts
    assert.equal(acct.isMock, true)
    assert.equal(acct.platform, 'pinterest')
    assert.ok(!('accessTokenEnc' in acct))
    const boards = await t.app.inject({ method: 'GET', url: `/v1/accounts/${acct.id}/boards`, headers: auth() })
    assert.equal(boards.json().boards[0].name, 'Winter Home Edit')
  })

  it('explains that Pinterest OAuth needs app credentials', async () => {
    const res = await t.app.inject({ method: 'POST', url: '/v1/accounts/pinterest/connect', headers: auth(), payload: {} })
    assert.equal(res.statusCode, 501)
    assert.match(res.json().message, /PINTEREST_CLIENT_ID/)
    assert.equal((await t.app.inject({ method: 'POST', url: '/v1/accounts/x/connect', headers: auth(), payload: {} })).statusCode, 501)
  })

  it('stores media by hash and rejects a mismatched hash', async () => {
    const { body, sha } = png(1)
    const a = await t.app.inject({ method: 'PUT', url: `/v1/media/${sha}`, headers: { ...auth(), 'content-type': 'image/png' }, payload: body })
    assert.equal(a.statusCode, 200)
    const b = await t.app.inject({ method: 'PUT', url: `/v1/media/${sha}`, headers: { ...auth(), 'content-type': 'image/png' }, payload: body })
    assert.equal(b.json().mediaId, a.json().mediaId)
    const bad = await t.app.inject({ method: 'PUT', url: `/v1/media/${'0'.repeat(64)}`, headers: { ...auth(), 'content-type': 'image/png' }, payload: body })
    assert.equal(bad.statusCode, 400)
  })

  it('validates publications and is idempotent on the key', async () => {
    const acct = (await t.app.inject({ method: 'GET', url: '/v1/accounts', headers: auth() })).json().accounts[0]
    const { body, sha } = png(2)
    const mediaId = (await t.app.inject({ method: 'PUT', url: `/v1/media/${sha}`, headers: { ...auth(), 'content-type': 'image/png' }, payload: body })).json().mediaId
    const pub = (key: string, title = 'Mug') => ({
      clientId: key, idempotencyKey: `sf-${key}-key`, accountId: acct.id, platform: 'pinterest',
      scheduledAt: new Date(Date.now() + 3_600_000).toISOString(), timeZone: 'America/New_York', mediaId,
      payload: { title, description: 'd', link: 'https://shop.example.com/mug', altText: 'a mug', boardId: 'board_winter' },
    })
    const bad = await t.app.inject({ method: 'POST', url: '/v1/publications', headers: auth(), payload: { publications: [pub('bad', 'x'.repeat(120))] } })
    assert.equal(bad.statusCode, 422)
    const first = await t.app.inject({ method: 'POST', url: '/v1/publications', headers: auth(), payload: { publications: [pub('one')] } })
    assert.equal(first.statusCode, 201)
    const again = await t.app.inject({ method: 'POST', url: '/v1/publications', headers: auth(), payload: { publications: [pub('one')] } })
    assert.equal(again.json().publications[0].id, first.json().publications[0].id)
    const all = await t.app.inject({ method: 'GET', url: '/v1/publications', headers: auth() })
    assert.equal(all.json().publications.filter((p: { clientId: string }) => p.clientId === 'one').length, 1)

    const id = first.json().publications[0].id
    const cancel = await t.app.inject({ method: 'POST', url: `/v1/publications/${id}/cancel`, headers: auth(), payload: {} })
    assert.equal(cancel.json().status, 'canceled')
    assert.equal((await t.app.inject({ method: 'POST', url: `/v1/publications/${id}/cancel`, headers: auth(), payload: {} })).statusCode, 409)
  })

  it('keeps workspaces apart', async () => {
    const other = signSession({ ws: '00000000-0000-4000-8000-000000000000', iat: 0 }, t.svc.config.sessionSigningKey)
    assert.equal((await t.app.inject({ method: 'GET', url: '/v1/publications', headers: { authorization: `Bearer ${other}` } })).statusCode, 401)
  })
})
