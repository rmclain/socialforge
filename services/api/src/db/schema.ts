import { sql } from 'drizzle-orm'
import {
  bigint, boolean, check, index, integer, jsonb, pgTable, text, timestamp, uniqueIndex, uuid,
} from 'drizzle-orm/pg-core'

// A workspace is the isolation boundary: every row below belongs to exactly one,
// and every query filters by it.
export const workspaces = pgTable('workspaces', {
  id: uuid('id').primaryKey().defaultRandom(),
  name: text('name').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
}, (t) => [uniqueIndex('workspaces_name_key').on(t.name)])

export const socialAccounts = pgTable('social_accounts', {
  id: uuid('id').primaryKey().defaultRandom(),
  workspaceId: uuid('workspace_id').notNull().references(() => workspaces.id, { onDelete: 'cascade' }),
  platform: text('platform').notNull(),
  providerAccountId: text('provider_account_id').notNull(),
  name: text('name').notNull(),
  handle: text('handle'),
  status: text('status').notNull().default('connected'),
  scopes: text('scopes').array().notNull().default(sql`'{}'::text[]`),
  // AES-256-GCM, see src/crypto.ts. Never logged, never returned by the API.
  accessTokenEnc: text('access_token_enc'),
  refreshTokenEnc: text('refresh_token_enc'),
  tokenExpiresAt: timestamp('token_expires_at', { withTimezone: true }),
  lastPublishedAt: timestamp('last_published_at', { withTimezone: true }),
  isMock: boolean('is_mock').notNull().default(false),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
}, (t) => [
  uniqueIndex('social_accounts_provider_key').on(t.workspaceId, t.platform, t.providerAccountId),
  index('social_accounts_workspace_idx').on(t.workspaceId),
  check('social_accounts_status_check', sql`${t.status} in ('connected', 'expired', 'revoked', 'error')`),
])

export const oauthStates = pgTable('oauth_states', {
  state: text('state').primaryKey(),
  workspaceId: uuid('workspace_id').notNull().references(() => workspaces.id, { onDelete: 'cascade' }),
  platform: text('platform').notNull(),
  codeVerifier: text('code_verifier'),
  expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
}, (t) => [index('oauth_states_workspace_idx').on(t.workspaceId)])

export const media = pgTable('media', {
  id: uuid('id').primaryKey().defaultRandom(),
  workspaceId: uuid('workspace_id').notNull().references(() => workspaces.id, { onDelete: 'cascade' }),
  sha256: text('sha256').notNull(),
  contentType: text('content_type').notNull(),
  bytes: bigint('bytes', { mode: 'number' }).notNull(),
  storageKey: text('storage_key').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
}, (t) => [uniqueIndex('media_workspace_sha_key').on(t.workspaceId, t.sha256)])

// A post definition. Attempts are separate rows, so history is never overwritten.
export const publications = pgTable('publications', {
  id: uuid('id').primaryKey().defaultRandom(),
  workspaceId: uuid('workspace_id').notNull().references(() => workspaces.id, { onDelete: 'cascade' }),
  clientId: text('client_id').notNull(),
  idempotencyKey: text('idempotency_key').notNull(),
  accountId: uuid('account_id').notNull().references(() => socialAccounts.id, { onDelete: 'restrict' }),
  platform: text('platform').notNull(),
  scheduledAt: timestamp('scheduled_at', { withTimezone: true }).notNull(),
  timeZone: text('time_zone').notNull(),
  mediaId: uuid('media_id').references(() => media.id, { onDelete: 'restrict' }),
  payload: jsonb('payload').notNull(),
  status: text('status').notNull().default('scheduled'),
  providerPostId: text('provider_post_id'),
  publishedUrl: text('published_url'),
  lastError: text('last_error'),
  attempts: integer('attempts').notNull().default(0),
  jobId: text('job_id'),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
}, (t) => [
  uniqueIndex('publications_idempotency_key').on(t.workspaceId, t.idempotencyKey),
  index('publications_workspace_updated_idx').on(t.workspaceId, t.updatedAt),
  index('publications_account_idx').on(t.accountId),
  index('publications_media_idx').on(t.mediaId),
  check('publications_status_check', sql`${t.status} in ('scheduled', 'publishing', 'published', 'failed', 'canceled')`),
])

export const publicationAttempts = pgTable('publication_attempts', {
  id: bigint('id', { mode: 'number' }).primaryKey().generatedAlwaysAsIdentity(),
  publicationId: uuid('publication_id').notNull().references(() => publications.id, { onDelete: 'cascade' }),
  attempt: integer('attempt').notNull(),
  startedAt: timestamp('started_at', { withTimezone: true }).notNull().defaultNow(),
  finishedAt: timestamp('finished_at', { withTimezone: true }),
  // success, retryable, permanent, auth, uncertain, reconciled
  outcome: text('outcome'),
  httpStatus: integer('http_status'),
  providerRequestId: text('provider_request_id'),
  error: text('error'),
}, (t) => [index('publication_attempts_publication_idx').on(t.publicationId, t.attempt)])

// Development-only stand-in for a social platform. Modeled on Pinterest's
// documented create-Pin response so the worker runs end to end without credentials.
export const mockProviderPosts = pgTable('mock_provider_posts', {
  id: uuid('id').primaryKey().defaultRandom(),
  accountId: uuid('account_id').notNull().references(() => socialAccounts.id, { onDelete: 'cascade' }),
  boardId: text('board_id').notNull(),
  title: text('title').notNull(),
  link: text('link').notNull(),
  idempotencyKey: text('idempotency_key').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
}, (t) => [
  index('mock_provider_posts_account_idx').on(t.accountId, t.createdAt),
])

export const activityLog = pgTable('activity_log', {
  id: bigint('id', { mode: 'number' }).primaryKey().generatedAlwaysAsIdentity(),
  workspaceId: uuid('workspace_id').notNull().references(() => workspaces.id, { onDelete: 'cascade' }),
  kind: text('kind').notNull(),
  subjectId: text('subject_id'),
  detail: jsonb('detail'),
  at: timestamp('at', { withTimezone: true }).notNull().defaultNow(),
}, (t) => [index('activity_log_workspace_at_idx').on(t.workspaceId, t.at)])
