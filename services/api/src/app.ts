import { createHash } from 'node:crypto'
import Fastify, { type FastifyInstance } from 'fastify'
import { and, desc, eq, gt, inArray } from 'drizzle-orm'
import { encrypt, randomToken, verifySession } from './crypto.ts'
import { media, oauthStates, publications, socialAccounts, workspaces } from './db/schema.ts'
import { PINTEREST_SCOPES } from './providers/pinterest.ts'
import { ProviderError } from './providers/types.ts'
import { PUBLISH_QUEUE, type Services } from './services.ts'
import { validatePublication, type PinPayload } from './spec.ts'

declare module 'fastify' {
  interface FastifyRequest { workspaceId: string }
}

const IMAGE_TYPES = ['image/jpeg', 'image/png', 'image/webp']

export async function buildApp (svc: Services, opts: { logger?: boolean } = {}): Promise<FastifyInstance> {
  const app = Fastify({
    logger: opts.logger === false ? false : {
      level: process.env.LOG_LEVEL ?? 'info',
      // Tokens and cookies never reach the logs.
      redact: ['req.headers.authorization', 'req.headers.cookie'],
    },
    bodyLimit: 1_048_576,
  })
  app.decorateRequest('workspaceId', '')
  // Raw image bodies for media upload.
  app.addContentTypeParser(IMAGE_TYPES, { parseAs: 'buffer', bodyLimit: 25 * 1_048_576 }, (_req, body, done) => done(null, body))

  app.setErrorHandler((err: Error & { statusCode?: number, validation?: unknown }, req, reply) => {
    const status = err.statusCode && err.statusCode >= 400 ? err.statusCode : 500
    if (status >= 500) req.log.error({ err }, 'request failed')
    reply.code(status).send({ error: status >= 500 ? 'internal_error' : 'bad_request', message: status >= 500 ? 'Something went wrong on the server.' : err.message })
  })

  app.addHook('onSend', async (_req, reply, payload) => {
    reply.header('X-Content-Type-Options', 'nosniff')
    reply.header('Referrer-Policy', 'no-referrer')
    reply.header('X-Frame-Options', 'DENY')
    return payload
  })

  // --- Public ---

  app.get('/health', async (_req, reply) => {
    try {
      await svc.pool.query('select 1')
      return { status: 'ok', db: 'ok' }
    } catch {
      return reply.code(503).send({ status: 'down', db: 'unreachable' })
    }
  })

  app.get('/version', async () => ({ name: 'socialforge-api', version: svc.config.appVersion, commit: svc.config.commit }))

  app.get('/v1/capabilities', async () => ({
    apiVersion: 1,
    platforms: ['pinterest'],
    features: ['schedule', 'cancel', 'reconcile', 'media_upload'],
    maxUploadBytes: 25 * 1_048_576,
  }))

  // OAuth callback: bound to a one-time state, not to a bearer token (the browser has none).
  app.get<{ Params: { platform: string }, Querystring: { code?: string, state?: string, error?: string } }>(
    '/v1/oauth/:platform/callback', async (req, reply) => {
      const { code, state, error } = req.query
      reply.type('text/html')
      if (error || !code || !state) return reply.code(400).send(page('Connection was not completed.', error ?? 'Missing code.'))
      const [row] = await svc.db.delete(oauthStates)
        .where(and(eq(oauthStates.state, state), eq(oauthStates.platform, req.params.platform), gt(oauthStates.expiresAt, new Date())))
        .returning()
      if (!row) return reply.code(400).send(page('This link has expired.', 'Start the connection again from SocialForge.'))
      const cfg = svc.config.pinterest
      if (req.params.platform !== 'pinterest' || !cfg) return reply.code(501).send(page('Not available.', 'This platform is not configured.'))
      try {
        const tokens = await svc.pinterest.exchangeCode(code, redirectUri(svc, 'pinterest'), cfg.clientId, cfg.clientSecret)
        const user = await svc.pinterest.userAccount(tokens.access_token)
        const values = {
          workspaceId: row.workspaceId,
          platform: 'pinterest',
          providerAccountId: user.id ?? user.username,
          name: user.business_name || user.username,
          handle: `@${user.username}`,
          status: 'connected',
          scopes: (tokens.scope ?? '').split(/[ ,]+/).filter(Boolean),
          accessTokenEnc: encrypt(tokens.access_token, svc.config.tokenEncryptionKey),
          refreshTokenEnc: tokens.refresh_token ? encrypt(tokens.refresh_token, svc.config.tokenEncryptionKey) : null,
          tokenExpiresAt: tokens.expires_in ? new Date(Date.now() + tokens.expires_in * 1000) : null,
          updatedAt: new Date(),
        }
        await svc.db.insert(socialAccounts).values(values).onConflictDoUpdate({
          target: [socialAccounts.workspaceId, socialAccounts.platform, socialAccounts.providerAccountId], set: values,
        })
        return page('Pinterest is connected.', 'Return to SocialForge and press Refresh in Social Accounts.')
      } catch (err) {
        req.log.warn({ err: (err as Error).message }, 'oauth exchange failed')
        return reply.code(502).send(page('Pinterest did not accept the connection.', (err as Error).message))
      }
    })

  // --- Authenticated (bearer session token) ---

  await app.register(async (v1) => {
    v1.addHook('onRequest', async (req, reply) => {
      const header = req.headers.authorization ?? ''
      const claims = header.startsWith('Bearer ') ? verifySession(header.slice(7), svc.config.sessionSigningKey) : null
      if (!claims) return reply.code(401).send({ error: 'unauthorized', message: 'Missing or invalid access token.' })
      const [ws] = await svc.db.select({ id: workspaces.id }).from(workspaces).where(eq(workspaces.id, claims.ws))
      if (!ws) return reply.code(401).send({ error: 'unauthorized', message: 'The workspace for this token no longer exists.' })
      req.workspaceId = ws.id
    })

    v1.get('/accounts', async (req) => {
      if (svc.config.mockProviders) await ensureMockAccount(svc, req.workspaceId)
      const rows = await svc.db.select().from(socialAccounts).where(eq(socialAccounts.workspaceId, req.workspaceId)).orderBy(socialAccounts.name)
      return { accounts: rows.map(accountView) }
    })

    v1.get<{ Params: { id: string } }>('/accounts/:id/boards', async (req, reply) => {
      const account = await findAccount(svc, req.workspaceId, req.params.id)
      if (!account) return reply.code(404).send({ error: 'not_found', message: 'No such account.' })
      try {
        return { boards: await svc.providerFor(account).listBoards(svc.providerAccount(account)) }
      } catch (err) {
        if (err instanceof ProviderError && err.kind === 'auth') {
          await svc.db.update(socialAccounts).set({ status: 'expired', updatedAt: new Date() }).where(eq(socialAccounts.id, account.id))
        }
        return reply.code(502).send({ error: 'provider_error', message: (err as Error).message })
      }
    })

    v1.post<{ Params: { platform: string } }>('/accounts/:platform/connect', async (req, reply) => {
      const { platform } = req.params
      if (platform !== 'pinterest') {
        return reply.code(501).send({
          error: 'not_available',
          message: `The optional publishing service currently supports Pinterest only. Connect ${platform} directly on your Mac in Connections.`,
        })
      }
      const cfg = svc.config.pinterest
      if (!cfg) return reply.code(501).send({ error: 'not_configured', message: 'Set PINTEREST_CLIENT_ID and PINTEREST_CLIENT_SECRET on the publishing service to connect Pinterest.' })
      const state = randomToken()
      await svc.db.insert(oauthStates).values({ state, workspaceId: req.workspaceId, platform, expiresAt: new Date(Date.now() + 10 * 60_000) })
      const url = new URL('https://www.pinterest.com/oauth/')
      url.search = new URLSearchParams({
        client_id: cfg.clientId, redirect_uri: redirectUri(svc, platform), response_type: 'code', scope: PINTEREST_SCOPES.join(','), state,
      }).toString()
      return { authorizeUrl: url.toString() }
    })

    v1.put<{ Params: { sha256: string } }>('/media/:sha256', {
      schema: { params: { type: 'object', properties: { sha256: { type: 'string', pattern: '^[a-f0-9]{64}$' } }, required: ['sha256'] } },
    }, async (req, reply) => {
      const body = req.body
      if (!Buffer.isBuffer(body)) return reply.code(415).send({ error: 'unsupported_media_type', message: `Send ${IMAGE_TYPES.join(', ')}.` })
      const actual = createHash('sha256').update(body).digest('hex')
      if (actual !== req.params.sha256) return reply.code(400).send({ error: 'hash_mismatch', message: 'The upload does not match its SHA-256.' })
      const [existing] = await svc.db.select().from(media).where(and(eq(media.workspaceId, req.workspaceId), eq(media.sha256, actual)))
      if (existing) return { mediaId: existing.id, sha256: actual }
      const rawType = (req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase()
      if (!IMAGE_TYPES.includes(rawType)) {
        return reply.code(415).send({ error: 'unsupported_media_type', message: `Send ${IMAGE_TYPES.join(', ')}.` })
      }
      const key = `${req.workspaceId}/${actual}`
      await svc.store.put(key, body, rawType)
      const [row] = await svc.db.insert(media).values({
        workspaceId: req.workspaceId, sha256: actual, contentType: rawType, bytes: body.length, storageKey: key,
      }).onConflictDoNothing().returning()
      const id = row?.id ?? (await svc.db.select().from(media).where(and(eq(media.workspaceId, req.workspaceId), eq(media.sha256, actual))))[0].id
      return { mediaId: id, sha256: actual }
    })

    v1.post<{ Body: { publications: NewPublication[] } }>('/publications', {
      schema: { body: newPublicationsSchema },
    }, async (req, reply) => {
      const out: (typeof publications.$inferSelect)[] = []
      const problems: { clientId: string, problems: string[] }[] = []
      for (const p of req.body.publications) {
        const account = await findAccount(svc, req.workspaceId, p.accountId)
        const [m] = p.mediaId ? await svc.db.select().from(media).where(and(eq(media.id, p.mediaId), eq(media.workspaceId, req.workspaceId))) : []
        const errs = !account
          ? ['Unknown account.']
          : account.status !== 'connected'
            ? [`The account is ${account.status}; reconnect it.`]
            : validatePublication(svc.specs.get(p.platform), p.payload, account.scopes, m ? { bytes: m.bytes, contentType: m.contentType } : null)
        if (p.platform !== 'pinterest') errs.push(`The optional publishing service does not support ${p.platform}; publish from your Mac instead.`)
        if (p.mediaId && !m) errs.push('Unknown media.')
        if (account && account.platform !== p.platform) errs.push('The account is on another platform.')
        if (errs.length) { problems.push({ clientId: p.clientId, problems: errs }); continue }
      }
      if (problems.length) {
        return reply.code(422).send({ error: 'invalid_publications', message: problems.map((x) => `${x.clientId}: ${x.problems.join(' ')}`).join('\n'), problems })
      }
      for (const p of req.body.publications) {
        // Idempotent: the same key returns the existing row and queues nothing new.
        const [created] = await svc.db.insert(publications).values({
          workspaceId: req.workspaceId,
          clientId: p.clientId,
          idempotencyKey: p.idempotencyKey,
          accountId: p.accountId,
          platform: p.platform,
          scheduledAt: new Date(p.scheduledAt),
          timeZone: p.timeZone,
          mediaId: p.mediaId ?? null,
          payload: p.payload,
        }).onConflictDoNothing().returning()
        if (created) {
          try {
            const jobId = await svc.boss.send(PUBLISH_QUEUE, { publicationId: created.id }, {
              startAfter: created.scheduledAt, singletonKey: created.id,
            })
            await svc.db.update(publications).set({ jobId }).where(eq(publications.id, created.id))
            out.push(created)
          } catch (err) {
            // Roll back the orphaned row if pg-boss enqueue fails.
            await svc.db.delete(publications).where(eq(publications.id, created.id)).catch(() => {})
            throw err
          }
        } else {
          const [existing] = await svc.db.select().from(publications)
            .where(and(eq(publications.workspaceId, req.workspaceId), eq(publications.idempotencyKey, p.idempotencyKey)))
          out.push(existing)
        }
      }
      return reply.code(201).send({ publications: out.map(publicationView), serverTime: new Date().toISOString() })
    })

    v1.get<{ Querystring: { updatedSince?: string } }>('/publications', async (req) => {
      const since = req.query.updatedSince ? new Date(req.query.updatedSince) : null
      const where = since && !Number.isNaN(since.getTime())
        ? and(eq(publications.workspaceId, req.workspaceId), gt(publications.updatedAt, since))
        : eq(publications.workspaceId, req.workspaceId)
      const rows = await svc.db.select().from(publications).where(where).orderBy(desc(publications.updatedAt)).limit(5000)
      return { publications: rows.map(publicationView), serverTime: new Date().toISOString() }
    })

    v1.get<{ Params: { id: string } }>('/publications/:id/attempts', async (req, reply) => {
      if (!isUUID(req.params.id)) return reply.code(404).send({ error: 'not_found', message: 'No such publication.' })
      const [pub] = await svc.db.select().from(publications).where(and(eq(publications.id, req.params.id), eq(publications.workspaceId, req.workspaceId)))
      if (!pub) return reply.code(404).send({ error: 'not_found', message: 'No such publication.' })
      const rows = await svc.pool.query('select attempt, started_at, finished_at, outcome, http_status, provider_request_id, error from publication_attempts where publication_id = $1 order by attempt', [pub.id])
      return { attempts: rows.rows }
    })

    v1.post<{ Params: { id: string } }>('/publications/:id/cancel', async (req, reply) => {
      if (!isUUID(req.params.id)) return reply.code(404).send({ error: 'not_found', message: 'No such publication.' })
      const [pub] = await svc.db.update(publications).set({ status: 'canceled', updatedAt: new Date() })
        .where(and(eq(publications.id, req.params.id), eq(publications.workspaceId, req.workspaceId), inArray(publications.status, ['scheduled'])))
        .returning()
      if (!pub) {
        const [cur] = await svc.db.select().from(publications).where(and(eq(publications.id, req.params.id), eq(publications.workspaceId, req.workspaceId)))
        if (!cur) return reply.code(404).send({ error: 'not_found', message: 'No such publication.' })
        return reply.code(409).send({ error: 'conflict', message: `The post is ${cur.status} and can no longer be canceled.` })
      }
      if (pub.jobId) await svc.boss.cancel(PUBLISH_QUEUE, pub.jobId).catch(() => {})
      return publicationView(pub)
    })
  }, { prefix: '/v1' })

  return app
}

interface NewPublication {
  clientId: string
  idempotencyKey: string
  accountId: string
  platform: string
  scheduledAt: string
  timeZone: string
  mediaId?: string | null
  payload: PinPayload
}

const newPublicationsSchema = {
  type: 'object',
  required: ['publications'],
  properties: {
    publications: {
      type: 'array', minItems: 1, maxItems: 500,
      items: {
        type: 'object',
        required: ['clientId', 'idempotencyKey', 'accountId', 'platform', 'scheduledAt', 'timeZone', 'payload'],
        properties: {
          clientId: { type: 'string', minLength: 1, maxLength: 64 },
          idempotencyKey: { type: 'string', minLength: 8, maxLength: 128 },
          accountId: { type: 'string', format: 'uuid' },
          platform: { type: 'string' },
          scheduledAt: { type: 'string', format: 'date-time' },
          timeZone: { type: 'string', minLength: 1 },
          mediaId: { type: ['string', 'null'], format: 'uuid' },
          payload: {
            type: 'object',
            required: ['title', 'description', 'link', 'altText'],
            properties: {
              title: { type: 'string' }, description: { type: 'string' }, link: { type: 'string' }, altText: { type: 'string' },
              boardId: { type: ['string', 'null'] },
            },
          },
        },
      },
    },
  },
} as const

function accountView (a: typeof socialAccounts.$inferSelect) {
  return {
    id: a.id, platform: a.platform, name: a.name, handle: a.handle, status: a.status, scopes: a.scopes,
    tokenExpiresAt: a.tokenExpiresAt?.toISOString() ?? null, lastPublishedAt: a.lastPublishedAt?.toISOString() ?? null, isMock: a.isMock,
  }
}

function publicationView (p: typeof publications.$inferSelect) {
  return {
    id: p.id, clientId: p.clientId, status: p.status, scheduledAt: p.scheduledAt.toISOString(), publishedUrl: p.publishedUrl,
    providerPostId: p.providerPostId, lastError: p.lastError, attempts: p.attempts, updatedAt: p.updatedAt.toISOString(),
  }
}

function isUUID (id: string) {
  return /^[0-9a-f-]{36}$/i.test(id)
}

async function findAccount (svc: Services, workspaceId: string, id: string) {
  if (!isUUID(id)) return undefined
  const [a] = await svc.db.select().from(socialAccounts).where(and(eq(socialAccounts.id, id), eq(socialAccounts.workspaceId, workspaceId)))
  return a
}

/** With MOCK_PROVIDERS=1 every workspace gets one clearly labeled mock Pinterest account. */
export async function ensureMockAccount (svc: Services, workspaceId: string) {
  await svc.db.insert(socialAccounts).values({
    workspaceId, platform: 'pinterest', providerAccountId: 'mock', name: 'Mock Pinterest', handle: '@mock',
    status: 'connected', scopes: ['user_accounts:read', 'boards:read', 'pins:read', 'pins:write'], isMock: true,
  }).onConflictDoNothing()
}

function redirectUri (svc: Services, platform: string) {
  return `${svc.config.publicBaseUrl}/v1/oauth/${platform}/callback`
}

function page (title: string, detail: string) {
  const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`)
  return `<!doctype html><meta charset="utf-8"><title>SocialForge</title><body style="font:16px -apple-system,system-ui;margin:15vh auto;max-width:28em"><h1>${esc(title)}</h1><p>${esc(detail)}</p></body>`
}

