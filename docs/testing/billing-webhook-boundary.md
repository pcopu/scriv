# Signed billing webhook boundaries

Run `tracer app -- test services billing`. The new appendix adds 26 HTTP checks,
for 75 total within the original 80-request cap. Original 27 named runtime callbacks, 22 checkout cases and footer remain intact.
Two earlier lines (377 and 380) now capture and exactly assert the revoked portal
error response; all other original lines 1–387 remain exact. This is local service
integration with synthetic HMAC and provider fixtures, not live billing.

Eight signature refusals distinguish missing/invalid headers, timestamps beyond
the five-minute window, invalid digests, unsupported signature version and a signed
body that was changed afterward. Valid secondary signatures and whitespace-trimmed
fields are also exercised. Signed malformed JSON and nine signed invalid envelope
values reach exact validation errors. An expanded unknown customer is ignored;
an existing event ID reused for a distinct customer/team is retryably refused.

All new webhook calls omit Authorization. The final viewer GET is authenticated.
Before/after comparisons preserve full observed D1 rows and R2 inventory, with no
provider call on refusals or ignores. A fresh event during a synthetic provider
outage leaves those rows exact, then the same event succeeds after recovery with
one exact receipt and only expected team billing changes. Times are independently
bounded by the successful request. Replaying after the fixture becomes canceled
keeps accepted entitlement and makes no provider request; the viewer sees it active.

The chapter restores the original Miniflare provider configuration and verifies
state across that switch. This is not a process-restart or crash durability proof.
No new direct fixture writes or production helper calls are added. Observed tables
are users, sessions, teams, team_members, projects, billing_events, generation_jobs,
generation_job_operations and assets, plus R2 inventory. Security limits and
internal room refresh state are outside the unchanged-state claim.

Exact 300-second edges, signing-secret rotation, subscription pagination,
concurrent webhooks, refresh propagation failures, transaction/storage faults,
native UI and live provider execution remain separate unverified behavior.
Original runtime, checkout and new webhook evidence stay distinct. Mapping is
source navigation, not measured execution coverage.
