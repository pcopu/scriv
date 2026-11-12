# Revision safety local service journey

Run from the repository with the reviewed runtime:

```sh
SCRIV_TRACER_RUNTIME=/absolute/reviewed/tracer/src/scenario-runtime.mjs \
  node /absolute/reviewed/tracer/bin/tracer.mjs app -- test services revision-safety
```

This is one coherent 18-step local HTTP journey through the actual bundled Worker and Miniflare. The CLI selects `cloud/tests-e2e/revision-safety-journey.mjs`. Runtime actions include two real waits; natural lease expiry consumes approximately 30 seconds. Each invocation owns temporary HOME/config/cache/storage and process group; parent timeout is 90 seconds. All external Worker fetches are denied. No implementation behavior is substituted.

## Fixture and exact progression

Direct D1 setup provisions four synthetic users/sessions and an active paid team. This is fixture provisioning, not login/billing behavior. Migrations are applied to temporary local D1. No direct DO SQL, lease-table change, fake clock, production source change, provider call, or live account is used. R2 remains empty.

1. Create a project over public HTTP, then two scenes Opening and Ending, each version 1. Sequence 1 and timing 0.
2. Acquire Opening lease fence 1, renew it with unchanged identity/token and bounded later expiry, release it, reacquire fence 2. Released proof and mismatched command-session proof both fail `lease_required` while the active public lease stays unchanged.
3. Delete Opening at sequence 2: version-2 tombstone is publicly empty-data, while receipt/event retain exact before/after content. Put the same identity at expected tombstone version 2 to undo: Recovered opening v3 at sequence 3.
4. At sequence 4, delete Ending (v2 tombstone) and create Later scene (v1). Historical snapshots for sequences 2/3 independently assert exact live and deleted item sets and historical event metadata; wrong historical epoch is refused.
5. Owner restores sequence 1: sequence 5, epoch 2, timing 1. Opening becomes original content v4; Ending is resurrected v3; Later scene becomes v2 tombstone. Both active leases disappear. Receipt and restore event require snapshot refresh and have empty item/change arrays.
6. Retry the original delete after restoration: exact epoch-1 sequence-2 receipt returns, without another event or mutation. Changed retry is `command_reused`. Exact restore replay also returns its old receipt without another epoch change.
7. Fresh old-epoch command, old lease in current epoch, stale item version under newly reacquired fence 3, future restore sequence and stale restore epoch each fail precisely. Ordered history pagination after sequence 3 returns command 4 then restore 5, with hasMore true then false.
8. Wait through real fence-3 expiry. Expired proof is refused and public active leases empty. Reacquire fence 4 and save Opening v5 in epoch 2 at sequence 6. Reuse the earlier refused version-conflict command ID with corrected bytes, establishing that refusal did not reserve a successful receipt. Ending v3 and Later-scene v2 tombstone remain unchanged.

Every step reads current snapshot and the complete small event journal. `state()` checks independently authored live/tombstone data, versions, project identity, epoch, head, timing, canImport, threads and exact ordered event payloads. Event times are bounded on their first observation, then compared exactly by sequence on every subsequent journal read; historical snapshots must retain those same observed timestamps. The initial timestamps are observed, not guessed. Additional explicit lease listings cover renewal, release, refusal, restore and expiry. No claim is made about unobservable internal tables; public replay and corrected retry are the receipt oracles.

## Mapping and audit

`revision-safety-steps.json` is a pinned named-step catalog; `revision-safety-proposal.json` is the complete scoped proposal. Both remain unreviewed candidates. Narrow mappings exclude byte-cap branches, implementation-only cached receipt branches intercepted by the public route, unreachable restore-new-identity branches and untested skip branches. Mixed physical lines are limited by explicit rationale to the asserted variants. Do not self-promote.

The prior full repository proposal is retained unchanged. Mapping discovery, semantic audit and actual execution remain separate. Existing runner mappings become stale when this isolated new route is integrated; the sole integrator must update runner/discovery witnesses rather than accepting the old hashes.

## Limits

No native app, Mac, provider, live network, websocket/broadcast delivery, concurrent race, disk/process-restart durability, large-page/large-batch limits, admin restore, permission-loss or full authentication-session matrix is covered here. Public reads do not prove internal SQL row counts or every branch on compact source lines. The whole application is not declared complete by this journey.
