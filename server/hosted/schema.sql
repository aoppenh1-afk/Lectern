-- Additive, repeatable migration. Run explicitly before deploying the function.
CREATE TABLE IF NOT EXISTS lectern_users (
  id text PRIMARY KEY, google_sub text UNIQUE NOT NULL, email text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS lectern_clients (
  id text PRIMARY KEY, name text NOT NULL, redirects jsonb NOT NULL,
  auth_method text NOT NULL, secret_hash text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS lectern_sessions (
  hash text PRIMARY KEY, user_id text NOT NULL REFERENCES lectern_users(id) ON DELETE CASCADE,
  csrf text NOT NULL, expires_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS lectern_pending (
  hash text PRIMARY KEY, kind text NOT NULL, data jsonb NOT NULL, expires_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS lectern_grants (
  id text PRIMARY KEY, user_id text NOT NULL REFERENCES lectern_users(id) ON DELETE CASCADE,
  client_id text NOT NULL, scope text NOT NULL, resource text NOT NULL,
  revoked boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS lectern_tokens (
  hash text PRIMARY KEY, grant_id text NOT NULL REFERENCES lectern_grants(id) ON DELETE CASCADE,
  kind text NOT NULL, used boolean NOT NULL DEFAULT false, expires_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS lectern_tokens_grant ON lectern_tokens(grant_id);
CREATE TABLE IF NOT EXISTS lectern_libraries (
  user_id text PRIMARY KEY REFERENCES lectern_users(id) ON DELETE CASCADE,
  snapshot jsonb NOT NULL, revision integer NOT NULL DEFAULT 1,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS lectern_limits (
  key text PRIMARY KEY, count integer NOT NULL, expires_at timestamptz NOT NULL
);
CREATE TABLE IF NOT EXISTS lectern_uploads (
  id text PRIMARY KEY, user_id text NOT NULL REFERENCES lectern_users(id) ON DELETE CASCADE,
  grant_id text NOT NULL REFERENCES lectern_grants(id) ON DELETE CASCADE,
  revision integer NOT NULL, content bytea NOT NULL DEFAULT ''::bytea,
  expires_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS lectern_uploads_owner ON lectern_uploads(user_id);
CREATE INDEX IF NOT EXISTS lectern_grants_user ON lectern_grants(user_id);
