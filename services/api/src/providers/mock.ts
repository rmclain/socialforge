import { and, desc, eq, gte } from 'drizzle-orm'
import type { DB } from '../db/client.ts'
import { mockProviderPosts } from '../db/schema.ts'
import { ProviderError, type Board, type ProviderAccount, type PublishRequest, type PublishResult, type SocialProvider } from './types.ts'

/**
 * A development stand-in for Pinterest, enabled with MOCK_PROVIDERS=1. It
 * stores "Pins" in mock_provider_posts and answers like the documented API.
 * Accounts it backs are flagged is_mock and labeled in the app. Tests script
 * failures with `script`: each publish takes the next step.
 */
export type MockStep = 'ok' | 'retryable' | 'auth' | 'permanent' | 'uncertain-after-create'

export class MockPinterestProvider implements SocialProvider {
  readonly platform = 'pinterest'
  readonly db: DB
  script: MockStep[] = []
  calls = 0

  constructor (db: DB) {
    this.db = db
  }

  static boards: Board[] = [
    { id: 'board_winter', name: 'Winter Home Edit', privacy: 'PUBLIC' },
    { id: 'board_kitchen', name: 'Kitchen & Table', privacy: 'PUBLIC' },
  ]

  async publish (req: PublishRequest): Promise<PublishResult> {
    this.calls++
    const step = this.script.shift() ?? 'ok'
    if (step === 'retryable') throw new ProviderError('retryable', 'Mock Pinterest answered 503 Service Unavailable', 503, `mock-${this.calls}`)
    if (step === 'auth') throw new ProviderError('auth', 'Mock Pinterest answered 401: Authentication failed', 401, `mock-${this.calls}`)
    if (step === 'permanent') throw new ProviderError('permanent', 'Mock Pinterest answered 400: Invalid board_id', 400, `mock-${this.calls}`)
    if (!req.image) throw new ProviderError('permanent', 'A Pin needs an image.', 400)
    if (!MockPinterestProvider.boards.some((b) => b.id === req.payload.boardId)) {
      throw new ProviderError('permanent', `Mock Pinterest answered 404: board ${req.payload.boardId} not found`, 404)
    }
    const [row] = await this.db.insert(mockProviderPosts).values({
      accountId: req.account.id,
      boardId: req.payload.boardId!,
      title: req.payload.title,
      link: req.payload.link,
      idempotencyKey: req.idempotencyKey,
    }).returning()
    if (step === 'uncertain-after-create') throw new ProviderError('uncertain', 'Mock Pinterest timed out after receiving the request')
    return { providerPostId: row.id, url: `https://mock.pinterest.local/pin/${row.id}/`, requestId: `mock-${this.calls}` }
  }

  async findExisting (req: PublishRequest, since: Date): Promise<PublishResult | null> {
    const [hit] = await this.db.select().from(mockProviderPosts).where(and(
      eq(mockProviderPosts.accountId, req.account.id),
      eq(mockProviderPosts.idempotencyKey, req.idempotencyKey),
      gte(mockProviderPosts.createdAt, new Date(since.getTime() - 60_000)),
    )).orderBy(desc(mockProviderPosts.createdAt)).limit(1)
    return hit ? { providerPostId: hit.id, url: `https://mock.pinterest.local/pin/${hit.id}/` } : null
  }

  async listBoards (_account: ProviderAccount): Promise<Board[]> {
    return MockPinterestProvider.boards
  }
}
