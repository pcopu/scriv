# Scriv: multiplayer, storage, history, billing, and local Codex

**Design date:** October 28, 2026  
**Status:** Standalone greenfield implementation specification. The application, services, and integrations described below are intended behavior to build and validate; this document does not claim they have been implemented or deployed.

## 1. Product decisions

Scriv is a script-first Mac application. The script, its timing, characters, images, and discussions form one project. The main editor, Characters view, and Storyboard are views over that same project.

Scriv runs **Codex app-server on the user's Mac**. Scriv can start its own local process or connect to an existing local server. The cloud service handles scripts, collaboration, history, and premium image storage. It does not borrow an operator's ChatGPT account to generate everyone's images.

### Confirmed requirements

- Single-person use and hosted script storage are free.
- Multiplayer and hosted image storage are premium, priced at **USD $10/month through Stripe**.
- Images can move machine-to-machine using P2P on either plan.
- Collaborators see live changes, cursors, and selections.
- Entering edit mode on a script line excludes other people from editing that line until it is released.
- A full history timeline records accepted changes.
- A small bottom-right discussion panel supports project chat and a running conversation per character, script line, direction, or image.
- Scriv account sign-in and the local Codex/ChatGPT account are independent.
- The Mac application needs Start, Stop, and Connect controls for Codex.

### Proposed defaults, not additional confirmed pricing promises

The **project owner pays**. Their subscription enables premium features in their projects; invitees can participate using free Scriv accounts. Their own projects remain free unless they subscribe.

History of script content and personal annotations is included on the free plan. Free same-account device sync is allowed; inviting another person requires a premium project. One person's two devices still obey the same line-editing rules.

Storage quota, member limits, relay allowance, and retention periods are configuration, not constants embedded in the content format. Initial values must be costed and tested before advertising the plan as unlimited.

| Capability | Free personal project | Premium owner's project |
| --- | --- | --- |
| Script, timing, characters, image manifests | Hosted | Hosted |
| Local image files and local Codex generation | Yes, subject to the user's Codex access | Same |
| Script history and personal annotations | Yes | Yes |
| Other people's cursors and shared editing | No | Yes |
| Shared project and item discussions | No | Yes |
| P2P image delivery | Owner's authorized devices | Authorized project members' devices |
| Durable hosted image copies | No | Yes, within quota |
| OpenAI usage included in the $10 fee | No | No |

A free project can retain an image's identity, caption, tags, timing, and checksum in the cloud without uploading the image bytes.

## 2. Architecture

Use **Postgres + Redis + WebSockets**, with private object storage for premium media and a local asset cache on each Mac.

Postgres owns accepted project state, editing leases, history, and billing-derived entitlements. Redis carries short-lived presence and committed-change notifications. WebSockets deliver updates to clients. The server acknowledges a saved edit only after the database transaction commits.

~~~mermaid
flowchart TD
    M["Scriv for Mac"] -->|"Authorized commands and live updates"| S["Scriv sync service"]
    M -->|"Local process or connection"| C["Codex app-server"]
    S --> P["Postgres: content, leases, history"]
    S --> R["Redis: presence and notifications"]
    S --> O["Private premium image storage"]
    M <-->|"Authorized P2P image transfer"| D["Other project devices"]
~~~

**No direct client access to Postgres or Redis.** A live database experience means authenticated reads plus streamed, authorized writes through the mutation service. Browser/native clients, imports, MCP tools, and AI-assisted edits all use the same validation path.

Build the initial backend as a modular service with WebSocket handling and a background dispatcher. Separate deployments or regional sharding are later operational choices, not prerequisites for the schema.

### Local versus cloud responsibility

| On each Mac | In the Scriv service |
| --- | --- |
| Editor state and offline draft cache | Durable accepted project state |
| Local image files and P2P transfer | Membership and premium entitlements |
| Codex child process or connection | Change replay and project history |
| ChatGPT credentials and local AI sessions | Live presence routing |
| Generation execution and artifact validation | Premium image backup |
| Local job recovery after sleep/restart | Generation status metadata, without AI credentials |

A Mac going offline does not stop other collaborators editing the project. Its uncompleted local generation jobs wait for that Mac.

## 3. A simple data model with stable identities

Use one **items** table for the things the user can select and discuss. A spoken line, a direction, a character, an image, and an image cue all get stable IDs. An image cue is a placement in playback; an image is the visual identity it displays.

Use UUID primary keys, UTC database timestamps, integer milliseconds for playback, and monotonically increasing item versions. IDs never depend on displayed line numbers, array positions, filenames, or text content.

