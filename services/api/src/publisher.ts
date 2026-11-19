import { and, eq, sql } from 'drizzle-orm'
import { activityLog, media, publicationAttempts, publications, socialAccounts } from './db/schema.ts'
import { ProviderError, type PublishRequest, type PublishResult } from './providers/types.ts'
import type { Services } from './services.ts'

export interface PublishJob { publicationId: string }

/** Thrown to tell pg-boss to retry later with backoff. */
export class RetryLater extends Error {}

/**
 * Publishes one post. Called by the worker for each job attempt.
 *
 * - Skips posts that are already published or canceled (a duplicate job is harmless).
 * - After an uncertain attempt, asks the platform whether the post exists before posting again.
 * - Retryable errors throw RetryLater, until the last allowed attempt, which fails the post.
 * - Auth errors mark the account expired and fail the post at once; permanent errors fail it at once.
 * Every attempt is recorded in publication_attempts.
 */
export async function processPublication (svc: Services, job: PublishJob, retryCount: number, signal?: AbortSignal): Promise<'published' | 'failed' | 'skipped'> {
  const { db } = svc
  // Claim: only a scheduled (or retrying) post moves to publishing. Two workers cannot both claim it.
  const [pub] = await db.update(publications)
    .set({ status: 'publishing', attempts: sql`${publications.attempts} + 1`, updatedAt: new Date() })
    .where(and(eq(publications.id, job.publicationId), sql`${publications.status} in ('scheduled', 'publishing')`))
    .returning()
  if (!pub) return 'skipped'

  const [account] = await db.select().from(socialAccounts).where(eq(socialAccounts.id, pub.accountId))
  const [attempt] = await db.insert(publicationAttempts).values({ publicationId: pub.id, attempt: pub.attempts }).returning()
  const finishAttempt = (outcome: string, extra: { httpStatus?: number | null, providerRequestId?: string | null, error?: string | null } = {}) =>
    db.update(publicationAttempts).set({ outcome, finishedAt: new Date(), ...extra }).where(eq(publicationAttempts.id, attempt.id))

  const fail = async (message: string) => {
    await db.update(publications).set({ status: 'failed', lastError: message, updatedAt: new Date() }).where(eq(publications.id, pub.id))
    await db.insert(activityLog).values({ workspaceId: pub.workspaceId, kind: 'publication.failed', subjectId: pub.id, detail: { message } })
    return 'failed' as const
  }

  if (!account || account.status !== 'connected') {
    await finishAttempt('auth', { error: 'Account is not connected' })
    return fail('The account is disconnected. Reconnect it and schedule the post again.')
  }

  try {
    const provider = svc.providerFor(account)
    let image: PublishRequest['image'] = null
    if (pub.mediaId) {
      const [m] = await db.select().from(media).where(eq(media.id, pub.mediaId))
      if (!m) throw new ProviderError('permanent', 'The image for this post is missing.')
      image = { bytes: await svc.store.get(m.storageKey), contentType: m.contentType }
    }
    const req: PublishRequest = {
      account: svc.providerAccount(account),
      idempotencyKey: pub.idempotencyKey,
      payload: pub.payload as PublishRequest['payload'],
      image,
      signal,
    }

    // An earlier attempt that may have reached the platform: look before posting again.
    const previous = await db.select({ outcome: publicationAttempts.outcome }).from(publicationAttempts)
      .where(eq(publicationAttempts.publicationId, pub.id))
    let result: PublishResult | null = null
    if (previous.some((a) => a.outcome === 'uncertain')) {
      result = await provider.findExisting(req, pub.createdAt)
      if (result) await finishAttempt('reconciled', { providerRequestId: result.requestId ?? null })
    }
    if (!result) {
      result = await provider.publish(req)
      await finishAttempt('success', { providerRequestId: result.requestId ?? null })
    }

    const now = new Date()
    await db.update(publications).set({
      status: 'published', providerPostId: result.providerPostId, publishedUrl: result.url, lastError: null, updatedAt: now,
    }).where(eq(publications.id, pub.id))
    await db.update(socialAccounts).set({ lastPublishedAt: now, updatedAt: now }).where(eq(socialAccounts.id, account.id))
    await db.insert(activityLog).values({ workspaceId: pub.workspaceId, kind: 'publication.published', subjectId: pub.id, detail: { url: result.url } })
    return 'published'
  } catch (err) {
    const e = err instanceof ProviderError ? err : new ProviderError('retryable', (err as Error).message)
    await finishAttempt(e.kind, { httpStatus: e.status, providerRequestId: e.requestId, error: e.message })
    if (e.kind === 'auth') {
      await db.update(socialAccounts).set({ status: 'expired', updatedAt: new Date() }).where(eq(socialAccounts.id, account.id))
      return fail(`${e.message}. Reconnect the account in SocialForge.`)
    }
    if (e.kind === 'permanent') return fail(e.message)
    // retryable or uncertain
    if (retryCount >= svc.config.retry.limit) return fail(`${e.message}; gave up after ${pub.attempts} attempts.`)
    await db.update(publications).set({ status: 'scheduled', lastError: e.message, updatedAt: new Date() }).where(eq(publications.id, pub.id))
    throw new RetryLater(e.message)
  }
}
