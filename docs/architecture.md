# Current architecture and schema

This is the implemented architecture for the rebuilt Scriv app. It supersedes the earlier Postgres/Redis and $10 owner-subscription proposal preserved in [multiplayer-design.md](multiplayer-design.md). The price is **USD $9.99 per team per month**, with no per-seat charge.

## System ownership

| Component | Owns |
| --- | --- |
| Native SwiftUI/AppKit app | Editing, word/direction timing, playback, character/image UI, local drafts, generation and device media. |
| Portable ScrivCore | Value models, timing invariants, local package/history storage, import/export, hashes and reconciliation. |
| Worker | HTTP entry points, authentication, authorization, provider integrations and routing. |
| D1 | Users, hashed sessions, teams/membership, invitation links, project catalog, billing entitlements and hosted-media accounting. |
| Project SQLite Durable Object | Accepted project items, leases, history, idempotency, discussion, signaling and WebSocket room coordination. |
| Billing Durable Object | Serializes checkout and canonical subscription reconciliation for one team. |
| R2 | Private paid image replicas, addressed by project and digest. |
| Local Codex | ChatGPT sign-in, model access and image-generation execution on the user's Mac. |

SQLite Durable Objects provide the project coordinator and live distribution role originally proposed for Redis. Each project has one authority, and independent projects can use independent objects. A separate Redis or Postgres service is not required for this implementation. Clients never connect directly to any database.

## Content model

| Entity | Important fields and relationships |
| --- | --- |
| Project | Stable ID, title, ordered scenes, entries, characters, images, cues and local revision. |
| Scene | Stable ID, title and order. |
| Entry | Scene ID, order, dialogue/direction kind, exact text, speaker ID, owned duration, forward coverage, words and optional persisted UTF-16 character identity links. |
| Word | Stable ID, exact text, start/end milliseconds relative to its entry and optional authored-timing marker. |
| Character | Stable ID, name, aliases, biography, appearance, color and optional portrait image-version ID. |
| Image | Stable asset ID and version, prior-version link, filename, MIME type, byte count, SHA-256, creation time, prompt/metadata and explicit depicted-character tags. Bytes are immutable; tags can be edited. |
| Cue | Stable ID, scene, resolved start/end, optional script-entry start anchor and authored forward duration, label, prompt and image-version ID. |

Script and direction text remain authoritative. Character names are linked without rewriting the wording. Image tags describe the people actually depicted, not every character mentioned in nearby dialogue. One entry can have multiple cues, and a cue can span neighboring entries. Image bytes and cue timing are separate records.

### Time invariants

- Scene time is the sum of entries' owned durations in order.
- Dialogue owns positive time. A direction can own zero or positive time.
- A direction begins at its authored position and can cover only itself and later content.
- Direction coverage cannot end before its own action slot ends and does not advance sequence time.
- Word times remain ordered and inside their dialogue duration. Explicit authored endpoints survive compatible text edits; incompatible edits fail without canonical mutation.
- Source-owned images move with their source and retain authored extent across scene-tail clipping. Valid anchored overlap remains separate; playback uses the latest-starting active cue.
- A zero-owned direction can own an image at offset zero; a scene-tail placement may be dormant without losing its authored extent.
- Moving a shared image cut preserves the combined duration and prevents a zero-length cue.
- Dragging a selected contiguous prefix to the previous image or suffix to the next image changes the cut/assignment while preserving source word order and timestamps. Non-edge selections cannot move past unselected words.

The design fixture retains full-scene absolute offsets. The bundled playable excerpt starts at zero and uses the same relative durations/cuts.

## D1 schema

The schema is executable in the ordered [`cloud/migrations`](../cloud/migrations) files. Email authentication is additive in `0003_email_auth.sql`; existing identity/project foreign keys remain intact.

| Table | Purpose and key constraints |
| --- | --- |
| `users` | Internal identity keyed by UUID. Legacy GitHub IDs remain unchanged; email-only users use a reserved nonnumeric provider-key namespace for compatibility. |
| `email_identities` | Normalized verified email mapped uniquely to one user. Never inferred from an existing GitHub contact email. |
| `email_auth_challenges` | Hashed random challenge ID/code, PKCE binding, expiration, sent state, bounded attempts and single-use consume marker. No plaintext code is stored. |
| `sessions` | Hash of opaque bearer token, server-issued device/session ID, user, device name, expiration and revocation. Raw token is returned only at issuance. |
| `oauth_states` | Short-lived hashed OAuth state, original native state and PKCE challenge. |
| `auth_codes` | Single-use hashed native exchange code bound to the user and PKCE challenge. |
| `teams` | Owner, name, Stripe customer/subscription state, paid-until date, reconciliation timestamps and reserved media bytes/quota. |
| `team_members` | Composite `(team_id,user_id)` key; owner/admin/member/viewer role. |
| `join_links` | Hashed bearer invitation token, granted role, creator, expiry and revocation. Reusable without a seat counter. |
| `projects` | Project catalog: owner, optional team, title, creation/update timestamps and archive marker. Content resides in its room. |
| `billing_events` | Unique provider event ID and processing timestamps for webhook deduplication. |
| `assets` | `(project_id,sha256)` identity, R2 key, asset version, byte count/type, uploading/ready/deleting state and uploader. |
| `security_limits` | Expiring counters for public auth and authenticated request rate limits. |