The following is a logical schema contract. Required uniqueness and relationships are part of the contract; database DDL and application validation must implement them together.

### Accounts and project membership

| Table | Essential columns | Keys and rules |
| --- | --- | --- |
| **users** | id; auth_subject; display_name; avatar_url; created_at | Unique auth_subject from the Scriv authentication provider. Do not use email as a stable cross-provider identity. |
| **devices** | id; user_id; label; public_key_or_pairing_ref; revoked_at; created_at | FK user_id. A device record is not proof that a device is online. |
| **projects** | id; owner_user_id; title; head_seq bigint; write_epoch bigint; timing_version bigint; schema_version; settings jsonb; created_at; updated_at | FK owner_user_id. head_seq starts at 0. The owner is the billing principal for this version. |
| **project_members** | project_id; user_id; role; joined_at; revoked_at | PK (project_id, user_id). Roles editor, commenter, viewer; owner authority comes from projects.owner_user_id. |

Invitations can use a small separate expiring invitation record when that workflow is implemented. They must never act as permanent public project passwords.

### Content, media, and discussion

| Table | Essential columns | Keys and rules |
| --- | --- | --- |
| **items** | id; project_id; kind; scene_id nullable; order_key; body jsonb; version bigint; created_by; updated_by; deleted_at; timestamps | PK id; UNIQUE (project_id, id). kind is scene, speech, direction, character, image, or image_cue. body is validated against the kind and schema version. |
| **item_links** | id; project_id; source_item_id; target_item_id; relation; anchor jsonb nullable | Same-project FKs to items. relation is speaker, mention, or depicts. One active speaker link per speech item. Mention anchors distinguish repeated occurrences. |
| **asset_versions** | id; project_id; image_item_id; version_number; provenance jsonb; created_by; generation_job_id nullable; created_at | Same-project FK to image item. UNIQUE (image_item_id, version_number). Immutable logical image revision; regeneration creates a version instead of overwriting one. |
| **asset_files** | id; project_id; asset_version_id; variant; sha256; byte_size; mime_type; width; height; created_at | Same-project FK to asset_versions. UNIQUE (asset_version_id, variant), such as original or thumbnail_480. Each immutable variant has its own checksum and byte count. |
| **asset_replicas** | id; project_id; asset_file_id; kind; device_id nullable; object_key nullable; state; verified_at; last_report_at | Same-project FK to asset_files. kind is device or hosted. One hosted replica per file; one device replica per file/device. Hosted rows have object_key; device rows have device_id. |
| **threads** | id; project_id; item_id nullable; status; version bigint; created_by; resolved_by nullable; resolved_at nullable; timestamps | One project thread where item_id is null; one canonical discussion thread per item otherwise. Enforce with two partial unique indexes. |
| **messages** | id; project_id; thread_id; author_id; body_md; anchor jsonb nullable; references jsonb; reply_to_message_id nullable; version; edited_at; deleted_at; created_at | Same-project/thread relationships. An optional reply must belong to this thread. References and anchors are validated, including attached asset versions. |

For hosted image versions, object keys are private storage locators, not public URLs. Signed URLs are generated when authorized access is requested.

Replica states are pending, verified, missing, and deleting. A historical device report does not establish current online availability. Hosted verification is performed by the server after upload finalization.

Logical image identity is separate from its versions and individual files. Replacing an image keeps its item discussion while preserving which version an older comment discussed. Cues and image-region comments pin a logical version; transfers and replicas identify a specific original or thumbnail file. A verified thumbnail never counts as a verified original. Retained versions and derivatives count toward storage usage.

Soft deletion preserves item IDs for history and discussion. Deleting a script line does not cascade-delete its comments or silently retarget its anchors to a neighboring line.

### Collaboration and operations

