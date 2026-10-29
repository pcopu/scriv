# Durable local generation jobs — 2026-10-29

## Implemented cloud contract

`cloud/src/generation.ts` and D1 migration `0002_generation_jobs.sql` persist
**metadata only**, with no new service or infrastructure binding. The Worker does
not call Codex or any image provider. Prompts, reference files, local paths,
provider thread IDs and credentials remain in the Mac's local journal; unknown
request fields are rejected.

All routes require the existing authenticated project access:

- `GET /v1/projects/:projectId/generation-jobs?limit=100&cursor=<opaque cursor>`
  returns `{jobs,nextCursor:string|null}`. Follow every cursor for complete
  recovery/history. Pages are newest-first, stable by creation time and job ID.
- `GET .../generation-jobs/:jobId` returns `{job}`.
- `POST .../generation-jobs` takes `{id,targetItemId,sourceRevision}` and returns
  `{job}` (201 new, 200 identical replay). Reuse with different immutable inputs
  is a 409. Create does not grant execution permission.
- `POST .../generation-jobs/:jobId/claim` takes
  `{operationId,expectedVersion,recover?:true}` and returns `{job}`.
- `PATCH .../generation-jobs/:jobId` takes
  `{operationId,expectedVersion,status,progressText?,outputImageId?,errorCode?}`
  and returns `{job}`. Status is `running`, `waiting`, `completed`, `cancelled`
  or `failed`. Progress is one line, at most 160 characters. Error codes are
  short machine identifiers, not raw provider responses. Bodies are limited
  to 4 KiB.

The response job has `schemaVersion:1`, `id`, `projectId`, `targetItemId`,
`sourceRevision`, `status`, `progressText`, `createdAt`, `updatedAt`, `createdBy`,
`ownerDeviceId`, `ownerDeviceName`, `version`, `leaseExpiresAt`, `outputImageId`
and `errorCode`. The final two fields are nullable; all others are present.
Timestamps are Unix milliseconds. Job/operation IDs are UUIDs; target/output
item IDs use the existing opaque project-item format. All ID casing is preserved. Device identity/name come from the server's
session, never a caller-supplied device claim.

## Ownership and recovery

Only the creating user controls a job. Other authorized project readers can
inspect progress; viewers cannot create/claim/update. Solo and team owners retain
the same write access as existing project commands. Other team members require
an active paid entitlement and writable role. Every mutation atomically checks
current project/archive state, membership, billing and initiating session with
its version compare-and-swap, after request-body and hashing waits.

A claim lasts 90 seconds. The owning Mac renews with a `running` PATCH about every
30 seconds. An expired or revoked queued/running owner is displayed as `waiting`
with `Waiting for this Mac`; this is derived from durable timestamps and current
session state, so no scheduler or running Worker is needed. A live running claim
cannot be stolen, even by another Mac of the same user.

Recovering an expired running, paused, failed or cancelled job requires an
explicit `recover:true` claim. A queued job may first start on its original Mac;
changing Macs requires explicit recovery and an expired/revoked prior claim.
Recovery increments the version and fences all prior updates. Clients must not
automatically retry a potentially paid engine operation. A local recovered output
should be imported without rerunning the engine when available.

D1 transactions commit claim/state changes together with payload-hashed operation
receipts. Identical retries return **current** job state, not an obsolete running
grant. Reusing an operation ID with different input or another device fails. A
lost response therefore does not authorize a second engine execution. Callers
must verify the returned state, owning device and current version before work,
and stop publishing output if they lose their claim.

Completed jobs require an `outputImageId` and cannot be restarted or mutated.
The client should keep renewing while importing the immutable image into the
project and mark cloud completion only once the manifest accepts that output.
Local engine completion and project import are separate from cloud metadata;
this API does not bypass document item leases, version checks or authorization.
New generation after successful completion uses a new job ID.

## Local evidence

- `npm run typecheck --prefix cloud`: passed.
- Focused workerd run `npm test --prefix cloud -- --reporter=dot tests/generation.test.ts`:
  **14 passed**, zero failed (focused local run).
- Log: `/tmp/scriv-generation-tests.log`.
- Actual local D1 migrations/transactions tested; provider fetch throws if called.
- Cases include create/payload replay, concurrent claims, durable operation
  receipts, progress/completion, expired/revoked owner recovery, old-runner fences,
  role/project isolation, read-only grace, same-timestamp pagination, bounded
  metadata, and five paused-body access changes (removal, viewer downgrade,
  subscription lapse, session revocation, archive).

This is focused backend evidence, not an assertion that the final aggregate suite,
native macOS execution, distributed Mac recovery or deployed Cloudflare acceptance
has run. No deployment, provider generation, charge or account setting was changed.

D1 transaction semantics were checked against the
[official D1 binding documentation](https://developers.cloudflare.com/d1/worker-api/d1-database/#batch).
