import { createCipheriv, createDecipheriv, createHmac, randomBytes, timingSafeEqual } from 'node:crypto'

/** AES-256-GCM for OAuth tokens at rest: base64(iv | tag | ciphertext). */
export function encrypt (plain: string, key: Buffer): string {
  const iv = randomBytes(12)
  const cipher = createCipheriv('aes-256-gcm', key, iv)
  const data = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()])
  return Buffer.concat([iv, cipher.getAuthTag(), data]).toString('base64')
}

export function decrypt (sealed: string, key: Buffer): string {
  const buf = Buffer.from(sealed, 'base64')
  const decipher = createDecipheriv('aes-256-gcm', key, buf.subarray(0, 12))
  decipher.setAuthTag(buf.subarray(12, 28))
  return Buffer.concat([decipher.update(buf.subarray(28)), decipher.final()]).toString('utf8')
}

export interface SessionClaims { ws: string, iat: number }

/** Signed bearer tokens for the Mac app: base64url(json).base64url(hmac-sha256). */
export function signSession (claims: SessionClaims, key: string): string {
  const body = Buffer.from(JSON.stringify(claims)).toString('base64url')
  const sig = createHmac('sha256', key).update(body).digest('base64url')
  return `${body}.${sig}`
}

export function verifySession (token: string, key: string): SessionClaims | null {
  const [body, sig] = token.split('.')
  if (!body || !sig) return null
  const want = createHmac('sha256', key).update(body).digest()
  const got = Buffer.from(sig, 'base64url')
  if (got.length !== want.length || !timingSafeEqual(got, want)) return null
  try {
    const claims = JSON.parse(Buffer.from(body, 'base64url').toString('utf8')) as SessionClaims
    return typeof claims.ws === 'string' ? claims : null
  } catch {
    return null
  }
}

export function randomToken (bytes = 24): string {
  return randomBytes(bytes).toString('base64url')
}