| Table | Essential columns | Keys and rules |
| --- | --- | --- |
| **edit_leases** | project_id; item_id; holder_user_id nullable; holder_session_id nullable; lease_token_hash nullable; fence bigint; write_epoch; expires_at nullable | PK (project_id, item_id), same-project FK. Preserve the row and fence after release. No lease data is restored from history. |
| **project_events** | project_id; seq bigint; event_id; actor_id; session_id; client_mutation_id; request_hash; operation; changes jsonb; result jsonb; created_at; published_at nullable; publish_attempts | PK (project_id, seq); UNIQUE event_id; UNIQUE (project_id, actor_id, client_mutation_id). History payload is immutable. Delivery metadata may change. |
| **project_snapshots** | project_id; seq; schema_version; content jsonb; checksum; created_at | PK (project_id, seq). Consistent project content at an exact event sequence. |
| **generation_jobs** | id; project_id; requested_by; device_id; runtime_id; target_item_id; source_head_seq; source_item_version; prompt_snapshot; reference_asset_version_ids; status; local_thread_id nullable; local_turn_id nullable; output_asset_version_id nullable; error_code; timestamps | Local execution journal is mirrored here when online. No OAuth tokens, Codex auth files, or general machine paths. |
| **subscriptions** | owner_user_id; stripe_customer_id; stripe_subscription_id; stripe_price_id; status; access_until; cancel_at_period_end; delinquent_since; grace_until; entitlement_version; synced_at | PK owner_user_id for the initial one-subscription-per-owner model; unique Stripe identifiers. Server-maintained only. |
| **billing_events** | stripe_event_id; event_type; resource_id; received_at; processed_at nullable; attempts; last_error; minimal_payload | PK stripe_event_id. Durable webhook inbox and idempotency record. Keep only necessary billing data. |

Do not add a permanent SQL table for every cursor movement or online heartbeat. Redis already serves that need.

### Indexes and validation

Index active items by project, kind, scene, and order_key; links by target/relation; messages by thread/created_at/id; events by project/seq; unpublished events with a partial index; files by version/variant; replicas by file and device; and jobs by owner/status.

All project-scoped foreign keys include project_id where practical. JSON references must be checked within the mutation transaction for existence, expected kind, and same-project ownership. Never assume that knowing a UUID grants access.

Use server-allocated sortable order keys. Moving a line changes its order key, not its ID. Rebalancing dense order keys is a structural command with version checks.

The shared JSON schemas are strict: reject unknown fields and invalid references. Preserve accepted timing, annotation, and sync fields across the client, transport, and persistence layers.

## 4. Script and timing representation

All three views use the same items. The schema carries the accepted design decisions:

- All script text has one left alignment.
- Directions alone receive vertical coverage controls.
- A direction starts at its authored position and can cover only later content.
- The curved top anchor is fixed; the lower endpoint changes coverage.
- Owned duration and coverage are separate.
- Spoken text has stable word IDs so cuts and annotations survive line renumbering.
- Character names are real links to character items, not matching text alone.
- Image character tags describe who is pictured.

### Typed item bodies

| Kind | Body |
| --- | --- |
| scene | Title and scene metadata. Its position establishes scene order. |
| speech | Exact source text, owned_duration_ms, and words containing stable IDs, text spans, and relative timing. Speaker identity is the speaker link. |
| direction | Exact text, owned_duration_ms, and coverage_end anchor. The source item's sequence position defines its fixed start. |
| character | Canonical name, aliases, description, reference image IDs. |
| image | Selected asset_version_id, caption, prompt/provenance metadata. Depicted characters are depicts links. |
| image_cue | image_item_id, pinned asset_version_id, and start/end anchors defining the playback placement. |

Pin a cue to a specific immutable asset version. Choosing a new version updates the cue through an explicit command; old history keeps the old version.

Anchors use stable item/word IDs, an edge, and an offset when needed. Examples below use readable aliases for UUIDs:

~~~json
{
  "kind": "direction",
  "body": {
    "text": "(To the farmer)",
    "owned_duration_ms": 0,
    "coverage_end": {
      "item_id": "direction_09",
      "edge": "start",
      "offset_ms": 400
    }
  }
}
~~~

Absolute starts are derived from authored order and the owned durations of speech/direction items. Characters, images, and cues do not themselves add another duration to the script.

A word's timing is relative to its speech item. A cue cut can refer to the edge of that word. Retain IDs for unchanged words after text edits. If a referenced word is removed, mark the affected cut/annotation as needing repair or retain a tombstone; do not attach it to a different word silently.

### Accepted page-12 example

These are provisional editorial timings, not measured audio:

| Direction | Owned time | Starts | Coverage ends | Coverage span |
| --- | ---: | ---: | ---: | ---: |
| (To the farmer) | 0.0s | 25.3s | 30.7s | 5.4s |
| Franklin looks between the boys and the invoice. | 2.4s | 30.3s | 35.5s | 5.2s |
| (Re: Miyazaki) | 0.0s | 32.7s | 35.9s | 3.2s |

The first overlaps the reaction by 0.4s. The reaction overlaps the final direction by 2.8s. All three can share the colored gutter rail without sharing one database record.

