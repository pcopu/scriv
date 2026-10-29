-- Metadata only. Prompts, local paths, provider threads and credentials stay on the Mac.
CREATE TABLE generation_jobs (
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  target_item_id TEXT NOT NULL,
  source_revision INTEGER NOT NULL CHECK(source_revision >= 0),
  created_by TEXT NOT NULL REFERENCES users(id),
  owner_device_id TEXT NOT NULL,
  owner_device_name TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('queued','running','waiting','completed','cancelled','failed')),
  progress_text TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1 CHECK(version > 0),
  lease_expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  output_image_id TEXT,
  error_code TEXT,
  last_operation_id TEXT,
  PRIMARY KEY(project_id,id)
);
CREATE INDEX generation_jobs_project_created ON generation_jobs(project_id,created_at DESC,id DESC);
CREATE TABLE generation_job_operations (
  project_id TEXT NOT NULL,
  job_id TEXT NOT NULL,
  operation_id TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  actor_session_id TEXT NOT NULL,
  resulting_version INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY(project_id,job_id,operation_id),
  FOREIGN KEY(project_id,job_id) REFERENCES generation_jobs(project_id,id) ON DELETE CASCADE
);