Asset insert/delete triggers reserve and release team quota atomically. This prevents two simultaneous uploads from separately checking the same remaining capacity and both exceeding the limit. Reconciliation repairs abandoned upload/delete operations across the D1/R2 boundary. D1 and R2 do not pretend to be one database transaction.

## Project room schema

The room's schema is initialized in [`cloud/src/project-room.ts`](../cloud/src/project-room.ts).

| Table | Purpose |
| --- | --- |
| `schema_migrations` | Room schema-version markers. |
| `meta` | Project ID, restore epoch, accepted history sequence and timing version. |
| `items` | Stable ID, kind, version, JSON payload, tombstone and indexed scene/order/timing columns. |
| `word_owners` | Indexed live word-to-entry identity ownership; updated atomically with content and restore, with a forward migration for existing rooms. |
| `leases` | Item, authenticated device session, editor-window session, random token, monotonic fence, expiry, epoch and user display data. |
| `events` | Immutable accepted command sequence, actor, time, epoch, kind and metadata. |
| `changes` | Per-item before/after content attached to an event. |
| `receipts` | Command ID, submitting user, canonical request hash and exact accepted response. |
| `threads` | One project thread and one canonical thread per item, stable anchor and resolved state. |
| `messages` | Idempotent message UUID, author, immutable body, optional parent reply, attachment versions and time. |
| `signals` | Short-lived authenticated device-to-device signaling inbox. Image bytes never enter this table. |

Generic items let one atomic command validate and modify a scene, entry, cue or image reference together without duplicating the native content model across unrelated endpoint schemas. Server validation still checks each supported item kind and its cross-references.

## Editing, offline work and history

Entering edit mode obtains a 30-second exclusive item lease, renewed every 10 seconds. A lease is scoped to the authenticated device and the native-client editor session. Ownership, token, fence, item version, expiry and restore epoch are checked server-side. A restored or revoked session cannot reuse an old lease. Different entries can be edited concurrently.

Each command has a unique ID and expected versions. Direct commands support 100 operations/512 KiB; larger indivisible edits stage immutable upload parts, then commit up to 10,000 operations with separate 16 MiB upload and before/after history budgets. The room commits content, before/after changes, the history event and receipt in one SQLite transaction. A retry with the same payload gets the original receipt; reusing the ID for different content fails. Authorization is checked before honoring a retry, so a former member cannot use old command receipts to regain access.

Timing-changing commands also use an expected project timing version. This prevents simultaneous duration/cut edits from shifting the same sequence inconsistently. Independent text edits under separate entry leases can proceed; they still advance the timing counter so an older pending word/cut operation cannot overwrite newly timed text.

The native app persists a bounded local editor-recovery journal outside project packages, plus a scoped command outbox. Invalid text is journaled before native acceptance but never installed in canonical/cloud state; source/epoch drift requires review, and recovery clears only after successful disk save or explicit discard. Reconnecting compares the last durable canonical checkpoint, the local draft and current remote items. Unchanged or independently changed items can merge; same-item conflicts are retained for explicit review. Network failure does not silently discard the local draft or mark an unaccepted change as cloud-saved.

Cloud history is an append-only sequence. New thread/message/resolution mutations share its sequence and watermark, storing their discussion payload and an empty item-change list atomically with the discussion update. Lost socket notifications therefore recover through the same replay path as content. Existing pre-upgrade discussion remains readable without inventing historical sequence numbers. Restore reconstructs a selected content state and writes a new event under a new epoch. It invalidates leases. It does not rewind membership, subscriptions or conversation messages. Local project history stores complete native snapshots and remains usable offline. Both cloud event and message clients page through results; messages use a two-part `(at,id)` cursor, with monotonically advancing per-thread timestamps for new sends. Replay responses are byte-bounded; oversized events request a fresh snapshot while preserving the full journal changes. Native clients also refresh the active discussion after snapshot replacement so skipped message payloads are recovered.

The new-project import endpoint validates and commits up to 10,000 items / 16 MiB atomically. It supports cyclic character/portrait references by validating after the entire proposed state is present. It is only available for an empty project, making retries safe without partial bootstrap state.

## Live collaboration and access changes

Premium rooms use authenticated WebSockets. Accepted changes are streamed with a durable sequence; reconnect uses replay after the last applied sequence. Watermarks detect gaps. Presence includes real item/selection/cursor data and is transient, expiring after 30 seconds. Client presence is limited to 5 Hz. Presence movement is not a history revision.