Randy's five-second speech at 25.3–30.3 spans three image cues: 1.4s, 2.4s, and 1.2s. In this example, the words “gung ho” belong to the middle image. Moving the cut changes the image assignment, not the script wording, ordering, or word timestamps.

### Timing commands are atomic

- **Extend direction:** update coverage_end only; owned time and subsequent speech stay unchanged.
- **Change owned time:** resize that authored slot and update the timing version. Later starts derive from the new sequence.
- **Drag image boundary:** adjust both adjacent cues together; preserve their combined span.
- **Move words to neighboring image:** require a contiguous source selection and update both cue assignments in one command.
- **Reorder/delete:** validate all affected sequence and word anchors together.

Require leases on edited items and expected versions on dependencies. Structural/timing commands also check projects.timing_version and increment it on every accepted timing or ordering change, including a text edit that changes word anchors. A content restore that changes timing increments it as well. A direction endpoint cannot precede its authored start or the end of its own positive-duration action.

## 5. Live writes and line ownership

The visible lock is an **application lease**, not an SQL transaction held open while someone types. Postgres row locks are used only within short claim, renewal, and mutation transactions. Ordinary readers can continue reading committed content while those transactions run. [Postgres locking](https://www.postgresql.org/docs/current/explicit-locking.html)

### Proposed editing behavior

Clicking into a line's editor requests its lease before enabling typing. Merely scrolling, selecting it for playback, or opening its discussion does not lock it.

The lease holder's name, color, and caret are visible. Other users can read, select/copy, play, and comment. They can request the line but cannot overwrite it.

Initial lease settings: **30-second expiry, renewed every 10 seconds**, released after pending edits are acknowledged when focus leaves. An explicit idle timeout can release an abandoned foreground selection. It must be distinct from the renewal interval.

Each claim gets a fresh random token and an incremented durable fence. Ownership includes the authenticated user and individual app session, so two windows belonging to the same user cannot both own the line.

Authorization has an explicit free-owner path: the owner can perform free personal content and discussion operations without a project_members row or premium subscription. A collaborator needs a current role permitting the command and the project owner's premium entitlement. The invitee's own subscription does not determine access. Viewer, commenter, and editor capabilities are checked per command.

Every command editing existing content items checks:

1. Owner authority, or the collaborator role and project entitlement required for this operation.
2. Correct session, token, fence, and project write_epoch.
3. Unexpired lease using the database's actual clock.
4. Expected item version and relevant timing version.
5. Valid typed payload and same-project references.

Check expiry after acquiring the row lock. Use clock_timestamp() for that check; PostgreSQL now() is fixed at transaction start and can be stale after waiting for a lock. [Postgres time functions](https://www.postgresql.org/docs/current/functions-datetime.html)

Never reset the fence by deleting/recreating the lease record. A delayed write from a sleeping Mac must fail after another session acquires the line. Redis restarting must not unlock it.

Lease transitions are atomic under the same consistent project/lease lock order: claim only a released, expired, or old-epoch lease; reject another session's unexpired claim. Renew only a matching, still-unexpired session/token/fence/epoch. Release is conditional on that same identity, so an old session cannot release its successor's lease. Reacquisition increments the fence.

Discussion commands require owner/commenter permission and message/thread version checks, not the parent item's editing lease. Creation of new items uses authorization, sequencing, and dependency versions; a lease is required when an existing content item is changed. This distinction keeps comments usable while a line is locked.

### Mutation transaction

A command carries a unique client_mutation_id, expected project epoch, affected item versions, lease proofs, and a typed operation. Actor identity comes from authentication, not a client-supplied user ID.

Within one short database transaction:

1. Authenticate and verify current read access, then lock the project's sequencing row.
2. Return the actor's stored receipt for an identical committed mutation ID; reject reuse with a different request hash. This happens before new-write entitlement, epoch, or lease checks, so a lost acknowledgment can be recovered after a restore or plan change.
3. For a new mutation, check the operation's current authorization, entitlement, and epoch.
4. Lock affected items/leases in deterministic order where the operation requires them.
5. Check the appropriate versions/leases and apply all changes.
6. Increment head_seq and item versions.
7. Append one event containing the command's reversible row changes and result.
8. Commit, then acknowledge with sequence and resulting versions.

Use transactional per-project head_seq, not a global serial ID as if it represented commit order. Sequence values can have gaps and do not by themselves establish transactional commit ordering. [Postgres transaction behavior](https://www.postgresql.org/docs/current/transaction-iso.html)

The simple sequencing row serializes project writes. It is an intentional first-version tradeoff to benchmark, especially when many people edit one project.

## 6. Streaming delivery and reconnect

The event log doubles as a transactional outbox. A dispatcher publishes a project/sequence notification through Redis, then records delivery. A crash after publishing can create a duplicate; sequence-based deduplication handles it.

Redis Pub/Sub can lose notifications for disconnected subscribers. It is acceptable here because accepted content and replay remain in Postgres. Redis is not the sole history store. [Redis delivery semantics](https://redis.io/docs/latest/develop/pubsub/)

Each client tracks last_applied_seq:

- Join with a consistent snapshot and its head sequence while subsequent notifications are buffered.
- Apply events in sequence order and ignore duplicates.
- Fetch missing events when a gap appears.
- Receive a lightweight head watermark periodically, initially every two seconds, so a lost final notification is detected.
- If the backlog is too large, load a fresh consistent snapshot and resume.
- Bound socket buffers and use backpressure. Disconnect/replay a slow consumer instead of growing memory indefinitely.

Use one Redis notification channel per project, scoped by environment. Every WebSocket node with subscribers receives the wakeup. Redis Streams may later help job workers; one consumer group across all WebSocket nodes would distribute work rather than broadcast every update to every node. [Redis consumer groups](https://redis.io/docs/latest/commands/xreadgroup/)

### Cursor and presence traffic

Presence contains project ID, authenticated user/session, item ID, item version, caret/selection offsets, and a monotonic session presence counter. Define offsets as UTF-16 code units for a consistent wire format; convert explicitly at editor and native text API boundaries.

Start with at most **5 cursor updates per second**, latest update wins, 10-second heartbeats, and 30-second presence expiry. Batch outgoing updates. Send detailed cursors for visible items and roster-level presence for the rest.

Transform positions through accepted text patches when possible; hide stale selections if their referenced version cannot be reconciled. Presence, lease renewals, and mouse motion do not create history entries.

### Offline edits

A disconnected device cannot promise it still owns a server lease. Keep typing as a clearly labeled local draft.

On reconnection, refresh membership, replay changes, acquire a new lease, and compare the draft's base version. Apply automatically only when the base still matches. Otherwise preserve the draft and offer a comparison/suggestion. Do not silently overwrite newer text.

A text CRDT is unnecessary for this initial exclusive-line model. If simultaneous typing in the same line or automatic conflicting offline merges becomes a requirement, that is a separate collaboration-model change.

## 7. Full history and restore

Full history means every **server-accepted content and discussion command**, including text, timing, character tags, selected image versions, comments, edits, resolutions, and deletions. It excludes unsubmitted keystrokes, cursor movement, and temporary presence.

The history UI groups rapid typing into readable sessions while retaining underlying events. Users can inspect actor, time, affected items, and before/after changes.

Create consistent content snapshots periodically, initially every 1,000 events or five minutes of active changes. Grouping and snapshotting must not delete the event record.

Restoring content creates a new event:

1. Reconstruct the chosen revision for a read-only preview.
2. Require the expected current head sequence.
3. Recheck that head inside the commit transaction.
4. Increment write_epoch to invalidate outstanding leases and drafts' write authority.
5. Apply restored content with stable IDs and new current versions.
6. Append the restoration event and notify clients to refresh.

Do not rewind memberships, billing, account identity, device trust, lease fences, or later discussion messages. Threads on removed items remain accessible through archived items/history.

Image restoration requires the old bytes to survive. Premium retains referenced image versions within the announced storage policy. Free history retains metadata and references; an old image may be unavailable if no local replica remains.

“All changes saved” means the content transaction was acknowledged. “Backed up” means the image upload was independently verified. These are separate statuses.

## 8. P2P images and hosted storage

Use authenticated project WebSockets for peer discovery and signaling, then on-demand WebRTC DataChannels for image bytes.

Fetch order: verified local cache; authorized online peer; premium hosted copy; otherwise a clear unavailable-image placeholder. Script editing must continue when an image is unavailable.

P2P is a delivery method, not a durability promise. A free device cannot fetch an image from a sleeping Mac unless another authorized online device already holds it. Premium therefore uploads a verified hosted copy even if the image was successfully sent to a peer.

WebRTC uses ICE/STUN and may require TURN relay when a direct connection cannot be established. TURN consumes relay bandwidth and does not store the image. Prefer an existing premium object copy over an expensive long relay transfer. [WebRTC protocols](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Protocols)

### Transfer contract

- Issue short-lived tickets scoped to project, sender, receiver, exact asset file/version, and size.
- A hash identifies content; it does not authorize access.
- Transfer chunks with backpressure and negotiated message-size limits; start with 16 KiB chunks.
- Verify final byte size, checksum, and decodability before marking a replica verified.
- Retry/resume transfers without creating a second logical asset.
- Create peer pairs only on demand; never form a complete mesh among all collaborators.
- Start with two concurrent image transfers per device, prioritizing current/near-playhead images.
- Recheck membership for signaling and hosted URLs; expire transfer tickets quickly.

DataChannels provide encrypted transport, but Scriv still supplies project authorization. [WebRTC DataChannels](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Using_data_channels)

Direct peers may learn network addresses. An optional relay-only mode trades bandwidth for avoiding direct address exposure. Revocation stops future authorized access; it cannot erase an image someone already downloaded. [WebRTC specification](https://www.w3.org/TR/webrtc/)

### Quota and downgrade policy to finalize before launch

A starting proposal to cost is 10 GiB hosted media per owner and a 25 MiB per-image limit. These are configurable candidates, not validated unit economics. Count thumbnails, retained versions, and reserved upload bytes.

When full, keep script editing, existing downloads, deletion, and local generation available; pause new hosted uploads with a clear quota state.

A proposed downgrade grants a 30-day read/export recovery window. During it, the owner retains free editing; existing collaborators can read scripts, history, discussions, and existing media, but cannot edit or post. Existing-member P2P discovery and hosted downloads remain available during that window; invitations and new hosted uploads stop. Afterward, project access becomes owner-only, including WebSocket subscriptions, peer tickets, discussion reads, and signed-URL issuance. Already downloaded copies cannot be revoked. The owner's scripts, references, and history remain available on the free plan. No automatic purge is implemented by this document; finalize retention, recovery messaging, and media-deletion policy before enabling billing.

## 9. Stripe subscription

Create one monthly USD $10 Price and use hosted Checkout plus the Customer Portal. The backend selects the allowed Price and authenticated customer mapping.

Premium is a server-derived entitlement. A Checkout redirect or a client field such as isPro cannot grant it.

### Webhook handling

Verify the signature against the raw body, durably insert billing_events by unique Stripe event ID, then acknowledge. Process asynchronously and serialize reconciliation per owner.

Stripe events can be duplicated and delivered out of order. Refresh canonical subscription state rather than applying an old webhook snapshot over newer entitlement state. Retry safely and reconcile periodically. [Stripe webhooks](https://docs.stripe.com/webhooks)

Use idempotency keys for retried customer/Checkout creation. [Stripe idempotent requests](https://docs.stripe.com/api/idempotent_requests)

### Proposed access policy

| State | Scriv behavior |
| --- | --- |
| active | Premium available according to verified subscription/payment state |
| trialing | Premium only if Scriv explicitly offers a trial |
| incomplete / incomplete_expired | Free |
| past_due | Optional seven-day grace from first delinquency; repeated failures do not reset it |
| Cancel at period end | Keep access through the paid period |
| canceled / unpaid / paused / grace expired | Owner retains free use; collaborator writes, invitations, and hosted uploads stop |

Use the current subscription and associated payment state together; a paid invoice alone is not always an active subscription. Handle an old canceled subscription without revoking a newer active one. [Subscription events](https://docs.stripe.com/billing/subscriptions/webhooks)

On entitlement changes, increment entitlement_version, notify active sessions, and recheck permission on every subsequent write. Project ownership transfers require an explicit billing/entitlement transition, not just changing a client field.

## 10. Two accounts and the local Codex lifecycle

### Scriv account

The top-right Scriv control handles app identity, project access, invitations, plan, billing portal, and sign-out. Signed out, it reads **Sign in to Scriv**. Signed in, it shows the user's name and Free/Pro badge.

### Codex on this Mac

A separate top-right control opens a compact local-engine popover with runtime status, ChatGPT account state, and Start/Stop/Connect actions.

| Action | Behavior |
| --- | --- |
| Start | Launch a dedicated Codex child process owned by Scriv and connect automatically |
| Connect | Attach to an explicitly chosen existing local endpoint; no process ownership is acquired |
| Stop | Interrupt Scriv's active turns and terminate only the child Scriv started |
| Disconnect | Detach from an externally managed server without stopping it |
| Sign in / Disconnect ChatGPT | Change AI account authorization separately from Scriv account or process state |

The normal managed path uses stdio. Existing local connections can use a documented transport supported by the pinned Codex version. The app performs the initialization handshake before treating the connection as ready. [Codex app-server](https://learn.chatgpt.com/docs/app-server)

Do not use killall, terminate a PID merely because its port matches, or assume a persisted PID proves process ownership after a restart. There is no need to invent an unsupported shutdown RPC: owned process lifecycle belongs to the native Mac host.

Starting a process is distinct from connecting, authenticating, and verifying image capability. Track each:

- Runtime: not installed, stopped, starting, running, stopping, unreachable.
- Connection: disconnected, connecting, connected, reconnecting, incompatible.
- Account: signed out, signing in, connected, reauthentication required, limit reached.
- Images: unverified, available, unavailable, temporarily failing.

In the stopped state, the control reads **Codex · Local**. Its popover is titled **Codex on this Mac** and shows ChatGPT sign-in, Start and Connect controls, and disabled Stop.

### Credentials and usage

Keep AI credentials in the user's protected local credential store/state directory. The cloud project database, Redis, peer messages, history, and analytics must never contain access tokens or Codex auth files. A connected external runtime's account is the account used for its work; do not silently switch to another person's account. [Codex authentication](https://learn.chatgpt.com/docs/auth)

The Scriv $10 fee pays for Scriv's workspace services. The connected user's eligible Codex/ChatGPT plan and usage limits govern AI work. Stopping Codex does not cancel the Scriv subscription; signing out of Scriv does not silently log the user out of other Codex clients.

### Generation lifecycle

Native Codex supports image generation and reference-image editing. This differs from the newer Sign in with ChatGPT Responses route, whose current preview limitations exclude image generation. [Native image generation](https://learn.chatgpt.com/docs/image-generation) · [Preview route limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)

For each requested generation:

1. Persist a local job and, when online, its cloud metadata, including initiating user/device, project, target item, source revision, prompt snapshot, and immutable reference versions.
2. Create a unique scoped local work directory and supply only the needed references.
3. Start a turn through the connected runtime; record its actual thread/turn IDs.
4. Stream progress into Scriv without writing every token into project history.
5. Validate the returned image artifact belongs to this job, is new, decodable, and within limits.
6. Import a new immutable asset version and publish its manifest.
7. Attach through the normal mutation service only if target versions and permissions still permit it.
8. Otherwise retain it as a candidate result for review instead of overwriting newer work.
9. Transfer via authorized P2P and upload for premium backup.

Do not hold a script-line lease for several minutes while generating. Snapshot the source and check it again on attachment. Shared changes produced by AI require the same permissions and conflict handling as human changes.

On sleep, disconnect, or process exit, use waiting/unknown/reconnecting states. Inspect the recorded turn and local artifacts before resubmitting. A lost response does not prove the request failed, and automatic retry can create duplicate usage. Thread resume does not itself guarantee an interrupted image computation continues.

Other collaborators do not gain permission to submit work under this Mac's ChatGPT identity merely because they can edit the project.

### Two implementation gates remain

**Artifact contract:** Public app-server documentation provides general item/turn events; this design does not assume a dedicated image-generation RPC or a guaranteed output-directory convention. Pin a runtime version and prove actual generation/editing, cancellation, and artifact recovery before enabling the production capability.

**Distribution eligibility:** Current documentation permits continued local/open-source app-server use while expressly excluding commercial/hosted use of that authentication route. The newer integration guidance directs paid/hosted applications to request appropriate access. The combination of a free open-source Mac client and paid Scriv services needs its eligibility resolved; localhost execution alone does not settle it. This is separate from native Codex's technical image-generation capability. [App-server auth guidance](https://learn.chatgpt.com/docs/app-server#auth-endpoints) · [Official integration guidance](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt)

Neither gate blocks designing the local runtime UI or implementing the independent collaboration model.

## 11. Discussion and annotation interface

The interface combines the main script, preview, and layers layout with:

- Top-right Scriv account and separate local Codex controls.
- A small collaborator roster and History action.
- A colored remote caret and an “Alex is editing” line badge.
- A compact bottom-right **Discussion** panel.
- **Project / This item** tabs.
- A context chip such as **Line 08 · Randy**.
- Targets for Line, Direction, Character, and Image.
- Messages, immutable image-version references, resolve/reopen, and a reply composer.

One canonical thread belongs to each item. Project chat is the same model with no item_id. Individual messages may quote words or pin an image region without creating a new chat database.

Image regions use normalized coordinates, tied to a specific asset version. Word quotes retain their source version and stable word IDs. Renaming a character or moving a line keeps the conversation. A deleted anchor becomes archived/orphaned and remains inspectable.

Message edits/deletes are versioned commands. The author can edit their message; owner moderation is explicit and recorded. Commenter permission allows discussion without text editing. A line's editing lease never prevents another authorized user from replying.

Changing the current selection does not silently discard a draft reply. Pin the open thread while composing, then let the user switch deliberately.

For now, this panel is human project discussion and annotation. AI task chat can later be a clearly separate mode; collaborators' ordinary messages should not automatically invoke a model.

## 12. Capacity targets and acceptance checks

“Hundreds live” is a requirement to validate, not a throughput claim produced by choosing Redis.

Initial load-test workload: **500 connected users in one project, up to 100 editing different items**, plus a distributed-project workload. Begin with roughly 250ms typing batches; tune toward 500ms under load without pretending uncommitted previews are saved. Proposed target: committed edits reach peers within 500ms p95 in the deployment region.

Presence fanout can dominate: 500 users sending five updates/second to every other user would create about 1.25 million recipient updates/second before coalescing or filtering. Use visible-item subscriptions, latest-value coalescing, batches, and bounded buffers. Do not create a P2P connection for every pair of users.

Measure project sequencing contention, transaction latency, replay lag, fanout bytes, active subscriptions, Redis health, object traffic, and TURN traffic before advertising a supported limit. Adding WebSocket nodes does not remove the database's hot-project sequencing limit.

### Required behavior checks before launch

| Scenario | Expected result |
| --- | --- |
| Two users claim the same line | Exactly one receives the lease |
| Old tab writes after expiry/reclaim | Rejected by session/token/fence/version checks |
| Redis restarts | Presence rebuilds; content and leases remain correct |
| Dispatcher crashes after publish | Duplicate event delivery causes no duplicate edit |
| Final notification is lost | Watermark detects lag and replay fills it |
| Response is lost after successful commit | Mutation retry returns the original result |
| Offline draft meets newer text | Draft preserved; no silent overwrite |
| Adjacent cue boundary changes | Both cue rows change atomically; total span preserved |
| Restore occurs during editing | New epoch rejects old write authority; history survives |
| Original image device sleeps | Premium serves verified hosted copy; free shows unavailable if no peer has it |
| Subscription changes mid-session | Server rechecks entitlement; owner keeps free script use |
| Generation returns after target changes | Retained as a candidate; no stale overwrite |
| Mac sleeps during generation | Reconcile before retry; avoid duplicate submission |
| Connected external Codex server | Disconnect does not terminate the server |

These are acceptance criteria for the implementation. Validation must establish each behavior before launch; this specification does not claim those checks have been run.

## 13. Greenfield build sequence

Build Scriv from the shared contracts in this specification. The Mac application and hosted services use the same versioned content schemas, stable identities, and command semantics.

Build in this order:

1. Define typed schemas for items, word anchors, timing, links, asset versions/files, and discussion records. Preserve screenplay text and authored ordering during import/export.
2. Build the Mac application shell and the script, Characters, Storyboard, preview, and layers views over that model, with local draft and asset persistence.
3. Add the local Mac Codex host with explicit process ownership, account state, and a verified artifact adapter.
4. Add Scriv identity, Postgres persistence, command validation, history, and offline draft reconciliation.
5. Add WebSockets, durable replay, presence, and fenced leases.
6. Add per-item discussions and character/image links.
7. Add authorized P2P, premium object storage, Stripe entitlement, and downgrade behavior.
8. Load-test the chosen concurrency targets and complete the runtime eligibility/artifact gates before public claims.

Every write path, including imports, MCP tools, and AI-assisted changes, uses the same authorized commands. No client snapshot or alternate integration may bypass leases, versions, project epochs, or mutation receipts. Local caches and unsubmitted drafts are not authoritative shared state.

Implement persistence, transport validation, and client schemas together. Keep the local Codex runtime and credentials separate from the hosted collaboration and billing services throughout the build.

## 14. Decisions still needing product validation

The architecture and schema above provide an implementation starting point. These choices must be settled before charging users and may require adjustments:

- Confirm owner-paid access versus per-editor billing.
- Cost and set hosted-storage, image-size, relay, and member limits.
- Finalize grace and media-recovery/deletion policy.
- Confirm how the free open-source Mac client plus paid services fits the approved OpenAI integration route.
- Verify the pinned local Codex image artifact contract and supported macOS distribution/install method.
- Validate concurrency and latency targets on actual deployment hardware.
