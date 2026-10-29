# Scriv Cloud API v1

This contract is shared by the native Mac app and Cloudflare Worker. JSON uses camelCase. IDs are opaque strings (native model IDs are UUIDs). Server times are integer milliseconds since Unix epoch; native image creation dates may include fractional milliseconds. Timeline values are integer milliseconds. All API errors are `{ "error": { "code": "...", "message": "...", "details": ... } }` with an appropriate HTTP status. Authentication is `Authorization: Bearer <opaque session token>`; secrets are never query parameters.

## Native sign-in

1. Generate a random PKCE verifier and SHA-256/base64url challenge plus independent client `state`.
2. Open `GET /auth/github/start?codeChallenge=...&state=...` using ASWebAuthenticationSession. Worker callback is `/auth/github/callback`; final redirect is **exactly** `scriv://auth/callback?code=<single-use code>&state=<original state>`.
3. `POST /auth/exchange` `{code,codeVerifier,deviceName}` → `{token,expiresAt,user:{id,name,email,avatarUrl}}`. Store token in Keychain.
4. `POST /auth/logout` revokes current session. `GET /v1/me` returns `{user,sessionId,teams:[{id,name,role,plan,status}],projects:[...]}`. `GET /auth/sessions` returns `{currentSessionId,sessions}`; `DELETE /auth/sessions/:id` revokes one of your sessions and disconnects its live sockets.

GitHub OAuth is the initial Scriv identity provider. ChatGPT login belongs solely to local Codex and is separate.

## Teams and projects

- `GET /v1/teams` → `{teams}`; `POST /v1/teams` `{name}` → `{team}`.
- `GET /v1/teams/:id` → `{team,members,joinLinks}`. `PATCH /v1/teams/:id` `{name}`. Owners/admins manage membership; only owner manages billing.
- `POST /v1/teams/:id/join-links` `{role:"member"|"viewer",expiresInDays?:30}` → `{token,url,link}`. `DELETE /v1/teams/:id/join-links/:linkId` revokes. `POST /v1/join/:token` → `{team}`. Joining requires sign-in and a paid active/trialing team; links are reusable with no seat cap. Revocation does not eject existing members.
- `PATCH /v1/teams/:id/members/:userId` `{role:"admin"|"member"|"viewer"}`; `DELETE` removes a member. Owner cannot be accidentally removed.
- `POST /v1/teams/:id/billing/checkout` → `{url}`; `POST .../portal` → `{url}`. One USD $9.99/month subscription per team, quantity 1, independent of member count.
- `GET /v1/projects` → `{projects}`; `POST /v1/projects` `{id?:UUID,title,teamId?:UUID}` → `{project}`. Solo projects are free. Team projects require active subscription. `PATCH /v1/projects/:id` `{title}`; `DELETE` owner/admin archive.

## Project state and commands

- `GET /v1/projects/:id/snapshot` → `{projectId,epoch,headSeq,timingVersion,items:[{id,kind,version,data,deleted:false}],threads:[...],leases:[...]}`.
- `GET /v1/projects/:id/events?after=0&limit=100` → `{events,headSeq,epoch,timingVersion,hasMore}`. Events are `{seq,epoch,commandId,actorId,kind,at,changes:[{id,before,after}],data}`. History is immutable. `GET .../history` aliases events.
- Item kinds: `scene`, `entry`, `character`, `image`, `cue`. `data` is the native model's JSON object. Stable `id` appears both on item and data. Individual data <=64KiB; commands <=512KiB and <=100 operations.
- `POST .../leases` `{itemId,sessionId}` → `{itemId,sessionId,token,fence,expiresAt,epoch,userId,name}`. Existing items require an exclusive 30-second lease. Renew every 10 seconds using `PUT .../leases` `{itemId,sessionId,token,fence,epoch}`. Release `DELETE .../leases` with same body. Leases conflict with `423` and owner details. New items can be created without a lease; replacing/deleting existing items requires it, including same-user other windows.
- `POST .../commands` `{commandId,sessionId,epoch,expectedTimingVersion,label,operations:[{op:"put"|"delete",id,kind?,data?,expectedVersion,lease?:{token,fence}}]}` → `{commandId,seq,epoch,timingVersion,items:[changed items]}`. Create uses expectedVersion 0. A batch is atomic and idempotent. Existing version mismatch returns409; stale epoch409; expired/missing lease423. Same commandId with another payload is409. Replays return original receipt before checking expired leases, but after current access authorization.
- `POST .../restore` `{commandId,sessionId,epoch,seq}` → receipt. Owner/admin only. Reconstructs item state at sequence, creates a new history event, increments epoch, invalidates all leases. Does not restore users, memberships, billing or discussion messages.

## Item discussions

- `GET .../threads?itemId=<id>` (omit for project discussion) → `{threads}`.
- `POST .../threads` `{itemId?:null,anchor?:{wordIds?,imageVersionId?,...}}` → `{thread}`. One canonical thread per item plus one project thread.
- `GET .../threads/:threadId/messages?after=<timestamp>&afterId=<id>` → `{messages,hasMore,nextCursor:{at,id}|null}`. Pages contain up to 500 messages, ordered by timestamp and ID. Send both returned cursor parts to avoid same-time gaps.
- `POST .../threads/:threadId/messages` `{id,body,replyToId?:null,attachments?:[{itemId,imageVersionId?}]}` → `{message}`. Client UUID makes send idempotent; maximum body8000 characters. No line edit lease required.
- `PATCH .../threads/:threadId` `{resolved:true|false}` → `{thread}`.

## Live connection and peer media signaling

Open `GET /v1/projects/:id/socket` with bearer header and `Upgrade:websocket`.
Requires an active team subscription; free owners use HTTP sync and history.
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
    "requestId": "<unique connection-attempt ID>"
  }
}
```

The connection request starts transport negotiation; it does not request an
image or grant permission to serve one. The lower-ID device creates the offer
even when it has no pending image request of its own. SDP `offer`/`answer` and
`ice` messages then use the existing signaling route. Use a fresh `requestId`
when rebuilding a closed connection so native signal deduplication does not
discard a later legitimate attempt. Duplicate requests for the same attempt
must not create competing offers.

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
