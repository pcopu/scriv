# Scriv Cloud API v1

This contract is shared by the native Mac app and Cloudflare Worker. JSON uses camelCase. IDs are opaque strings (native model IDs are UUIDs). Server times are integer milliseconds since Unix epoch; native image creation dates may include fractional milliseconds. Timeline values are integer milliseconds. All API errors are `{ "error": { "code": "...", "message": "...", "details": ... } }` with an appropriate HTTP status. Authentication is `Authorization: Bearer <opaque session token>`; secrets are never query parameters.

## Native sign-in

Email codes are the primary Scriv sign-in. ChatGPT login belongs solely to local Codex and remains separate.

1. Generate a random PKCE verifier and its SHA-256/base64url challenge. Keep the verifier in memory for this server and sign-in flow.
2. `POST /auth/email/request` `{email,codeChallenge}` → HTTP 202 `{challengeId,expiresAt,resendAt}` (Unix milliseconds). Email normalization trims and lowercases a conservative ASCII address; it does not remove dots or plus suffixes. The response does not reveal whether an account exists.
3. Enter the emailed six-digit code, then `POST /auth/email/verify` `{challengeId,code,codeVerifier,deviceName?}` → `{token,expiresAt,user:{id,name,email,avatarUrl}}`. The device-bound code expires after ten minutes, is single-use, and permits at most five atomic attempts. The native app stores the resulting session token in the API-origin-scoped Keychain, not in preferences or project files.
4. Resending reuses the flow's PKCE verifier. A request after the 60-second cooldown replaces the previous code for that email/challenge pair. Cancel, server changes and account/session lifecycle changes discard the native pending flow. A late response cannot sign into a different origin or account context.
5. `POST /auth/logout` revokes the current session. `GET /v1/me` returns `{user,sessionId,teams:[{id,name,role,plan,status}],projects:[...]}`. `GET /auth/sessions` returns `{currentSessionId,sessions}`; `DELETE /auth/sessions/:id` revokes one of your sessions and disconnects its live sockets.

Requests are limited to 20 per IP/ten minutes, five per normalized email/hour and 900 globally/day. Verification is limited to 30 per IP/ten minutes and 20 per email/ten minutes, in addition to each challenge's five-attempt cap. Aggregate limits use fixed windows; the resend cooldown is exact. Rate-limit keys hash IPs/addresses. Challenges store neither plaintext codes nor the random challenge ID; the code digest includes that nonpersisted ID. Identity creation, code consumption and session creation share one D1 transaction. Request and verify bodies are bounded, and provider failures are sanitized.

Cloudflare's restricted `EMAIL` sending binding sends only the fixed login template from `EMAIL_FROM`; it is not an arbitrary mail relay. Missing configuration returns 503 `auth_not_configured`; send failure returns 503 `email_unavailable`, invalidates that code and retains the cooldown. Expired, replayed, exhausted or mismatched verification returns 401 `invalid_code`. These POST routes require JSON content type (415 otherwise); a supplied browser Origin must match `PUBLIC_URL` (403 otherwise), while native requests omit Origin. Consumed challenges remain until the scheduled expiry cleanup; they are unusable immediately after consumption.

Email identities are additive and never silently link to an existing GitHub contact address. Existing GitHub users, sessions and project ownership remain unchanged. Optional legacy OAuth stays available when its provider secrets are configured: `GET /auth/github/start?codeChallenge=...&state=...` uses ASWebAuthenticationSession; `/auth/github/callback` redirects only to `scriv://auth/callback?code=<single-use code>&state=<original state>`; `POST /auth/exchange` `{code,codeVerifier,deviceName}` returns the same session shape.

## Teams and projects

