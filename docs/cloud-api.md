# Scriv Cloud API v1

This contract is shared by the native Mac app and Cloudflare Worker. JSON uses camelCase. IDs are opaque UUID strings. Times are integer milliseconds since Unix epoch; timeline values are integer milliseconds. All API errors are `{ "error": { "code": "...", "message": "...", "details": ... } }` with an appropriate HTTP status. Authentication is `Authorization: Bearer <opaque session token>`; secrets are never query parameters.

## Native sign-in

1. Generate a random PKCE verifier and SHA-256/base64url challenge plus independent client `state`.
2. Open `GET /auth/github/start?codeChallenge=...&state=...` using ASWebAuthenticationSession. Worker callback is `/auth/github/callback`; final redirect is **exactly** `scriv://auth/callback?code=<single-use code>&state=<original state>`.
3. `POST /auth/exchange` `{code,codeVerifier,deviceName}` → `{token,expiresAt,user:{id,name,email,avatarUrl}}`. Store token in Keychain.
4. `POST /auth/logout` revokes current session. `GET /v1/me` returns `{user,teams:[{id,name,role,plan,status}],projects:[...]}`.

GitHub OAuth is the initial Scriv identity provider. ChatGPT login belongs solely to local Codex and is separate.

## Teams and projects

- `GET /v1/teams` → `{teams}`; `POST /v1/teams` `{name}` → `{team}`.
- `GET /v1/teams/:id` → `{team,members,joinLinks}`. `PATCH /v1/teams/:id` `{name}`. Owners/admins manage membership; only owner manages billing.
- `POST /v1/teams/:id/join-links` `{role:"member"|"viewer",expiresInDays?:30}` → `{token,url,link}`. `DELETE /v1/teams/:id/join-links/:linkId` revokes. `POST /v1/join/:token` → `{team}`. Joining requires sign-in and a paid active/trialing team; links are reusable with no seat cap. Revocation does not eject existing members.
- `PATCH /v1/teams/:id/members/:userId` `{role:"admin"|"member"|"viewer"}`; `DELETE` removes a member. Owner cannot be accidentally removed.
- `POST /v1/teams/:id/billing/checkout` → `{url}`; `POST .../portal` → `{url}`. One USD $9.99/month subscription per team, quantity 1, independent of member count.
- `GET /v1/projects` → `{projects}`; `POST /v1/projects` `{id?:UUID,title,teamId?:UUID}` → `{project}`. Solo projects are free. Team projects require active subscription. `PATCH /v1/projects/:id` `{title}`; `DELETE` owner/admin archive.

## Project state and commands

- `GET /v1/projects/:id/snapshot` → `{projectId,epoch,headSeq,items:[{id,kind,version,data,deleted:false}],threads:[...]}`.
- `GET /v1/projects/:id/events?after=0&limit=100` → `{events,headSeq,hasMore}`. Events are `{seq,epoch,commandId,actorId,kind,at,changes:[{id,before,after}],data}`. History is immutable. `GET .../history` aliases events.
- Item kinds: `scene`, `entry`, `character`, `image`, `cue`. `data` is the native model's JSON object. Stable `id` appears both on item and data. Individual data <=64KiB; commands <=512KiB and <=100 operations.
- `POST .../leases` `{itemId,sessionId}` → `{itemId,sessionId,token,fence,expiresAt,epoch,userId,name}`. Existing items require an exclusive 30-second lease. Renew every 10 seconds using `PUT .../leases` `{itemId,sessionId,token,fence,epoch}`. Release `DELETE .../leases` with same body. Leases conflict with `423` and owner details. New items can be created without a lease; replacing/deleting existing items requires it, including same-user other windows.
- `POST .../commands` `{commandId,sessionId,epoch,label,operations:[{op:"put"|"delete",id,kind?,data?,expectedVersion,lease?:{token,fence}}]}` → `{commandId,seq,epoch,items:[changed items]}`. Create uses expectedVersion 0. A batch is atomic and idempotent. Existing version mismatch returns409; stale epoch409; expired/missing lease423. Same commandId with another payload is409. Replays return original receipt before checking expired leases, but after current access authorization.
- `POST .../restore` `{commandId,sessionId,epoch,seq}` → receipt. Owner/admin only. Reconstructs item state at sequence, creates a new history event, increments epoch, invalidates all leases. Does not restore users, memberships, billing or discussion messages.

## Item discussions

- `GET .../threads?itemId=<id>` (omit for project discussion) → `{threads}`.
- `POST .../threads` `{itemId?:null,anchor?:{wordIds?,imageVersionId?,...}}` → `{thread}`. One canonical thread per item plus one project thread.
- `GET .../threads/:threadId/messages?after=<timestamp>` → `{messages}`.
- `POST .../threads/:threadId/messages` `{id,body,replyToId?:null,attachments?:[{itemId,imageVersionId?}]}` → `{message}`. Client UUID makes send idempotent; maximum body8000 characters. No line edit lease required.
- `PATCH .../threads/:threadId` `{resolved:true|false}` → `{thread}`.

## Live connection and peer media signaling

Open `GET /v1/projects/:id/socket` with bearer header and `Upgrade:websocket`. Requires active team subscription; free owners use HTTP sync and history. Server first sends `{type:"hello",projectId,epoch,headSeq,connectionId}`. Native client sends `{type:"resume",after:seq}` and receives `{type:"events",events,headSeq,hasMore}`; repeat until caught up. Server sends `{type:"event",event}` for each accepted mutation, `{type:"leases",leases}`, `{type:"presence",peers}`, `{type:"thread",thread}`, `{type:"message",message}`. Periodic client `{type:"ping",after:seq}` returns `{type:"watermark",headSeq,epoch}`; gaps use HTTP/events replay. Presence is `{type:"presence",itemId?,selection?:{start,end},cursor?:{x,y},name?}` max5Hz. User identity/name are server-authoritative. Presence expires after30s; active sockets are reauthorized for membership and billing at every message. Session revocation closes on next message. Reconnect with exponential jitter and resume.

Peer signaling is `POST .../signals` `{toDeviceId,type:"offer"|"answer"|"ice"|"asset-request",payload}` and the same JSON with `type:"signal",signalType:...` over socket. Receiver gets authenticated sender ID. Signaling contains no media bytes; local-only assets remain local until peer transfer or premium upload. Free solo's other authenticated devices may use HTTP `GET .../signals?deviceId=...&after=...` / POST to exchange signals. Signal messages expire after120s. Recipient must currently have access.

## Images

`PUT /v1/projects/:id/assets/:sha256` with raw PNG/JPEG/WebP bytes, Content-Type, and `X-Scriv-Asset-Id` uploads immutable content-addressed media. Premium only, maximum25MiB/file, 10GiB/team default quota. SHA-256 is verified against bytes. `GET .../assets/:sha256` requires membership/ownership; no public bucket or permanent public links. `DELETE` removes a hosted replica (owner/admin). Metadata/tags/timed cues remain project items; uploading bytes does not mutate script. Download/export works during configured downgrade grace and is never made public.

## Health and configuration

`GET /health` returns public service status without secrets. `GET /v1/config` returns `{teamPrice:{currency:"usd",amount:999,interval:"month"},maxAssetBytes,...}`. Production disables development authentication. Setup instructions and deploy variables are in `cloud/README.md`.
