CREATE TABLE "activity_log" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "activity_log_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"workspace_id" uuid NOT NULL,
	"kind" text NOT NULL,
	"subject_id" text,
	"detail" jsonb,
	"at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "media" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"workspace_id" uuid NOT NULL,
	"sha256" text NOT NULL,
	"content_type" text NOT NULL,
	"bytes" bigint NOT NULL,
	"storage_key" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "mock_provider_posts" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"account_id" uuid NOT NULL,
	"board_id" text NOT NULL,
	"title" text NOT NULL,
	"link" text NOT NULL,
	"idempotency_key" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "oauth_states" (
	"state" text PRIMARY KEY NOT NULL,
	"workspace_id" uuid NOT NULL,
	"platform" text NOT NULL,
	"code_verifier" text,
	"expires_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE TABLE "publication_attempts" (
	"id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY (sequence name "publication_attempts_id_seq" INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1),
	"publication_id" uuid NOT NULL,
	"attempt" integer NOT NULL,
	"started_at" timestamp with time zone DEFAULT now() NOT NULL,
	"finished_at" timestamp with time zone,
	"outcome" text,
	"http_status" integer,
	"provider_request_id" text,
	"error" text
);
--> statement-breakpoint
CREATE TABLE "publications" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"workspace_id" uuid NOT NULL,
	"client_id" text NOT NULL,
	"idempotency_key" text NOT NULL,
	"account_id" uuid NOT NULL,
	"platform" text NOT NULL,
	"scheduled_at" timestamp with time zone NOT NULL,
	"time_zone" text NOT NULL,
	"media_id" uuid,
	"payload" jsonb NOT NULL,
	"status" text DEFAULT 'scheduled' NOT NULL,
	"provider_post_id" text,
	"published_url" text,
	"last_error" text,
	"attempts" integer DEFAULT 0 NOT NULL,
	"job_id" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "publications_status_check" CHECK ("publications"."status" in ('scheduled', 'publishing', 'published', 'failed', 'canceled'))
);
--> statement-breakpoint
CREATE TABLE "social_accounts" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"workspace_id" uuid NOT NULL,
	"platform" text NOT NULL,
	"provider_account_id" text NOT NULL,
	"name" text NOT NULL,
	"handle" text,
	"status" text DEFAULT 'connected' NOT NULL,
	"scopes" text[] DEFAULT '{}'::text[] NOT NULL,
	"access_token_enc" text,
	"refresh_token_enc" text,
	"token_expires_at" timestamp with time zone,
	"last_published_at" timestamp with time zone,
	"is_mock" boolean DEFAULT false NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "social_accounts_status_check" CHECK ("social_accounts"."status" in ('connected', 'expired', 'revoked', 'error'))
);
--> statement-breakpoint
CREATE TABLE "workspaces" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"name" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "activity_log" ADD CONSTRAINT "activity_log_workspace_id_workspaces_id_fk" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "media" ADD CONSTRAINT "media_workspace_id_workspaces_id_fk" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "mock_provider_posts" ADD CONSTRAINT "mock_provider_posts_account_id_social_accounts_id_fk" FOREIGN KEY ("account_id") REFERENCES "public"."social_accounts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "oauth_states" ADD CONSTRAINT "oauth_states_workspace_id_workspaces_id_fk" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "publication_attempts" ADD CONSTRAINT "publication_attempts_publication_id_publications_id_fk" FOREIGN KEY ("publication_id") REFERENCES "public"."publications"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "publications" ADD CONSTRAINT "publications_workspace_id_workspaces_id_fk" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "publications" ADD CONSTRAINT "publications_account_id_social_accounts_id_fk" FOREIGN KEY ("account_id") REFERENCES "public"."social_accounts"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "publications" ADD CONSTRAINT "publications_media_id_media_id_fk" FOREIGN KEY ("media_id") REFERENCES "public"."media"("id") ON DELETE restrict ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "social_accounts" ADD CONSTRAINT "social_accounts_workspace_id_workspaces_id_fk" FOREIGN KEY ("workspace_id") REFERENCES "public"."workspaces"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "activity_log_workspace_at_idx" ON "activity_log" USING btree ("workspace_id","at");--> statement-breakpoint
CREATE UNIQUE INDEX "media_workspace_sha_key" ON "media" USING btree ("workspace_id","sha256");--> statement-breakpoint
CREATE INDEX "mock_provider_posts_account_idx" ON "mock_provider_posts" USING btree ("account_id","created_at");--> statement-breakpoint
CREATE INDEX "oauth_states_workspace_idx" ON "oauth_states" USING btree ("workspace_id");--> statement-breakpoint
CREATE INDEX "publication_attempts_publication_idx" ON "publication_attempts" USING btree ("publication_id","attempt");--> statement-breakpoint
CREATE UNIQUE INDEX "publications_idempotency_key" ON "publications" USING btree ("workspace_id","idempotency_key");--> statement-breakpoint
CREATE INDEX "publications_workspace_updated_idx" ON "publications" USING btree ("workspace_id","updated_at");--> statement-breakpoint
CREATE INDEX "publications_account_idx" ON "publications" USING btree ("account_id");--> statement-breakpoint
CREATE INDEX "publications_media_idx" ON "publications" USING btree ("media_id");--> statement-breakpoint
CREATE UNIQUE INDEX "social_accounts_provider_key" ON "social_accounts" USING btree ("workspace_id","platform","provider_account_id");--> statement-breakpoint
CREATE INDEX "social_accounts_workspace_idx" ON "social_accounts" USING btree ("workspace_id");--> statement-breakpoint
CREATE UNIQUE INDEX "workspaces_name_key" ON "workspaces" USING btree ("name");