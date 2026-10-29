# Cloud deployment evidence — 2026-10-29

## Deployed service

- API: `https://scriv-api.muddy-recipe-a722.workers.dev`
- Worker: `scriv-api`, version `f2f69d46-ca01-4810-a767-08de4b015c32`, deployed at `2026-10-29T23:12:49Z`.
- Compiled module SHA-256: `6862640a2aae152549b77a63c02619395bbdfa14eca88cb0d17bf9f65ed46d64`. Downloading the deployed module through the authenticated Cloudflare API confirmed an exact byte-for-byte match with this bundle.
- D1: `scriv`, ID `147d5380-0ceb-498f-b763-528f853205a2`; migrations `0001_identity_teams.sql`, `0002_generation_jobs.sql`, and `0003_email_auth.sql` applied and recorded. Read-back foreign-key check returned no violations.
- SQLite Durable Object classes: `ProjectRoom` and `BillingCoordinator`, migration tag `v1`.
- R2: `scriv-media`, private. Managed `r2.dev` access is disabled and no public custom domain is attached.
- Email sender: `login@scriv.why-not.work`. The owned sending subdomain reports DNS `ready`, including SPF, DKIM, and DMARC. The Worker email binding is restricted to that sender. Email content previews are disabled.
- Hourly maintenance cron: `17 * * * *`, read back after deployment.
- Worker observability enabled at 10% sampling, request query strings redacted, traces disabled, version-preview URLs disabled.

Deployment used the authenticated Cloudflare connector and the locally bundled module. No new API token, GitHub OAuth credential, Stripe credential, TURN credential, GitHub Actions run, or unrelated resource change was used.

## Verification actually performed

- Final backend typecheck and Wrangler dry-run bundle passed.
- Final backend suite: **182 passed, 1 intentionally skipped load test**. The focused email-auth suite had **21 passing tests**. Existing Workerd teardown diagnostics appeared in the aggregate log despite exit status zero; the focused email suite was clean.
- Deployment preflight passed; negative tests rejected an invalid sender, unrestricted sender binding, remote-email flag, placeholder D1 ID, and placeholder API origin.
- Production `GET /health`: HTTP 200, `{"ok":true,"service":"scriv","version":"0.1.0"}`.
- Production unauthenticated profile and invalid bearer requests: HTTP 401.
- Production email-auth validation: missing fields HTTP 400; foreign browser Origin HTTP 403; wrong content type HTTP 415; invalid OTP HTTP 401.
- Unconfigured optional GitHub login: HTTP 503 rather than an authentication bypass.
- One owner-only email OTP request at approximately `23:17Z` returned HTTP 202. D1 read-back confirmed one sent challenge, a 64-character code digest, a 600,000 ms lifetime, and zero verification attempts. No plaintext OTP was retrieved or logged. This proves provider acceptance, **not yet inbox delivery or successful live sign-in**.

The initial Python `urllib` smoke-test client received Cloudflare HTTP 403/error 1010 before reaching application code. Read-only D1 checks confirmed no challenge or send. A replacement process poll was initially blocked by auto-review for duplicate-delivery risk; subsequent process/D1 checks established no pending process and no execution. A single evidence-backed minimal request with ordinary `curl` then succeeded. No spoofed identity, User-Agent override, security-setting change, or automatic resend was used.

## Remaining acceptance boundaries

- Successful production OTP consumption, authenticated project persistence, and session revocation remain pending the owner's matching code. The test challenge expires at approximately `23:27Z`; no automatic resend is authorized.
- Cloudflare delivery telemetry was not yet available at the `23:20Z` check. Do not equate an accepted send with confirmed inbox placement.
- Stripe is intentionally not configured. Paid entitlements are not fabricated. Existing free/personal behavior syncs script, metadata, and history; image bytes stay local. Hosted image uploads remain genuinely subscription-gated until a separately authorized free-personal storage policy or real subscription is implemented.
- Multiplayer/TURN are outside the current acceptance scope. No TURN credential was created.
- Linux/backend verification is not a native macOS launch, signing/notarization, real local Codex generation, or two-device acceptance result.

## Local evidence

Ignored local evidence is under `build/cloud-deploy-20261029/`: `deployed-files.sha256`, `bundle.log`, `health.json`, `health.headers`, `negative-security-checks.json`, and `http-client-1010.txt`. The aggregate cloud-test log is `build/email-auth-final-cloud-test.log`.

The local `private/` subdirectory contains transient login material and must never be committed, published, attached, or included in evidence exports.