- `GET /v1/teams` → `{teams}`; `POST /v1/teams` `{name}` → `{team}`.
- `GET /v1/teams/:id` → `{team,members,joinLinks}`. `PATCH /v1/teams/:id` `{name}`. Owners/admins manage membership; only owner manages billing.
- `POST /v1/teams/:id/join-links` `{role:"member"|"viewer",expiresInDays?:30}` → `{token,url,link}`. `DELETE /v1/teams/:id/join-links/:linkId` revokes. `POST /v1/join/:token` → `{team}`. Joining requires sign-in and a paid active/trialing team; links are reusable with no seat cap. Revocation does not eject existing members.
- `PATCH /v1/teams/:id/members/:userId` `{role:"admin"|"member"|"viewer"}`; `DELETE` removes a member. Owner cannot be accidentally removed.
- `POST /v1/teams/:id/billing/checkout` → `{url}`; `POST .../portal` → `{url}`. One USD $9.99/month subscription per team, quantity 1, independent of member count.
- `GET /v1/projects` → `{projects}`; `POST /v1/projects` `{id?:UUID,title,teamId?:UUID}` → `{project}`. Solo projects are free. Team projects require active subscription. `PATCH /v1/projects/:id` `{title}`; `DELETE` owner/admin archive.

## Project state and commands

- `GET /v1/projects/:id/snapshot` → `{projectId,epoch,headSeq,timingVersion,items:[{id,kind,version,data,deleted:false}],deletedItems:[{id,kind,version,data:{},deleted:true}],canImport,threads:[...],leases:[...]}`. `deletedItems` exposes only tombstone identity/version metadata, not deleted content. Retain it with the client's version map so undo/reinsertion after reconnect can obtain a lease and use the correct expected version. `canImport` is true only if no content item has ever been stored; discussion-only history does not prevent initial import, but restore-to-empty does. Older responses may omit these additive fields.
- `GET /v1/projects/:id/events?after=0&limit=100` → `{events,headSeq,epoch,timingVersion,hasMore}`. Events are `{seq,epoch,commandId,actorId,kind,at,changes:[{id,before,after}],data}`. History is immutable. `GET .../history` aliases events. Pages contain at most the requested count and approximately 512 KiB of event JSON; honor `hasMore` rather than assuming a full count. An individual event exceeding 256 KiB is represented by `changes:[]` and `data.snapshotRequired:true`; its complete changes remain in durable storage.
- Item kinds: `scene`, `entry`, `character`, `image`, `cue`. `data` is the native model's JSON object. Stable `id` appears both on item and data. Individual data <=64KiB; direct commands <=512KiB and <=100 operations. Larger indivisible edits use the bounded staged protocol below, not separate commits.
- `POST .../leases` `{itemId,sessionId}` → `{itemId,sessionId,token,fence,expiresAt,epoch,userId,name}`. Existing items require an exclusive 30-second lease. Renew every 10 seconds using `PUT .../leases` `{itemId,sessionId,token,fence,epoch}`. Release `DELETE .../leases` with same body. Leases conflict with `423` and owner details. New items can be created without a lease; replacing/deleting existing items requires it, including same-user other windows.
- `POST .../commands` `{commandId,sessionId,epoch,expectedTimingVersion,label,operations:[{op:"put"|"delete",id,kind?,data?,expectedVersion,lease?:{token,fence}}]}` → `{commandId,seq,epoch,timingVersion,items:[changed items]}`. Create uses expectedVersion 0. A batch is atomic and idempotent. Existing version mismatch returns409; stale epoch409; expired/missing lease423. Same commandId with another payload is409. Replays return original receipt before checking expired leases, but after current access authorization.
- `POST .../restore` `{commandId,sessionId,epoch,seq}` → receipt. Owner/admin only. Reconstructs item state at sequence, creates a new history event, increments epoch, invalidates all leases. Does not restore users, memberships, billing or discussion messages.

### Larger atomic structural edits

One scene resize, reorder or deletion can change more than 100 items. The native client uses immutable upload parts followed by **one** SQLite commit; parts never modify project items, timing, leases or history by themselves.

