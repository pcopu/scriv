# Authenticated local collaboration journey

Run `tracer app -- test services collaboration` to exercise the production cloud
Worker and ProjectRoom Durable Object over real loopback HTTP. It also runs as
the third journey in `tracer app -- test services`.

Synthetic users, hashed sessions, team memberships and an active-team
entitlement are seeded before the first request. All subsequent collaboration
mutations use production HTTP handlers. The journey does not weaken production
authentication or make requests to the deployed service.

The scenario checks:

- Project creation and exact retries; changed-payload reuse rejection.
- Member edits, receipt retries, version conflicts, edit leases and lock conflicts.
- Viewer reads and edit denial; outsider reads denied.
- Current and historical snapshots; history and event paging.
- Role downgrade, lease release, new-write rejection and exact prior-receipt retry.
- Owner-only restore, idempotency and epoch fencing.
- Membership removal, hidden projects, logout and session revocation.
- Final project/sequence state and empty isolated object storage.

Each run owns its process group and private temporary state, with a 90-second
process deadline, 80-request ceiling, five-second request timeout, bounded bodies,
loopback-only targets, stripped inherited environment, disabled telemetry and
outbound denial. Cleanup runs on success, failure and interruption.

This is authenticated route execution using synthetic sessions, not successful
provider login or billing. WebSockets, discussions, asset transfers, large atomic
batches and native app behavior remain separate gaps. No measured line coverage
or accepted legacy baseline is inferred from this journey.
