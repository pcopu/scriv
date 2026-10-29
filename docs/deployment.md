# Deployment-agent handoff

This repository contains the new native Mac app and its Cloudflare service. **No production deployment has been performed.** Follow this runbook from a reviewed commit whose cloud, peer and native CI jobs pass. The [verification report](verification.md) lists what has actually run; account-bound smoke tests below are release gates rather than claims of completion.

## 1. Inputs to collect

| Input | Used for |
| --- | --- |
| Intended Cloudflare account with Workers Paid and R2 enabled | Worker, SQLite Durable Objects, D1 and private media bucket. |
| Production HTTPS API origin | OAuth callback, native API configuration, invitations and billing return URLs. |
| D1 database ID and private R2 bucket name | `cloud/wrangler.jsonc` bindings. |
| GitHub OAuth App client ID and secret | Scriv account login. This is independent of the GitHub connector used to develop the repository. |
| Stripe secret key, recurring Team price ID and webhook signing secret | $9.99/month per team billing. Use test mode for acceptance, then the matching live resources. |
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

Set the returned D1 ID in `wrangler.jsonc`, replace `YOUR_SUBDOMAIN` in `vars.PUBLIC_URL` with the actual production HTTPS origin, and configure a custom domain/route if desired. Keep the public origin exactly consistent with the GitHub OAuth callback and native release configuration. The committed all-zero D1 ID and example hostname intentionally fail `npm run check:config`.

Keep R2 private: do not enable public R2.dev access or a public media domain. The Worker authorizes every media request. The deployment creates `ProjectRoom` and `BillingCoordinator` as SQLite Durable Object classes using the checked-in `v1` migration. Future schema changes require forward migrations; do not edit an already-applied D1 migration to change a running database.

Current defaults are 25 MiB per image, 10 GiB hosted media per team, 30-day Scriv sessions and a 1,000-socket limit per live room. These are independent of the unlimited invited-member pricing. Adjust storage policy deliberately in schema/configuration; do not imply unlimited storage in product copy.

## 4. Configure Scriv account login

Create a GitHub OAuth App for Scriv. Use the exact authorization callback:

```text
https://YOUR_API_ORIGIN/auth/github/callback
```

Set the two Worker secrets:

```sh
npx wrangler secret put GITHUB_CLIENT_ID
npx wrangler secret put GITHUB_CLIENT_SECRET
```

The native app opens a system authentication session, uses state and PKCE, and exchanges a single-use code after the `scriv://auth/callback` redirect. The application registration in `Info.plist` handles that URL scheme. No external callback should deliver a long-lived Scriv bearer token in a query string.

For development use a separate OAuth App with its local/tunneled callback and `.dev.vars`. There is no unauthenticated development shortcut. Verify a fresh sign-in, denial, wrong verifier, expired code, logout and revoked device session.

## 5. Configure Team billing

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

Check `GET /health` on the deployed origin for `{ok:true,service:"scriv",version:"0.1.0"}`. Then sign in using the Mac app. Public health does not prove D1, OAuth, Stripe or R2 are correctly configured; the authenticated acceptance tests below do.

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

The script submits the signed ZIP, waits for acceptance, staples and validates the ticket, checks Gatekeeper and rebuilds the final archive. Test that exact ZIP on a different Mac/account after downloading it through the intended distribution channel. Confirm `.scriv` file opening, invitation deep links, OAuth return, embedded images and local Codex launching.

CI artifacts are development builds and ad-hoc signed. The required Intel Mac job compiles both architectures, produces a universal app and runs the native runtime checks on Intel. The manual workflow's `apple_silicon_runtime` input adds execution on an Apple Silicon runner when available. They are useful for review; the Developer ID/notarized universal archive is the public release artifact. Do not publish a development build with the loopback default as the production app.

## 9. Acceptance on two real Macs

| Area | Required behavior |
| --- | --- |
| Local-only usage | Launch without accounts; edit dialogue/directions; save, quit, reopen and restore history; import/export a script and complete project. |
| Timing | A 0-second direction overlaps following words without extending the sequence; positive action time shifts subsequent content; coverage remains forward-only; multiple overlap lanes remain selectable. |
| Storyboard | A line spans multiple images; word selection/marquee selects exact words; dragging adjacent edge words or cuts preserves source order and combined duration. |
| Characters | Explicit names/aliases open the intended profile; tags describe depicted characters; portrait/gallery/version changes remain consistent. |
| Free cloud | Sign in, save script/metadata/history, reopen from another device; image bytes remain local until authorized peer transfer. |
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
