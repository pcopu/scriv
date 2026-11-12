# Private peer signaling and service validation

This is a black-box **local Worker service journey**, entered through the Scriv CLI. It is not Catalyst/native acceptance, provider login, a real WebRTC connection, image transfer, or measured source-line coverage.

Run using an explicitly reviewed installed Tracer CLI and its matching complete scenario runtime:

```sh
SCRIV_TRACER_CLI=/absolute/trusted/tracer/bin/tracer.mjs \
SCRIV_TRACER_RUNTIME=/absolute/trusted/tracer/src/scenario-runtime.mjs \
TRACER_NO_UPDATE=1 node scripts/tracer-cli.mjs app -- test services peer-signaling
```

The harness verifies five reachable runtime module hashes before import. Those hashes identify the reviewed Tracer release associated with published commit `8e12583bb8da60f9325a7cee5d1050b3b33aa679`. It never installs or downloads dependencies.

## Isolation and lifetime

The existing service-journey process model is reused: a detached, owned child process group; private temporary HOME/state/cache directories; no inherited credentials, proxy configuration or NODE_OPTIONS; denied unexpected outbound requests; telemetry disabled; three original D1 migrations; synthetic identities and hashed session fixtures; an empty isolated R2 bucket; and unconditional owned-group and temporary-state cleanup. The actual production entrypoint is bundled and served on a random loopback port by the existing trusted Miniflare dependencies. The WebSocket client connects to that real listener, never directly to a Durable Object or exported handler.

The deadline is **150 seconds**, rather than the older journeys' 90 seconds, because the production signal TTL is 120 seconds. The journey observes the real server `at` values, performs useful content validation during the interval, then waits beyond the latest stored signal deadline. It does not alter the clock, patch TTLs, mutate the signal table, reset quotas, or add production test controls.

## Declared contract

The `peer-signaling-steps.json` catalog declares 43 ordered steps, 85 named actions, and 43 assertion callbacks.

- Connect three authenticated live devices in a synthetic paid team. A sends an offer to B using forged sender fields. Only B receives it; persisted and live sender identities come from authentication. C's own inbox and socket stay empty, and C cannot read B's inbox by naming its device ID.
- B replies using a real binary JSON WebSocket frame. A receives the exact authenticated device/user identity and answer payload in both live and durable envelopes. B and C watermark barriers precede exact checks that B retains only its original offer and C receives no signals.
- Accept an exact 50,000-byte UTF-8 payload and reject 50,001 bytes. Check invalid type, nonobject payload, malformed recipient, expired recipient, outside-project recipient, and a 65,537-byte outer envelope. Every HTTP and WebSocket rejection compares B's complete inbox against a saved baseline, including IDs, timestamps, sender identities and payloads. A rejected WebSocket signal reports its error while the authenticated socket remains open.
- Exchange both supported asset-notification types. Read explicit-device and cursor-filtered inboxes. Inspect live session inventory before revoking a secondary session through public authentication routes. Verify expired/revoked sender and recipient guards.
- Commit one coherent five-kind model using public commands, then verify exact content, head sequence one and timing version one in the viewer snapshot. Test 17 malformed item variants through fresh commands and verify unchanged items, sequence and timing version after each rejection. Missing scene references are explicitly checked through ProjectRoom, separately from syntactic field validation.
- Accept six independently specified Unicode word-array fixtures: NEL, BOM, combining whitespace, emoji, empty dialogue, and whitespace-only dialogue. Exact saved content, sequence and timing are checked; this is not native timing execution.
- Observe all four B signals before the earliest actual 120-second deadline, then observe an empty inbox beyond the latest deadline; no continuously monitored or exact-instant expiration claim is made. Public logout then closes B's existing socket with code 4001 and denies further B inbox access and messages to B. Verify retained project state, empty R2, zero outbound attempts, no socket errors and no signals to C.

Each action callback performs a real transport operation or explicit bounded observation. Assertions throw on mismatch. The final runtime report must say `passed`; a missing action/assertion or callback failure makes the process fail. Raw response bodies, credentials and session tokens are not emitted.

## Independent audit and integration

`peer-signaling-audit-proposal.json` contains three bounded **unreviewed** contracts for `project-room.ts:588-600`, `validation.ts:5-51` and `validation.ts:52-75`. It intentionally discloses untested variants. The source/witness associations in `peer-signaling-steps.json` are proposals, not automatic reviewed links. One integration owner freezes the full caller and witness context, obtains independent semantic review, records the receipt, and applies any reviewed mapping changes separately.

The complete audit context includes the journey and catalog, production entrypoint, access/auth/team/HTTP routing and the notifications logout-refresh call chain, ProjectRoom, field validators and character-image validators, service runner, and public Scriv CLI. A catalog check proves structural/hash integrity only. Adapter-reported callback outcomes are separate from semantic audit, reviewed mapping and measured source coverage.
