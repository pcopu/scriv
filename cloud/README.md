# Scriv Cloud

Cloudflare Workers API for the native Scriv Mac app. The service uses the existing
Workers Paid plan, D1, SQLite Durable Objects and a private R2 bucket. A separate
Redis service is not required: project Durable Objects provide the serialized
write authority, editing leases and WebSocket presence distribution.

The plan starts at $5/month; included usage is not an unlimited bill cap. R2 and
optional TURN relay usage have their own allocations and overage pricing. See the
[Cloudflare Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/),
[R2 pricing](https://developers.cloudflare.com/r2/pricing/) and
[TURN pricing](https://developers.cloudflare.com/realtime/turn/).

## Local verification

Node 22.14 or later is required. Dependencies and their lockfile are pinned.

```sh
npm ci
npm run check
npm test
npm run test:load
npm run build
```

`build` is a Wrangler **dry run**. Tests use the real local Workers runtime,
D1/SQLite and R2 emulation. Provider requests are mocked in integration tests;
these do not charge Stripe or OpenAI. `test:load` exercises 500 authenticated
WebSocket connections, presence, 100 concurrent independent script writers,
and delivery of 50,000 mutation observations. Local timings are not a production
SLA. Exact results and untested production cases are recorded in
[`../docs/backend-verification.md`](../docs/backend-verification.md).

For interactive development, copy `.dev.vars.example` to `.dev.vars`, fill in real
OAuth credentials and use:

```sh
npm run db:migrate:local
npm run dev
```

There is no development-auth bypass in production or local routes. The OAuth
provider callback for local work must exactly match the configured origin. Use
an HTTPS tunnel if the provider does not accept your loopback callback. The Mac
client can target `http://127.0.0.1:8787` in Settings.

## Deployment sequence

No infrastructure is provisioned by `npm ci`, tests or build. A deployment agent
must supply the account-specific settings below.

1. Authenticate Wrangler to the intended Cloudflare account. Confirm Workers Paid
   and R2 are enabled.
2. Create D1 and the private R2 bucket:

   ```sh
   npx wrangler d1 create scriv
   npx wrangler r2 bucket create scriv-media
   ```

3. Set `d1_databases[0].database_id` in `wrangler.jsonc` to the returned ID and
   `vars.PUBLIC_URL` to the actual HTTPS Worker/custom-domain origin. Keep
   `ENVIRONMENT=production`. Configure the desired route/custom domain.
4. Create a GitHub OAuth App for Scriv. Callback:
   `https://<api-origin>/auth/github/callback`. Store its client ID and secret as
   Worker secrets. The Mac signs into Scriv through the system web session with
   a separate PKCE verifier; it receives a single-use code at
   `scriv://auth/callback`. OpenAI credentials are never sent to this service.
5. In Stripe, create **one recurring USD $9.99/month Team price**. Its quantity is
   always 1 per team. Membership has no seat limit or per-seat charge. Activate
   the customer billing portal. Put these secrets into Workers:

   ```sh
   npx wrangler secret put GITHUB_CLIENT_ID
   npx wrangler secret put GITHUB_CLIENT_SECRET
   npx wrangler secret put STRIPE_SECRET_KEY
   npx wrangler secret put STRIPE_TEAM_PRICE_ID
   npx wrangler secret put STRIPE_WEBHOOK_SECRET
   ```

6. Register a Stripe **snapshot** webhook at
   `https://<api-origin>/billing/webhook`, using API version `2025-04-30.basil`.
   Events: `checkout.session.completed`,
   `checkout.session.async_payment_succeeded`, `customer.subscription.created`,
   `customer.subscription.updated`, `customer.subscription.deleted`,
   `invoice.paid`, `invoice.payment_failed`. Run test-mode checkout/cancel/renewal
   and duplicate/out-of-order event scenarios before switching to live keys.
   Successful redirects never grant subscription entitlement; only canonical
   provider state does.
7. For reliable internet P2P across restrictive NATs, create a Cloudflare Realtime
   [TURN key](https://developers.cloudflare.com/realtime/turn/generate-credentials/).
   Add `TURN_KEY_ID` and `TURN_API_TOKEN` secrets. The authenticated
   `/ice-servers` route issues one-hour credentials. Without these secrets only
   STUN/direct connections are available, so some peer pairs cannot connect.
8. Apply migrations, validate and deploy:

   ```sh
   npm run check:config
   npm run db:migrate:remote
   npm run deploy
   ```

9. Run the production smoke checklist below with two real accounts on two Macs.
   Set the Mac release's `ScrivCloudURL` to this HTTPS origin before packaging.

## Data ownership and schema

D1 stores users, hashed sessions, OAuth states and exchange codes, teams,
membership, hashed/revocable join links, project catalog, billing events,
subscriptions and image replica reservations. The D1 migration is
[`migrations/0001_identity_teams.sql`](migrations/0001_identity_teams.sql).

One SQLite `ProjectRoom` Durable Object owns each project's items, immutable
command history and before/after changes, receipts, edit leases, discussions,
peer signaling inbox and head/epoch/timing counters. Every accepted item batch
and its history receipt commit in one `transactionSync`. This avoids a split
transaction between D1 and the live project state. Schema initialization is in
[`src/project-room.ts`](src/project-room.ts).

A per-team `BillingCoordinator` serializes checkout and canonical Stripe state
reconciliation. An old subscription event cannot replace a newer active
subscription. Hourly maintenance retries missed billing updates, removes expired
OAuth/rate-limit state, and resolves abandoned R2 reservations.

R2 keys are private, immutable project/content-hash addresses. Upload bytes are
hashed and checked against the path; content signatures must match PNG/JPEG/WebP
MIME types. D1 triggers reserve/release team storage atomically across projects.
Defaults: 25 MiB per image and 10 GiB per team. These are storage limits, not seat
limits. Media belongs to the project and retains independent logical image
versions and timed placements.

## Collaboration rules

- Script-item leases last 30 seconds and renew every 10 seconds. Lease tokens
  are secret; fences monotonically increase. Each lease is bound to both the
  authenticated device session and the editor-window session.
- Existing items require a current lease and expected version. Creates use
  version 0. Batches are atomic, up to 100 operations/512 KiB.
- `POST /import` bootstraps an empty project atomically, up to 10,000 items/16 MiB.
  It supports cyclic character-portrait references and returns a snapshot hint.
- Timeline geometry changes require `expectedTimingVersion`. Word/text edits
  increment this version so pending cut edits can detect stale word timings.
  Text-only edits inside an unchanged owned duration remain independent under
  their item leases, allowing many writers on separate lines. They retain all
  item/reference checks while avoiding redundant whole-scene cue scans.
- Receipt replay precedes fresh lease/epoch/timing checks after current read
  authorization. A reused command ID with a different body is rejected.
- History restore appends a new event, advances epoch and timing version, and
  invalidates all leases. It does not rewind membership, billing or discussions.
- Hibernating WebSockets carry durable event notifications and ephemeral
  presence. Clients repair gaps from ordered HTTP replay; two-second watermarks
  detect a missed final event. Durable notifications are batched for up to 50 ms,
  64 events or 256 KiB. Presence is limited to 5 Hz per user connection; full
  snapshots broadcast at most 5 Hz for up to 100 sockets, and 1 Hz above that.
  Room capacity is 1,000 simultaneous sockets, with no team membership cap.
- Members are reauthorized on incoming messages. Removal, logout and billing
  changes also actively revalidate/close affected live sockets. Viewers may
  discuss but cannot edit. Lapsed teams retain a 30-day read/export window for
  members; owners retain access. No automatic content deletion is implemented.
- Thread identity is item identity, not its displayed position. Message sends
  are idempotent and use `(timestamp,id)` pagination to avoid same-time gaps.

The complete native contract is [`../docs/cloud-api.md`](../docs/cloud-api.md).

## Operations and recovery

Watch Worker error rates, CPU time, D1 reads/writes/storage, Durable Object
requests/duration/SQLite storage, R2 operations/storage and TURN relay bytes.
Configure Cloudflare usage notifications and account limits as appropriate for
expected traffic. Keep the private bucket inaccessible via public R2.dev URLs.

Use D1 export/Time Travel for identity/catalog recovery. Export projects through
native `.scriv` packages or the authenticated snapshot/events endpoints for
portable content recovery. The project event journal is immutable application
history, not an independently stored disaster-recovery backup. Production setup
must include a periodic external export job and a restore drill appropriate to
its retention requirements. Avoid rolling back destructive schema changes;
add forward migrations and test old-client compatibility.

## Production smoke checklist

- Fresh GitHub sign-in; expired/mismatched PKCE rejection; logout and session
  revocation; no credential leakage in logs or redirect URLs.
- Free solo create/edit/save/history and a second signed-in device syncing script.
- Team test checkout at exactly $9.99, join-link reuse/revocation, member removal,
  viewer access, portal cancellation, restoration and late webhook delivery.
- Two Macs editing different lines; same-line exclusion; lost connection;
  lease expiry; restart; replay; stale draft recovery; restore during editing.
- Character links, media tags and line/direction/image discussion anchors.
- Hosted image upload/download/hash verification; concurrent quota accounting;
  downgrade read/export behavior.
- Direct WebRTC media transfer and TURN-only transfer on separate networks;
  offline peer failure and premium hosted fallback.

Do not label a release fully deployed or paid billing verified until these
account-bound smoke checks have actually run.
