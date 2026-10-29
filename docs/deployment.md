# Deployment-agent handoff

The Cloudflare backend is deployed at **https://scriv-api.muddy-recipe-a722.workers.dev** with D1, private R2, SQLite Durable Objects and restricted login email from `login@scriv.why-not.work`. See [deployment verification](verification/cloud-deployment-20261029.md) for the exact Worker version, resource read-backs and email/session acceptance outcome. Stripe and multiplayer acceptance are explicitly deferred for the current single-user delivery. This is not a claim of a native production release: the [final integration record](verification/final-integration-20261029.md) separates passed Linux/cloud checks, actual failures and unrun Mac/signing gates. The remaining runbook below is for later authorized acceptance and distribution.

## 1. Inputs to collect

| Input | Used for |
| --- | --- |
| Intended Cloudflare account with Workers Paid and R2 enabled | Worker, SQLite Durable Objects, D1 and private media bucket. |
| Production HTTPS API origin | Native API configuration, email-origin checks, optional OAuth callback, invitations and billing return URLs. |
| D1 database ID and private R2 bucket name | `cloud/wrangler.jsonc` bindings. |
| Verified Cloudflare Email Sending domain and restricted `EMAIL` binding | Primary six-digit email-code Scriv login. No mail API token is needed for the Worker binding. |
| Optional GitHub OAuth App client ID and secret | Compatibility login for existing GitHub identities; not required for email sign-in. |
| Stripe secret key, recurring Team price ID and webhook signing secret | Deferred by the current deployment authorization. Later: $9.99/month per team billing, test-mode acceptance before live resources. |
| Cloudflare Realtime TURN key ID and API token | Reliable peer transfer across restrictive NATs. Optional for local/direct tests; required before advertising broad internet peer connectivity. |
| Apple Developer ID Application signing identity and notary credentials | Public Mac distribution. |
| Codex installed on the acceptance-test Macs and the testers' own ChatGPT accounts | Real local generation smoke test. These credentials stay on the Macs. |

Do not put credential values into source, issue comments, screenshots or command arguments that will be logged. Wrangler secret input and the macOS Keychain handle these values. The public API origin, resource names and D1 ID are ordinary deployment configuration.

## 2. Verify the reviewed checkout

From the repository root:

```sh
npm ci
npm --prefix cloud ci
npm run check
npm test
npm --prefix cloud run test:load
npx playwright install chromium
npm run test:peer
npm --prefix cloud run build
```

On a Mac:

```sh
swift test --package-path apps/mac
bash scripts/build-mac.sh
open build/Scriv.app
```

`cloud build` is a dry run. It does not provision infrastructure. Review native screenshots from the matching commit's GitHub Actions artifacts, then operate the app to check editing/dragging as well as its appearance. A screenshot cannot verify interactive behavior.

## 3. Configure and create Cloudflare resources

Run the following section from `cloud/` after confirming the intended account in `wrangler whoami`:

```sh
npx wrangler whoami
npx wrangler d1 create scriv
npx wrangler r2 bucket create scriv-media
```

The current `wrangler.jsonc` records the provisioned `scriv` D1 ID, private `scriv-media` bucket, API origin `https://scriv-api.muddy-recipe-a722.workers.dev` and sender `login@scriv.why-not.work`. These are ordinary resource identifiers, not credentials. Do not recreate existing resources when updating this deployment. For another account, create its resources and deliberately replace the bindings/origin. Keep the public origin consistent with native release configuration, email-origin checks and any optional OAuth callback. `npm run check:config` rejects missing resource/sender configuration.

Keep R2 private: do not enable public R2.dev access or a public media domain. The Worker authorizes every media request. The deployment creates `ProjectRoom` and `BillingCoordinator` as SQLite Durable Object classes using the checked-in `v1` migration. Future schema changes require forward migrations; do not edit an already-applied D1 migration to change a running database.

Current defaults are 25 MiB per image, 10 GiB hosted media per team, 30-day Scriv sessions and a 1,000-socket limit per live room. These are independent of the unlimited invited-member pricing. Adjust storage policy deliberately in schema/configuration; do not imply unlimited storage in product copy.

## 4. Configure Scriv account login

Email codes are primary. Verify a Cloudflare Email Sending domain and sender, bind `EMAIL` with `allowed_sender_addresses` restricted to the login sender, and set `EMAIL_FROM`. The current sender is `login@scriv.why-not.work`; that domain's sending DNS is separate from the Worker API hostname. Keep email content preview disabled and never log request bodies, codes, PKCE verifiers or bearer tokens. The Worker sends only a fixed login template, not arbitrary user-provided mail.

