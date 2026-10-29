-- Additive migration: never infer a verified identity from users.email (including
-- GitHub's public contact email), and preserve all existing user IDs and FKs.
-- Email-only users retain the original required github_id column using the
-- reserved nonnumeric namespace email:<user UUID>; GitHub IDs are numeric.
CREATE TABLE email_identities (
  email TEXT PRIMARY KEY,
  user_id TEXT UNIQUE NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  verified_at INTEGER NOT NULL
);
CREATE TABLE email_auth_challenges (
  id_hash TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  pkce_challenge TEXT NOT NULL,
  code_hash TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  sent_at INTEGER,
  attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0 AND attempts <= 5),
  consumed_by TEXT,
  UNIQUE(email,pkce_challenge)
);
CREATE INDEX email_auth_expiry ON email_auth_challenges(expires_at);
