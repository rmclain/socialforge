import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

/** spec/platforms/*.json, the same files the Mac app embeds. */
export interface PlatformSpec {
  platform: string
  name: string
  status: 'available' | 'planned'
  liveVerified: boolean
  contentTypes: { id: string, name: string, requiredScopes: string[], needsDestination: string }[]
  text: Record<string, { max: number, required: boolean, enforced: boolean }>
  /** Absent for platforms without image posts (YouTube Shorts). */
  image?: { formats: string[], maxBytes: number, maxBytesEnforced: boolean }
  video?: { formats: string[], maxBytes?: number, minSeconds?: number, maxSeconds?: number }
}

export function loadSpecs (dir: string): Map<string, PlatformSpec> {
  const out = new Map<string, PlatformSpec>()
  for (const f of readdirSync(dir).filter((f) => f.endsWith('.json'))) {
    const spec = JSON.parse(readFileSync(join(dir, f), 'utf8')) as PlatformSpec
    out.set(spec.platform, spec)
  }
  return out
}

export interface PinPayload { title: string, description: string, link: string, altText: string, boardId: string | null }

/**
 * The server enforces what the platform enforces, so a modified client cannot
 * queue a post the platform will reject. Returns problems in plain words.
 */
export function validatePublication (spec: PlatformSpec | undefined, payload: PinPayload, scopes: string[],
  media: { bytes: number, contentType: string } | null): string[] {
  if (!spec) return ['Unknown platform.']
  if (spec.status !== 'available') return [`${spec.name} publishing is not available yet.`]
  const problems: string[] = []
  const ct = spec.contentTypes[0]
  const missing = ct.requiredScopes.filter((s) => !scopes.includes(s))
  if (missing.length) problems.push(`The account is missing permission: ${missing.join(', ')}.`)
  const fields: [string, string][] = [
    ['title', payload.title], ['description', payload.description], ['caption', payload.description || payload.title],
    ['message', payload.description || payload.title], ['commentary', payload.description || payload.title],
    ['text', payload.description || payload.title], ['alt_text', payload.altText], ['link', payload.link],
  ]
  for (const [key, value] of fields) {
    const rule = spec.text[key]
    if (!rule) continue
    if (rule.required && !value.trim()) problems.push(`${key} is required.`)
    if (rule.enforced && [...value].length > rule.max) problems.push(`${key} is longer than ${rule.max} characters.`)
  }
  if (spec.platform === 'pinterest') {
    if (!payload.boardId) problems.push('A board is required.')
    if (payload.link && !/^https?:\/\/[^\s/]+/i.test(payload.link)) problems.push('The link must start with http:// or https://.')
    if (!media) problems.push('A Pin needs an image.')
  }
  if (media && !spec.image) problems.push(`${spec.name} does not take image posts.`)
  if (media && spec.image) {
    const cleanType = media.contentType.split(';')[0].trim().toLowerCase()
    const format = cleanType.replace('image/', '').replace('jpg', 'jpeg')
    if (!spec.image.formats.includes(format)) problems.push(`${cleanType} is not accepted by ${spec.name}.`)
    if (spec.image.maxBytesEnforced && media.bytes > spec.image.maxBytes) problems.push(`The image is larger than ${spec.image.maxBytes / 1_048_576} MB.`)
  }
  return problems
}
