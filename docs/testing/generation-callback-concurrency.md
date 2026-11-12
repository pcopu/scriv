# Duplicate and competing generation callbacks

Run `tracer app -- test services generation`. Sixteen new requests extend the
original 34 runtime callbacks and 30 recovery requests to 80 total, within the
unchanged 80-request cap. Original lines 1–390 and the footer remain intact. Only
the deliberately inspected generation full-file pin changes in the runtime-adoption
proposal; its source witness at lines 118–131 and every other field are unchanged.

The existing retained auth session creates one metadata job. Two identical claims
are dispatched together and return the same running version two, with one receipt.
Distinct progress callbacks at the same expected version yield one winner and one
conflict. The losing operation still fails at its old version, then succeeds using
the same operation ID with the corrected version, proving its refusal did not
reserve an accepted receipt. Distinct completion callbacks compete similarly; one
output ID wins and the job becomes completed version five.

Old claim/progress retries return current completed state rather than a stale
running grant. The losing completion and fresh cancel/recover operations remain
refused without writes. Exact row/receipt checks require one new job and four
receipts, independently expected hashes, session/version IDs and bounded timestamps.
Creation timestamps and the initial queued lease are bounded by the creation request;
created_at remains exact through all accepted mutations. Running leases are bounded
by their mutation requests and completed lease is zero.
All prior observed business and identity rows remain exact; R2 stays unchanged and
outbound zero. No fixture writes, production helper calls or extra sessions are added.

These are actual concurrent HTTP client requests, not forced internal transaction
overlap or a fault-injected atomicity proof. All callbacks use one valid auth session.
Output image IDs are synthetic metadata; no image is generated or stored. Lease
expiry, storage failures, restart/crash durability, cross-session competition,
native UI and live provider execution are not tested. Original runtime, recovery
and callback evidence are separate records. Mapping is not measured coverage.