Apply additive migration `0003_email_auth.sql`. It preserves existing user IDs/foreign keys and never silently links GitHub contact emails to email identities. The native app requests and verifies a short-lived six-digit code using an in-memory PKCE verifier, then stores the opaque session token in the origin-scoped Keychain. The exact expiry, resend, attempts and request limits are in the [API contract](cloud-api.md#native-sign-in).

Tests inject a fake sender and cannot establish real delivery. Use only an explicitly authorized recipient for a production delivery test. Verify delivery metadata, user-entered code consumption, replay/expiry, cancellation, wrong verifier, logout and revoked device sessions without recording secret values in evidence.

Existing GitHub accounts may still use optional OAuth if `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` are configured. Its exact callback is `https://<api-origin>/auth/github/callback`; the native return remains `scriv://auth/callback`. This provider is not required for email-only launch. There is no unauthenticated development shortcut, no automatic account merge and no ChatGPT credential sent to this backend.

## 5. Configure Team billing — deferred

**Stripe was explicitly excluded from the current deployment.** The source remains implemented, but checkout/webhook/paid-team acceptance is not claimed. Existing paid-access and private-media authorization gates are not bypassed to compensate. The following is the future authorized setup runbook, not an instruction to provision billing now.

Create one Stripe recurring price with these exact values:

| Field | Value |
| --- | --- |
| Product | Scriv Team |
| Currency | USD |
| Unit amount | 999 cents |
| Interval | Monthly, interval count 1 |
| Quantity | 1 per team |
| Per-seat billing | None |

Enable the Stripe customer billing portal. Use the snapshot webhook format with API version `2025-04-30.basil`, matching the code's Stripe request version. The endpoint is:

```text
https://YOUR_API_ORIGIN/billing/webhook
```

Subscribe to `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.paid` and `invoice.payment_failed`.

```sh
npx wrangler secret put STRIPE_SECRET_KEY
npx wrangler secret put STRIPE_TEAM_PRICE_ID
npx wrangler secret put STRIPE_WEBHOOK_SECRET
```

The price is validated on checkout; an accidental $10, annual or per-seat price is rejected. Only an owner can open checkout/portal. The redirect merely returns to the app. Entitlement comes from signed events followed by canonical Stripe subscription retrieval, with per-team serialized reconciliation and event deduplication.

Complete test-mode checkout, reusable team invitation, cancellation/renewal, duplicate webhook and late cancellation-event tests before using live keys. Confirm that a new active subscription survives an older canceled subscription's delayed event. Moving to live mode requires the matching live price and endpoint secret; do not mix test and live identifiers.

## 6. Configure peer relay

Provision a Cloudflare Realtime TURN key and add:

```sh
npx wrangler secret put TURN_KEY_ID
npx wrangler secret put TURN_API_TOKEN
```

The API issues temporary ICE credentials to authorized devices. The native bridge uses WebRTC encrypted data channels, bounded chunks and full-file hash verification. Without TURN, direct/STUN transfer can work on compatible networks and fail on restrictive NATs. Test both direct transfer and a TURN-only connection between separate networks; the local two-browser test cannot prove production NAT traversal.

## 7. Migrate, deploy and verify service health

From `cloud/`, after configuration and secrets are ready:

```sh
npm run check:config
npm run db:migrate:remote
npm run deploy
```

Check `GET /health` on the deployed origin for `{ok:true,service:"scriv",version:"0.1.0"}`. Then sign in using the Mac app. Public health does not prove email delivery, completed sign-in, D1/DO authenticated mutation, Stripe or R2 access; record the actual checks separately. Stripe acceptance remains deferred.

Make sure the hourly maintenance trigger is active. It expires auth/rate-limit state, reconciles billing, and repairs abandoned media reservations. Keep Worker observability enabled and monitor unexpected authorization failures, 5xx responses, rejected timing/version commands, storage quota failures and replay gaps.

## 8. Produce the public Mac build

From the repository root on a Mac with a Developer ID identity in Keychain:

```sh
SCRIV_RELEASE=1 \
SCRIV_UNIVERSAL=1 \
SCRIV_CLOUD_URL=https://YOUR_API_ORIGIN \
SCRIV_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
SCRIV_VERSION=0.1.0 \
SCRIV_BUILD_NUMBER=1 \
bash scripts/build-mac.sh
```

The script builds both Apple Silicon and Intel, creates a universal executable, embeds the resource bundle and icon, writes release metadata, signs with the hardened runtime, verifies the signature and creates `build/Scriv-macOS.zip`. Release mode refuses a missing HTTPS API origin or signing identity.

Create a notary Keychain profile using `xcrun notarytool store-credentials` with the intended Apple team, then run:

```sh
SCRIV_NOTARY_PROFILE=scriv-notary bash scripts/notarize-mac.sh
```

The script submits the signed ZIP, waits for acceptance, staples and validates the ticket, checks Gatekeeper and rebuilds the final archive. Test that exact ZIP on a different Mac/account after downloading it through the intended distribution channel. Confirm `.scriv` file opening, invitation deep links, email login/cancellation, optional OAuth return, embedded images and local Codex launching.

CI artifacts are development builds and ad-hoc signed. The required Intel Mac job compiles both architectures, produces a universal app and runs the native runtime checks on Intel. The manual workflow's `apple_silicon_runtime` input adds execution on an Apple Silicon runner when available. They are useful for review; the Developer ID/notarized universal archive is the public release artifact. Do not publish a development build with the loopback default as the production app.

## 9. Acceptance on two real Macs

| Area | Required behavior |
| --- | --- |
| Local-only usage | Launch without accounts; edit dialogue/directions; save, quit, reopen and restore history; import/export a script and complete project. |
| Timing | A 0-second direction overlaps following words without extending the sequence; positive action time shifts subsequent content; coverage remains forward-only; multiple overlap lanes remain selectable. |
| Storyboard | A line spans multiple images; word selection/marquee selects exact words; dragging adjacent edge words or cuts preserves source order and combined duration. |
| Characters | Explicit names/aliases open the intended profile; tags describe depicted characters; portrait/gallery/version changes remain consistent. |
| Free cloud | Request/verify an email code, sign out/revoke a session; save script/metadata/history and reopen from another device. Image bytes remain local until authorized peer transfer. |
| Team access | Pay in Stripe test mode at $9.99; reuse an invitation with multiple signed-in users; test viewer/member/admin rules, revocation and removal. |
| Collaboration | Independent line edits stream; same-line entry is excluded; actual text caret/selection appears; disconnect/reconnect repairs gaps; stale drafts stay recoverable. |
| Restore | Restore during active editing; old leases/epochs are rejected and restored content is a new history event. |
| Discussion | Project, character, dialogue, direction and exact image-version threads; replies, resolution and long-message-history pagination. |
| Media | Direct P2P and TURN-only transfer; hash checks; offline source failure; paid R2 replica upload/download and fallback; quota enforcement. |
| Codex | Start, stop, loopback connect, separate ChatGPT sign-in, image generation with references, cancellation and visible actual-error behavior. Confirm a late result preserves intervening edits. |
| Billing lifecycle | Renewal, cancellation, late/duplicate events, no duplicate open checkout, downgraded read/export policy and restored paid access. |

Record the app version, Codex version/model, backend commit, test-mode Stripe price, Mac OS/architecture, network conditions and pass/fail evidence. This is the remaining account/runtime verification that local automated tests cannot perform.

## 10. Capacity, cost and recovery

The local runtime test proves 500 authenticated open sockets and 100 simultaneous independent content commands with all expected mutation deliveries. It is not a geographic latency SLA, a sustained-typing benchmark or a test of 500 continuously moving cursors. Rooms above 100 sockets coalesce full presence snapshots to 1 Hz; ordinary rooms allow up to 5 Hz. Durable mutation notifications are batched briefly while accepted commands remain durably journaled before acknowledgement.

The Workers Paid plan has a base subscription and usage allowances; traffic, SQLite work, storage and optional TURN can exceed those allowances. Watch Workers CPU/requests, Durable Object requests/duration/SQLite, D1 reads/writes/storage, R2 operations/storage and TURN bytes. Configure account usage alerts and choose storage/relay policy before public launch. The $9.99 team subscription does not make Cloudflare usage unlimited.

Use D1 export/Time Travel for identity/catalog recovery. Project event history resides in per-project Durable Object storage; export authenticated project snapshots/events or full native `.scriv` packages to a separate backup destination on a scheduled operational basis. Image replicas need their own retention/backup policy. Application history and same-service replicas are not an independent disaster-recovery backup. Run a restore drill before promising a retention SLA.

For a bad Worker release, inspect Cloudflare deployment/version history and roll back to the last known-good **schema-compatible** version. Do not delete Durable Objects, buckets or D1 data to roll back code. Prefer additive migrations and leave previous event formats readable. A native rollback must continue to open the saved project format; retain the previous signed build and exported projects during acceptance.

## References

- [Cloudflare Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)
- [SQLite Durable Objects](https://developers.cloudflare.com/durable-objects/best-practices/access-durable-objects-storage/)
- [Cloudflare WebSocket hibernation](https://developers.cloudflare.com/durable-objects/best-practices/websockets/)
- [R2 pricing](https://developers.cloudflare.com/r2/pricing/)
- [Cloudflare Realtime TURN](https://developers.cloudflare.com/realtime/turn/)
- [Stripe subscription webhooks](https://docs.stripe.com/billing/subscriptions/webhooks)
- [Codex app-server](https://developers.openai.com/codex/app-server/)
- [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
