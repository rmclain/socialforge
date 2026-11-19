/** What a social platform adapter does. Add a platform by adding one of these. */
export interface ProviderAccount {
  id: string
  providerAccountId: string
  accessToken: string | null
  scopes: string[]
}

export interface PublishRequest {
  account: ProviderAccount
  idempotencyKey: string
  payload: { title: string, description: string, link: string, altText: string, boardId: string | null }
  image: { bytes: Buffer, contentType: string } | null
  /** Aborts when the job is cancelled or times out. */
  signal?: AbortSignal
}

export interface PublishResult {
  providerPostId: string
  url: string | null
  requestId?: string | null
}

export interface Board { id: string, name: string, privacy: string | null }

export interface SocialProvider {
  readonly platform: string
  publish (req: PublishRequest): Promise<PublishResult>
  /**
   * Looks for a post an earlier, uncertain attempt may have created, so a
   * retry after a timeout does not post twice. Null when none is found.
   */
  findExisting (req: PublishRequest, since: Date): Promise<PublishResult | null>
  listBoards (account: ProviderAccount): Promise<Board[]>
}

/**
 * - retryable: try again later (5xx, 429, network refused before sending)
 * - uncertain: the request may have reached the platform (timeout after send); reconcile first
 * - auth: the token is invalid or revoked; mark the account and stop
 * - permanent: the platform rejected the content; stop
 */
export type ProviderErrorKind = 'retryable' | 'uncertain' | 'auth' | 'permanent'

export class ProviderError extends Error {
  readonly kind: ProviderErrorKind
  readonly status: number | null
  readonly requestId: string | null
  constructor (kind: ProviderErrorKind, message: string, status: number | null = null, requestId: string | null = null) {
    super(message)
    this.kind = kind
    this.status = status
    this.requestId = requestId
  }
}

/** Maps an HTTP status to how the worker should treat it. */
export function classifyStatus (status: number): ProviderErrorKind {
  if (status === 401 || status === 403) return 'auth'
  if (status === 408 || status === 429 || status >= 500) return 'retryable'
  return 'permanent'
}