1. `POST .../batches` with `{commandId,sessionId,epoch,expectedTimingVersion,label,operationCount,parts:[{hash,bytes,count}]}`. Each SHA-256 is over the exact UTF-8 JSON string containing that part's operation array. The manifest and those exact strings are durably saved in the account/server-scoped client outbox before uploading.
2. `PUT .../batches/:commandId/parts/:index` with `{content:"<operation-array JSON>"}`. Repeated identical parts are harmless; changed bytes, wrong count/hash, another account/authentication session or unavailable write permission are rejected. No item is applied yet.
3. `POST .../batches/:commandId/commit` with the original manifest. Missing parts fail without changes. All operations then pass existing kind, item version, epoch, timing, graph and immutable-image validation together, in one synchronous transaction. Any failure rolls back every item, temporary lease and journal write.

Limits are explicit: 10,000 operations per edit; 100 operations and 384 KiB UTF-8 per part; at most 1,024 parts; 16 MiB total part bytes and a separate 16 MiB combined before/after history budget. Items retain their 64 KiB limit. A room reserves at most 64 MiB across 64 staged edits, with at most two per account. Abandoned uploads expire after 24 hours through the room alarm. Limits reject the complete edit rather than accepting a prefix; the Mac retains its local draft.

Explicit UI-owned lease proofs keep their original token/fence checks. For other affected existing items, finalization atomically claims only unlocked items (or the exact same account/auth-session/editor session's current lease). It cannot take another editor's live lease. Newly claimed structural leases expire inside the same transaction; existing UI-owned leases remain held. Consequently an edit with thousands of dependent cues does not require thousands of network lease requests or expose half-resized geometry while waiting.

Successful finalization creates one command receipt, one journal sequence and at most one timing-version increment. Its bounded receipt/event uses `items:[]`/`changes:[]` with `snapshotRequired:true`; clients replay and load the canonical snapshot before acknowledging the local save. All before/after rows remain available to history preview/restore. Retrying prepare or finalize with the same manifest returns the original receipt even after eviction, lost response, lease expiry or a subsequent write-permission downgrade, provided current read authorization still permits access. Different content under an accepted command ID is rejected.

After a known transactional lease/version/epoch/timing, reference/geometry or budget rejection, the Mac archives the exact immutable request as `.rejected`, preserving the local project draft so reconciliation can construct a corrected command instead of retrying an impossible payload forever. Only explicit status/code pairs known to follow the receipt lookup qualify. Ambiguous parsing, authentication/permission, transport, capacity, unknown and `command_reused` failures retain the pending identity. Authentication-session changes similarly retire an uncommitted stage, never transfer its lease authority. Accepted receipts remain recoverable by the same currently authorized account after signing in again. Staging expiry is safe: replaying the saved immutable manifest and parts reconstructs the uncommitted upload.

Native snapshot installation is monotonic against both applied history and accepted command-receipt progress. A late older snapshot cannot replace newer canonical item state or restore an older epoch; it leaves the replay cursor unchanged and catch-up fetches newer state. Receipt progress never skips unapplied history events.

### Image prompt storage and paid media boundary

Scripts, authored timing, characters and image metadata use the project command/snapshot/history protocol for both free personal and paid team projects. Only image binary upload to R2 requires the existing active paid-Team entitlement; metadata never grants that entitlement.

Image `prompt` is the manual visual direction or import description. Optional nullable `generationPrompt` is the exact captured app-submitted generation text, including the assembled source/profile brief and generic wrapper. It is at most 30,000 UTF-16 units and must fit within the existing 64 KiB encoded item limit; no truncation occurs. It is immutable for an image version alongside its bytes/lineage identity. A changed prompt belongs to a new image version. Omitted/null means not captured, including historical/imported images; ordinary updates cannot manufacture a prompt for such a version.

This field is plain text, not a serialized local job. The native projection never injects package/runtime/reference paths, portrait bytes, credentials or Codex identifiers. Authored text itself is preserved, not silently redacted. The generation-job endpoints retain their narrow progress/ownership metadata allowlist and continue rejecting prompt/private-context payloads. Image prompt storage does not require that a binary has been uploaded or is still available.

### Authored-field compatibility

Entry `characterLinks` is optional/missing/null only for legacy unbootstrapped text. A present array contains unique, ordered nonoverlapping UTF-16 `{id,characterId?,location,length,text,isConfirmed}` ranges matching the exact authored text; missing/null identity is an explicitly confirmed unlink. Linked IDs must resolve to live characters. Character deletion must unlink the annotations in the same edit.

Cues optionally pair `startAnchor:{entryId,offsetMs}` with positive `authoredDurationMs`. The source belongs to the same scene; offsets remain inside owned time, with offset zero also valid for a zero-owned direction. Resolved start/end must equal the source point and the authored duration clamped to the scene tail. A zero-owned direction at that exact tail may retain dormant `startMs == endMs == sceneDuration` with positive authored duration; adding later content can reveal it again. Zero authored duration or a zero-length projection in the middle remains invalid. Fully anchored cues may overlap; overlap involving legacy unanchored cues is rejected until migrated together. Words optionally carry `timingSource:"authored"`.

Ordinary puts cannot silently strip an established character-link array, cue anchor pair, or authored marker from a surviving word ID (`schema_upgrade_required`). Empty link arrays, explicit unlink choices and intentional word deletion remain supported. Explicit historical restore can restore older legacy state; ordinary old-client writes must update/reload rather than erase authored identity or timing.

### Read-only history preview

`GET .../snapshot?seq=<0..headSeq>&after=<itemId>&limit=200` reconstructs the exact item state at a journal sequence using the same reducer as restore, including import/restore/large events whose public changes are truncated. This never mutates current items, leases, discussions, epoch or journal. Optional `epoch` must match the historical event epoch (epoch 1 at sequence 0). Unauthorized readers are rejected before projection; future/negative/non-integer sequences and limits above 200 are rejected.

The response has the snapshot fields plus `{hasMore,nextCursor,historyEvent:{seq,epoch,actorId,kind,at}|null}`. `headSeq` is the requested sequence, and epoch/timingVersion are historical. Pages are ordered by item ID across live items and minimal tombstones, capped at 200 items and approximately 512 KiB of item payload. Fetch every page with the same sequence before displaying a complete preview. `canImport:false`, `threads:[]` and `leases:[]` are intentional: this is item-only read-only history, not a reconnect snapshot and not permission to overwrite current versions. Historical media metadata does not bypass asset authorization or guarantee deleted hosted bytes still exist.

## Item discussions

- `GET .../threads?itemId=<id>` (omit for project discussion) → `{threads}`. Image versions resolve to one canonical conversation for their lineage.
- `GET .../threads?scope=all&after=<threadId>&limit=100` → `{threads,hasMore,nextCursor}`. Authorized, ID-ordered browsing includes resolved, deleted-item and legacy image-version conversations; limit 1–200. Do not combine `scope=all` with `itemId`.
- `POST .../threads` `{itemId?:null,anchor?:{wordIds?,imageVersionId?,...}}` → `{thread}`. One canonical thread per item/image lineage plus one project thread.
- `GET .../threads/:threadId/messages?after=<timestamp>&afterId=<id>` → `{messages,hasMore,nextCursor:{at,id}|null}`. Pages contain up to 500 messages, ordered by timestamp and ID. Send both returned cursor parts to avoid same-time gaps.
- `POST .../threads/:threadId/messages` `{id,body,replyToId?:null,attachments?:[{itemId,imageVersionId?}]}` → `{message}`. Client UUID makes send idempotent; maximum body8000 characters. No line edit lease required.
- `PATCH .../threads/:threadId` `{resolved:true|false}` → `{thread}`.

Image discussions follow `previousVersionId` to a stable root, including tombstoned predecessors, so regeneration does not split the conversation. A newly created image conversation is keyed by root ID; its initial `anchor.imageVersionId` defaults to the selected live revision. Missing/cyclic/non-decreasing lineages fail closed. Existing root conversations win; if an older release created only revision-specific threads, the earliest family conversation is canonical. Other legacy threads and messages are never deleted or merged and remain addressable by thread ID and `scope=all`. The returned canonical `thread.itemId` can differ from the selected revision. Read-only discovery does not mutate historical anchors or advance the journal.

Project mentions are additive and stay in-app: `GET .../members?after=<userId>&limit=100&q=<name>` returns `{members:[{id,name,role}],hasMore,nextCursor}` to current project readers. `limit` is 1–200; `q` is a literal, case-insensitive display-name substring (maximum 100 characters). Member IDs are ordered for pagination. Personal projects expose only their owner; team projects expose the authoritative team owner and current members, with no email or session data.

Message POST accepts optional `mentionedUserIds:[string]` (maximum 20 unique current project-member IDs). Responses and durable message events include `mentionedUserIds`; old persisted messages migrate to `[]`, and older journal events may omit the field. Lists are canonicalized by ID for idempotency; changing recipients on a reused message ID is rejected. A previously accepted retry still returns its original recipients after a recipient leaves, while fresh sends cannot mention removed/nonmember users. Paid viewers retain their existing discussion/mention permissions. Mentions do not send email or create external notifications.

Discussion creation, new messages and resolution changes commit in the same
ordered journal as content: `discussion.thread-created` and
`discussion.thread-updated` carry `data.thread`; `discussion.message-created`
carries `data.message`. Each has `changes:[]`, `data.label` and the unchanged
`data.timingVersion`. Apply these payloads during both live delivery and replay.
The existing immediate `thread`/`message` socket notifications remain supported;
deduplicate messages by ID. Repeated identical message sends and resolution of
an already-resolved thread do not append duplicate history. Earlier discussion
data remains readable when upgrading an existing room; historical ordering is
not fabricated for messages accepted before this journal support.

Returning an existing canonical thread is a read and remains available during
subscription grace. Identical accepted message/restore retries return the
original result after current read authorization, even if the actor has since
lost write permission. New attachments must reference live items; previously
accepted attachments remain readable when an item is deleted. Initial word
anchors must reference distinct words in the annotated entry; image anchors
must reference an available image version. A canonical thread retains its
original anchor instead of being moved to another selection on repeated opens.

New message timestamps advance monotonically within a thread, including when
the wall clock repeats or regresses. Continue sending both cursor fields when
paging. A snapshot-required event advances the content checkpoint past other
events, so clients must also reload the active discussion's thread and messages
after snapshot replacement/reconnection; a content snapshot has thread metadata,
not message bodies. A history restore changes only content, never discussion.

## Live connection and peer media signaling

Open `GET /v1/projects/:id/socket` with bearer header and `Upgrade:websocket`.
Requires an active team subscription; free owners use HTTP sync and history.
Client JSON can use text frames or UTF-8 binary frames (including native
`URLSessionWebSocketTask.Message.data`). The 64 KiB limit measures encoded bytes;
invalid UTF-8/JSON returns a structured error. Invalid presence or an unavailable
signal recipient does not close an otherwise authorized collaboration socket.
Server first sends `{type:"hello",projectId,epoch,headSeq,timingVersion,connectionId,deviceId}`.
The server-issued `deviceId` identifies the authenticated device session; it is
separate from the native editor-window `sessionId` used for leases.

Send `{type:"resume",after:seq}` and receive
`{type:"events",events,headSeq,epoch,timingVersion,hasMore}`; repeat until caught up.
Live events use the same `events` shape. Notifications are batched for up to
50 milliseconds, 64 events or 256 KiB, with immediate durable HTTP receipts.
An individual oversized notification carries `data.snapshotRequired:true` and
empty `changes`; fetch a snapshot. Clients also accept `{type:"event",event}`.
A watermark flushes any pending notifications first. Periodic client
`{type:"ping",after:seq}` returns `{type:"watermark",headSeq,epoch,timingVersion}`;
repair gaps using HTTP/events replay. Reconnect with exponential jitter and resume.

Other server messages are `{type:"leases",leases}`, `{type:"presence",peers}`,
`{type:"thread",thread}`, `{type:"message",message}`, and authenticated peer signals.
Public lease lists omit secret tokens. Send presence as
`{type:"presence",itemId?,selection?:{start,end},cursor?:{x,y}}` at most 5 Hz.
Names and user/device IDs come from the authenticated session. Presence expires
after 30 seconds. Full presence broadcasts are coalesced to 5 Hz for rooms with
up to 100 connections, and 1 Hz for larger rooms to control all-to-all fanout.
Heartbeat replies also refresh presence. Item persistence and event delivery use
their separate path and are not slowed to the presence rate.

Sockets are reauthorized for session, membership and billing on every incoming
message. Membership removal, session revocation and subscription changes also
proactively revalidate and close affected sockets. Max 1,000 simultaneous
connections per project; membership has no seat cap. The limit protects a live
room and does not constrain how many people may join a team.
Access refresh also invalidates leases belonging to removed members, editors
downgraded to viewers or revoked device sessions, even without a live socket.
Lease rows/fences survive invalidation; the next claim receives a higher fence.
Access refresh also fences HTTP/socket operations that authorized before the
change but are still awaiting a request body, digest or peer lookup. These return
409 `access_changed` before a mutation or cached receipt is returned. A slow
upload cannot create a new unleased item/message after removal has completed;
retrying must pass fresh authorization. This fence can also reject an otherwise
authorized request racing with a different member's access change.

Peer signaling is `POST .../signals` `{toDeviceId,type:"offer"|"answer"|"ice"|"asset-request"|"asset-available",payload}` and the same JSON with `type:"signal",signalType:...` over socket. Receiver gets authenticated sender ID. Signaling contains no media bytes; local-only assets remain local until peer transfer or premium upload. Free solo's other authenticated devices may use HTTP `GET .../signals?deviceId=...&after=...` / POST to exchange signals. Signal messages expire after120s. Recipient must currently have access.

### Deterministic WebRTC connection setup

For each pair, the device with the lexicographically lower server-issued device
ID is the sole initial SDP offerer. The other device answers. This role is
independent of which device requests or supplies an image. Both endpoints use the
fixed negotiated `scriv-media` data channel with ID `0`; simultaneous image
requests share that connection instead of generating competing initial offers.

If the higher-ID device needs a connection, it sends the following directed
signal to the lower-ID device:

```json
{
  "toDeviceId": "<lower device ID>",
  "type": "asset-request",
  "payload": {
    "action": "connect",
    "requestId": "<fresh UUID for this connection attempt>"
  }
}
```

The connection request starts transport negotiation; it does not request an
image or grant permission to serve one. The lower-ID device creates the offer
even when it has no pending image request of its own. SDP `offer`/`answer` and
`ice` messages then use the existing signaling route. The bridge uses a fresh
UUID `requestId` as the connection-attempt nonce. Repeated requests with the
same nonce reuse the active attempt and cannot create another offer. A different
nonce replaces the earlier connection request's transport and fails its pending
transfers, so a lost offer or answer cannot leave the lower-ID peer waiting on
an obsolete handshake. A fresh nonce also prevents native signal deduplication
from suppressing a legitimate reconnect.

An image request has a 60-second deadline. An unanswered handshake or incomplete
transfer retires the peer, closes its channel/connection and fails all pending
requests on that peer. The next retry creates fresh transport state and a new
connection nonce where needed. An ordinary `unavailable` image response fails
only that image request and keeps the healthy channel open. SDP and ICE
application is serialized per peer; candidates that arrive before their matching
remote description remain in a bounded queue for later application.

`asset-request` also carries discovery actions: `query` and `available` include
the image `hash` and discovery `requestId`. Dispatch `action:"connect"` to the
transport before applying those hash-based discovery checks. Actual image
requests and bytes travel through the opened data channel and retain project
hash authorization, size limits and digest verification.

The cloud relays the bounded JSON control payload without interpreting these
actions or choosing the offerer. It authenticates the sender, derives sender
IDs from the session, verifies the recipient's unexpired/unrevoked session and
checks both users' current project access. Same-account device exchange remains
available for free personal projects. Exchange between different accounts still
requires an active team subscription for both project accesses; the connection
control action introduces no bypass. Each device can read only its own signal
inbox, and the existing signal expiry and request limits also apply.

## Images

`PUT /v1/projects/:id/assets/:sha256` with raw PNG/JPEG/WebP bytes, Content-Type, and `X-Scriv-Asset-Id` uploads immutable content-addressed media. Premium only, maximum25MiB/file, 10GiB/team default quota. SHA-256 is verified against bytes. `GET .../assets/:sha256` requires membership/ownership; `HEAD` returns the same metadata without bytes. No public bucket or permanent public links. `DELETE` removes a hosted replica (owner/admin). Metadata/tags/timed cues remain project items; uploading bytes does not mutate script. Download/export works during configured downgrade grace and is never made public.

## Health and configuration

`GET /health` returns public service status without secrets. `GET /v1/config` returns `{teamPrice:{currency:"usd",amount:999,interval:"month"},maxAssetBytes,...}`. Production disables development authentication. Setup instructions and deploy variables are in `cloud/README.md`.

## Timing, atomic import and peer discovery

Snapshots, hello/watermark/event pages and command receipts expose `timingVersion`.
Events also include `data.timingVersion`. Send `expectedTimingVersion` on every
command. Entry creation/deletion, duration/order/scene/kind/coverage changes and
cue boundary changes require it to match; otherwise409 `timing_conflict`.
Ordinary text/word changes within an unchanged duration remain independent under
the entry lease, and advance the timing counter to invalidate pending cut edits.
A restore advances both epoch and timing version.

`POST .../import` is an atomic bootstrap for a new empty project:
`{commandId,sessionId,epoch,expectedTimingVersion:0,label?,items:[{id,kind,data}]}`.
It accepts up to10,000 items/16MiB and validates references after all inserts,
including character/portrait cycles. It returns a receipt with `items:[]` and
`snapshotRequired:true`; fetch a new snapshot for item versions. Retrying the exact
import returns its receipt. A different import into a nonempty project is409.

`GET .../devices` returns `{currentDeviceId,devices:[{id,deviceName,userId,name,
createdAt,expiresAt}],onlineStatus:"unknown"}`. Device IDs are server session IDs,
not client-generated editor-window lease IDs. An unexpired credential does not
prove the device is online. Free owners see their own authorized devices; paid
members see team devices. `GET .../ice-servers` returns short-lived WebRTC ICE
servers, `relayAvailable` and `expiresAt`. With TURN unconfigured it returns STUN
only and cannot guarantee traversal of restrictive NATs.

Image `createdAt` accepts finite nonnegative milliseconds, including a fractional
millisecond from Swift's Date encoder. Server event and session times remain
integer milliseconds.

Word IDs are unique across all live entries, including atomic imports and
multi-entry edits. A batch may move a word identity between entries if the final
state is unique. Reinstating a deleted entry or cue is a geometry change and
requires the current timing version even when its payload is unchanged.
An existing image item's version, filename, digest, MIME type, byte count,
creation time and predecessor are immutable; regeneration creates a new item.
Tags and prompt metadata remain editable under its lease. Character tags are
distinct; a predecessor must be an available image with a strictly lower version,
which rules out self-links and version cycles.

## Retrying a saved command

Persist the exact command payload and ID before submitting. Replay that exact
payload after a lost response. Receipt lookup precedes epoch, timing, item version
and lease checks, so a previously committed command returns its original receipt.
Do not silently change a payload under the same ID. A structured rejection with
`lease_required`, `item_locked`, `stale_epoch`, `version_conflict` or
`timing_conflict` means that exact payload was not committed; archive the rejected
outbox entry, fetch current state, reconcile the local draft against its prior
checkpoint, acquire fresh leases and submit a new command ID. `command_reused`
means the ID already identifies a different payload and must be surfaced as an
error instead of automatically retrying a changed body.

`access_changed` differs: the current attempt was fenced before mutation **or
receipt lookup**, so an earlier attempt with the same ID may already have
committed. Keep its original outbox payload/ID and retry it unchanged after
fresh authorization. Do not discard it or infer that a new command ID is safe
from this error alone.
