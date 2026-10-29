# Cloud deployment evidence — 2026-10-29

## Deployed service

- API: `https://scriv-api.muddy-recipe-a722.workers.dev`
- Worker: `scriv-api`, latest version `83ac3161-1fd4-4e1d-9070-f8a309cf84a6`, deployed at `2026-10-29T23:35:11Z`.
- Latest compiled module SHA-256: `7f62e02d56baf1663262e8799c0139a96a5f0ffb8be56c6f9c36c243d204114b`. Downloading the deployed module through the authenticated Cloudflare API confirmed an exact byte-for-byte match with this bundle.
- Initial version `f2f69d46-ca01-4810-a767-08de4b015c32` was deployed at `23:12:49Z`, with module SHA-256 `6862640a2aae152549b77a63c02619395bbdfa14eca88cb0d17bf9f65ed46d64`. Its 21 cloud source/configuration/migration inputs match published commit `eabdc5383a68cf2d6dea98589579c3aecba5c465`; the remote source tree was independently verified.
- The latest deployment changes only the image `generationPrompt` validation and immutable-image-field list in `cloud/src/validation.ts` and `cloud/src/project-room.ts`. Their frozen SHA-256 hashes are respectively `36f16a9e9f6c11d38d5f6e65c5a714da2165a69aa949b77486e957bbe8f9dec3` and `309a096a287a08785e79fc9ff4a8fbae299c6c4b774d982a90f5b6018a73cd3f`. All other deployment inputs are unchanged. No new database migration or resource was required.
- D1: `scriv`, ID `147d5380-0ceb-498f-b763-528f853205a2`; migrations `0001_identity_teams.sql`, `0002_generation_jobs.sql`, and `0003_email_auth.sql` applied and recorded. Read-back foreign-key check returned no violations.
- SQLite Durable Object classes: `ProjectRoom` and `BillingCoordinator`, migration tag `v1`.
- R2: `scriv-media`, private. Managed `r2.dev` access is disabled and no public custom domain is attached.
- Email sender: `login@scriv.why-not.work`. The owned sending subdomain reports DNS `ready`, including SPF, DKIM, and DMARC. The Worker email binding is restricted to that sender. Email content previews are disabled.
- Hourly maintenance cron: `17 * * * *`, read back after deployment.
- Worker observability enabled at 10% sampling, request query strings redacted, traces disabled, version-preview URLs disabled.

Deployment used the authenticated Cloudflare connector and the locally bundled module. No new API token, GitHub OAuth credential, Stripe credential, TURN credential, GitHub Actions run, or unrelated resource change was used.

## Verification actually performed

- Final backend typecheck and Wrangler dry-run bundle passed.
- Latest backend suite: **188 passed, 1 intentionally skipped load test**, including **6 image-prompt tests**. The initial email deployment had 182 passing tests, including 21 email-auth tests. Existing Workerd teardown diagnostics appeared in the aggregate log despite exit status zero; the focused email suite was clean.
- Deployment preflight passed; negative tests rejected an invalid sender, unrestricted sender binding, remote-email flag, placeholder D1 ID, and placeholder API origin.
- Production `GET /health`: HTTP 200, `{"ok":true,"service":"scriv","version":"0.1.0"}`.
- Production unauthenticated profile and invalid bearer requests: HTTP 401.
- Production email-auth validation: missing fields HTTP 400; foreign browser Origin HTTP 403; wrong content type HTTP 415; invalid OTP HTTP 401.
- Unconfigured optional GitHub login: HTTP 503 rather than an authentication bypass.
- The initial owner-only email OTP request at approximately `23:17Z` returned HTTP 202. D1 read-back confirmed a 64-character code digest and a 600,000 ms lifetime. The owner later supplied the delivered code after its expiry; it was not consumed. A fresh, explicitly authorized challenge was requested at approximately `23:29Z`, and the owner's matching code successfully signed in at `23:30Z`. No code or bearer token was printed in verification output or public evidence.
- **19 authenticated production checks passed on the initial deployed version**, completed at `23:31:55Z`: authenticated profile/configuration; personal project creation; real SQLite Durable Object initialization; durable command commit and idempotent replay; later-request snapshot reads; free personal image `prompt` metadata persistence; absent hosted-copy handling; HTTP 402 paid-only binary-upload enforcement; leased edits; updated and historical snapshots; journal events; consumed-OTP rejection; temporary project archival and catalog removal; logout; and HTTP 401 rejection of the revoked session.
- D1 read-back after cleanup: one verified email identity, one revoked session, one archived verification project, zero hosted assets, zero teams, and no foreign-key violations. No paid entitlement was created. Transient local code, verifier, and session files were removed.
- After the generation-prompt update, exact remote-module verification, HTTP 200 health, and six negative authentication/security checks passed again. D1 identity/session/project state and all three migration records remained intact; foreign-key check was clean. Bindings, cron, and observability settings were read back unchanged. No further OTP was sent and authenticated smoke tests were not repeated; the new `generationPrompt` rules are covered by the local Workers-runtime tests, not a new production write.

The initial Python `urllib` smoke-test client received Cloudflare HTTP 403/error 1010 before reaching application code. Read-only D1 checks confirmed no challenge or send. A replacement process poll was initially blocked by auto-review for duplicate-delivery risk; subsequent process/D1 checks established no pending process and no execution. A single evidence-backed minimal request with ordinary `curl` then succeeded. No spoofed identity, User-Agent override, security-setting change, or automatic resend was used.

## Remaining acceptance boundaries

- Cloudflare per-domain delivery telemetry remained empty during the observation window. Inbox receipt and functional delivery were instead established by the owner's matching code and successful production verification; the telemetry gap is not evidence of delivery failure.
- Stripe is intentionally not configured. Paid entitlements are not fabricated. The owner confirmed paid-only cloud image binaries: free/personal script, timing, image-prompt metadata, and history remain cloud data, while free image bytes stay local. The live API check verifies the existing image `prompt` field; native mapping of the full effective generation prompt is a separate source-acceptance question, not proven by that API-only test.
- Multiplayer/TURN are outside the current acceptance scope. No TURN credential was created.
- Linux/backend verification is not a native macOS launch, signing/notarization, real local Codex generation, or two-device acceptance result.

## Local evidence

Ignored local evidence is under `build/cloud-deploy-20261029/`: `deployed-files.sha256`, `published-source-match.json`, `bundle.log`, `health.json`, `health.headers`, `negative-security-checks.json`, `live-authenticated-checks.json`, `http-client-1010.txt`, `prompt-deployed-files.sha256`, `prompt-bundle.log`, and `prompt-live-security-checks.json`. The initial aggregate cloud-test log is `build/email-auth-final-cloud-test.log`.

The local `private/` subdirectory contains smoke-test scripts and operation-recovery state and must never be committed, published, attached, or included in evidence exports. Transient login material was deleted after the verification session was revoked.
