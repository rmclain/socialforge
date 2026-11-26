import { ProviderError, classifyStatus, type Board, type ProviderAccount, type PublishRequest, type PublishResult, type SocialProvider } from './types.ts'

/**
 * Pinterest API v5 (https://developers.pinterest.com/docs/api/v5/).
 * LIVE STATUS: UNVERIFIED. Built from the documented request and response
 * shapes; no real Pin has been created with it yet. New apps get Trial access,
 * which writes to api-sandbox.pinterest.com (set PINTEREST_API_BASE).
 */
export const PINTEREST_SCOPES = ['user_accounts:read', 'boards:read', 'pins:read', 'pins:write']

export class PinterestProvider implements SocialProvider {
  readonly platform = 'pinterest'
  readonly apiBase: string
  readonly fetchImpl: typeof fetch

  constructor (apiBase = 'https://api.pinterest.com', fetchImpl: typeof fetch = fetch) {
    this.apiBase = apiBase
    this.fetchImpl = fetchImpl
  }

  private async call<T> (account: ProviderAccount, method: string, path: string, body?: unknown, signal?: AbortSignal): Promise<{ data: T, requestId: string | null }> {
    if (!account.accessToken) throw new ProviderError('auth', 'No access token; reconnect the account.')
    let res: Response
    try {
      res = await this.fetchImpl(`${this.apiBase}/v5${path}`, {
        method,
        headers: { Authorization: `Bearer ${account.accessToken}`, 'Content-Type': 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(30_000)]) : AbortSignal.timeout(30_000),
      })
    } catch (err) {
      // A timeout after sending may have created the Pin: reconcile before retrying.
      const name = (err as Error).name
      if (method === 'POST' && (name === 'TimeoutError' || name === 'AbortError')) {
        throw new ProviderError('uncertain', `Pinterest did not answer in time: ${(err as Error).message}`)
      }
      throw new ProviderError('retryable', `Could not reach Pinterest: ${(err as Error).message}`)
    }
    const requestId = res.headers.get('x-request-id')
    if (!res.ok) {
      let message = `Pinterest answered ${res.status}`
      try {
        const e = await res.json() as { message?: string }
        if (e.message) message += `: ${e.message}`
      } catch {}
      throw new ProviderError(classifyStatus(res.status), message, res.status, requestId)
    }
    return { data: await res.json() as T, requestId }
  }

  async publish (req: PublishRequest): Promise<PublishResult> {
    if (!req.image) throw new ProviderError('permanent', 'A Pin needs an image.')
    const mime = req.image.contentType.split(';')[0].trim().toLowerCase()
    if (mime !== 'image/jpeg' && mime !== 'image/jpg' && mime !== 'image/png') {
      throw new ProviderError('permanent', `Pinterest base64 Pin upload requires JPEG or PNG (received ${mime}).`)
    }
    const body = {
      board_id: req.payload.boardId,
      title: req.payload.title || undefined,
      description: req.payload.description || undefined,
      link: req.payload.link || undefined,
      alt_text: req.payload.altText || undefined,
      // Pinterest has no idempotency header; the note carries our key so reconciliation can find the Pin.
      note: `sf:${req.idempotencyKey}`,
      media_source: {
        source_type: 'image_base64',
        content_type: mime === 'image/png' ? 'image/png' : 'image/jpeg',
        data: req.image.bytes.toString('base64'),
      },
    }
    const { data, requestId } = await this.call<{ id: string }>(req.account, 'POST', '/pins', body, req.signal)
    return { providerPostId: data.id, url: `https://www.pinterest.com/pin/${data.id}/`, requestId }
  }

  async findExisting (req: PublishRequest, since: Date): Promise<PublishResult | null> {
    if (!req.payload.boardId) return null
    let bookmark: string | undefined
    for (let page = 0; page < 5; page++) {
      const q = `/boards/${encodeURIComponent(req.payload.boardId)}/pins?page_size=50${bookmark ? `&bookmark=${encodeURIComponent(bookmark)}` : ''}`
      const { data } = await this.call<{ items: { id: string, note?: string, created_at?: string }[], bookmark?: string | null }>(
        req.account, 'GET', q)
      const hit = data.items.find((p) => p.note === `sf:${req.idempotencyKey}` && (!p.created_at || new Date(p.created_at) >= new Date(since.getTime() - 60_000)))
      if (hit) return { providerPostId: hit.id, url: `https://www.pinterest.com/pin/${hit.id}/` }
      bookmark = data.bookmark ?? undefined
      if (!bookmark) break
    }
    return null
  }

  async listBoards (account: ProviderAccount): Promise<Board[]> {
    const boards: Board[] = []
    let bookmark: string | undefined
    do {
      const q = `/boards?page_size=100${bookmark ? `&bookmark=${encodeURIComponent(bookmark)}` : ''}`
      const { data } = await this.call<{ items: { id: string, name: string, privacy?: string }[], bookmark?: string | null }>(account, 'GET', q)
      boards.push(...data.items.map((b) => ({ id: b.id, name: b.name, privacy: b.privacy ?? null })))
      bookmark = data.bookmark ?? undefined
    } while (bookmark && boards.length < 1000)
    return boards
  }

  /** OAuth step 2: exchange the code for tokens (HTTP Basic with the app's id and secret). */
  async exchangeCode (code: string, redirectUri: string, clientId: string, clientSecret: string) {
    const res = await this.fetchImpl(`${this.apiBase}/v5/oauth/token`, {
      method: 'POST',
      headers: {
        Authorization: `Basic ${Buffer.from(`${clientId}:${clientSecret}`).toString('base64')}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: new URLSearchParams({ grant_type: 'authorization_code', code, redirect_uri: redirectUri }),
    })
    if (!res.ok) throw new ProviderError(classifyStatus(res.status), `Token exchange failed (${res.status})`, res.status)
    return await res.json() as { access_token: string, refresh_token?: string, expires_in?: number, scope?: string }
  }

  async userAccount (accessToken: string) {
    const { data } = await this.call<{ username: string, business_name?: string, id?: string }>(
      { id: '', providerAccountId: '', accessToken, scopes: [] }, 'GET', '/user_account')
    return data
  }
}