Membership, session and subscription changes notify affected rooms. Messages are reauthorized server-side, and revoked access closes/rejects the corresponding live connection. Revoked sessions, removed members and viewer downgrades immediately invalidate affected edit leases even when no socket is open; their monotonically increasing fencing rows are retained. Read-only viewers cannot obtain write leases or send content mutations. An item editing lease does not lock its discussion thread. Both browser text and native UTF-8 binary JSON frames use the same validated protocol; a missing signal recipient or stale cursor target does not disconnect the sender's valid room connection.

Free personal projects use authenticated HTTP synchronization and history. Same-account devices can exchange authorized peer signals over HTTP. Multiple people collaborating on a project require an active team subscription. Team size is not a billable seat count; room connection limits protect a single coordinator from overload.

## Media transfer and storage

The cloud stores image metadata for both plans. Local media is addressed and verified by SHA-256. The WebRTC bridge can serve only hashes that the current project authorizes. It splits data into bounded chunks, applies backpressure and verifies the complete digest before native import. Missing media, corrupt content, oversized transfers and unsolicited transfers fail explicitly.

Initial WebRTC negotiation has one deterministic offerer: the device with the lexicographically lower server-issued device ID. The higher-ID device answers, regardless of which peer requested the image. When the higher-ID peer needs a connection, it sends an authenticated `asset-request` signal with `action:"connect"` and a unique connection-attempt `requestId`; the lower-ID peer starts the offer even without a local image request. Both sides use the negotiated `scriv-media` channel with ID `0`, so simultaneous requests reuse one transport. Rebuilding a closed connection uses a new attempt ID to distinguish it from a duplicate signal. This connection control action is routed to the transport separately from hash-based image discovery and does not authorize media by itself.

Peer signaling uses server-issued device identities and authenticated project access. The Worker derives the sender identity, checks the recipient's unexpired and unrevoked session, and authorizes both users for the project before relaying the bounded control payload. Same-account device signaling remains free; signals between different accounts require an active team subscription. These gates also cover connection requests. The browser bridge has no bearer credential. Short-lived TURN credentials can be issued by Cloudflare Realtime TURN when configured; otherwise the response supplies STUN and restrictive NATs may prevent a direct connection. A TURN relay forwards encrypted peer traffic; it is not a durable image store.

Premium R2 media is private. Every read/write is authorized through the Worker. Upload verifies content type, actual bytes, SHA-256, file limit and team quota. The default is 25 MiB/image and 10 GiB/team. No permanent public media URLs are issued. A cloud replica can be recovered into a local package without changing image identity or timing.

## Identity and billing

Email OTP is the primary Scriv sign-in. Six-digit codes expire after ten minutes, allow at most five attempts and are bound to an in-memory native PKCE verifier. A D1 transaction consumes the challenge and creates/reuses the explicitly verified email identity and session. Email identities never silently merge with GitHub contact addresses. Legacy GitHub OAuth remains optional with PKCE/state and the single-use `scriv://auth/callback` exchange. Both flows store the opaque session in the API-origin-scoped Keychain; the server stores only its hash. HTTPS is required for remote API endpoints; loopback HTTP is allowed for development.

The Team price is exactly one recurring monthly USD 999-cent Stripe price at quantity one. Checkout and portal require the team owner. The server checks the configured price before creating checkout. A per-team billing coordinator serializes checkout attempts and reconciliation. Signed webhook events trigger retrieval of the customer's current matching subscriptions, so an old cancellation notification cannot override a newer active subscription. Duplicate events are idempotent.

Cancellation/downgrade removes paid write/collaboration capability according to the entitlement state. The current policy allows 30 days of authorized read/export grace for a lapsed team project. Membership and media remain private; changing billing does not publish data or erase local project packages.

## Local Codex boundary

Scriv starts only the executable selected on that Mac and communicates through app-server JSON-RPC. An external connection is restricted to loopback. Initialization, account state, ChatGPT login, model listing, threads, turns, progress and interruption use the app-server protocol. Generation runs in a fresh directory with copied references and imports a real image file after checking the path, size and content. An unavailable runtime capability produces a visible error.

The user's Codex account and its usage are independent of Scriv billing. No shared operator ChatGPT login, unofficial image-generation HTTP endpoint or stored ChatGPT cookie is part of the service. The production release checklist includes a real-account image-generation test because protocol tests cannot establish account entitlement.

## Operations and verification

Production resources are not provisioned by this repository's tests. The [handoff](deployment.md) covers D1/R2 creation, Durable Object deployment, OAuth, Stripe, TURN, signing/notarization and operational smoke tests. The [verification report](verification.md) distinguishes local runtime/load results, actual macOS builds and production-only checks. The $5 Workers base fee is an infrastructure starting point, not a total-cost cap or a latency promise.
