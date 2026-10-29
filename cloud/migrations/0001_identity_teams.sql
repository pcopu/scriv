PRAGMA foreign_keys = ON;
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  github_id TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  email TEXT,
  avatar_url TEXT,
  created_at INTEGER NOT NULL
);
CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY,
  id TEXT UNIQUE NOT NULL,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_name TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  revoked_at INTEGER
);
CREATE INDEX sessions_user ON sessions(user_id);
CREATE INDEX sessions_expiry ON sessions(expires_at);
CREATE TABLE oauth_states (
  state_hash TEXT PRIMARY KEY,
  client_state TEXT NOT NULL,
  challenge TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE TABLE auth_codes (
  code_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  challenge TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE TABLE teams (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  owner_id TEXT NOT NULL REFERENCES users(id),
  created_at INTEGER NOT NULL,
  stripe_customer_id TEXT UNIQUE,
  subscription_id TEXT UNIQUE,
  subscription_status TEXT NOT NULL DEFAULT 'free',
  current_period_end INTEGER,
  canceled_at INTEGER,
  paid_until INTEGER,
  billing_checked_at INTEGER,
  storage_used INTEGER NOT NULL DEFAULT 0 CHECK(storage_used >= 0)
);
CREATE TABLE team_members (
  team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK(role IN ('owner','admin','member','viewer')),
  joined_at INTEGER NOT NULL,
  PRIMARY KEY (team_id,user_id)
);
CREATE INDEX team_members_user ON team_members(user_id);
CREATE TABLE join_links (
  id TEXT PRIMARY KEY,
  team_id TEXT NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  token_hash TEXT UNIQUE NOT NULL,
  role TEXT NOT NULL CHECK(role IN ('member','viewer')),
  created_by TEXT NOT NULL REFERENCES users(id),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  revoked_at INTEGER
);
CREATE INDEX join_links_team ON join_links(team_id);
CREATE TABLE projects (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  owner_id TEXT NOT NULL REFERENCES users(id),
  team_id TEXT REFERENCES teams(id),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  archived_at INTEGER
);
CREATE INDEX projects_owner ON projects(owner_id,archived_at);
CREATE INDEX projects_team ON projects(team_id,archived_at);
CREATE TABLE billing_events (
  id TEXT PRIMARY KEY,
  team_id TEXT REFERENCES teams(id),
  event_type TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  processed_at INTEGER NOT NULL
);
CREATE TABLE assets (
  project_id TEXT NOT NULL REFERENCES projects(id),
  sha256 TEXT NOT NULL,
  team_id TEXT NOT NULL REFERENCES teams(id),
  asset_id TEXT,
  object_key TEXT UNIQUE NOT NULL,
  content_type TEXT NOT NULL,
  bytes INTEGER NOT NULL CHECK(bytes > 0),
  state TEXT NOT NULL CHECK(state IN ('uploading','ready','deleting')),
  uploaded_by TEXT NOT NULL REFERENCES users(id),
  created_at INTEGER NOT NULL,
  PRIMARY KEY(project_id,sha256)
);
CREATE INDEX assets_team ON assets(team_id,state);
CREATE INDEX assets_cleanup ON assets(state,created_at);
CREATE TABLE security_limits (
  key TEXT PRIMARY KEY,
  count INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
ALTER TABLE teams ADD COLUMN storage_limit INTEGER NOT NULL DEFAULT 10737418240 CHECK(storage_limit > 0);
CREATE TRIGGER assets_quota BEFORE INSERT ON assets BEGIN
  SELECT CASE WHEN (SELECT storage_used+NEW.bytes>storage_limit FROM teams WHERE id=NEW.team_id) THEN RAISE(ABORT,'team_storage_quota') END;
END;
CREATE TRIGGER assets_reserve AFTER INSERT ON assets BEGIN
  UPDATE teams SET storage_used=storage_used+NEW.bytes WHERE id=NEW.team_id;
END;
CREATE TRIGGER assets_release AFTER DELETE ON assets BEGIN
  UPDATE teams SET storage_used=MAX(0,storage_used-OLD.bytes) WHERE id=OLD.team_id;
END;
