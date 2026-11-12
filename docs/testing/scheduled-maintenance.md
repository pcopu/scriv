# Scheduled maintenance journey

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Run the entire existing cloud service journey:

    tracer app -- test services cloud

The original email configuration, request-body, quota and empty-identity checks
run unchanged. The appended chapter reconfigures only its isolated local runtime
and invokes the actual production scheduled handler using Miniflare's documented
reserved local event adapter. The adapter reference is recorded separately in
scheduled-runtime-contract.md. There is no direct call to a production helper,
new production fault hook, deployed trigger, clock override or external account.

Synthetic fixture setup stages nine media records across two projects/teams:

- One stale upload with matching size and SHA metadata, expected to become ready.
- Five stale records expected to be removed: missing object, wrong size, wrong
  SHA metadata, absent metadata, and a deleting replica.
- A fresh upload and an old ready replica, both retained.
- A ready sentinel in another project/team with the same digest as the wrong-size
  replica, but its own object key and correctly accounted byte count.

Complete asset rows, R2 keys/content bytes/content type/custom metadata, and both
teams' reserved-byte counters are checked against independent fixture values.
The fixture starts with nine D1 rows and eight R2 objects. Cleanup removes five
D1 rows and four existing R2 objects, leaving four rows and four objects; the
missing-object case has no object to remove. It releases exactly the removed
rows' 87 reserved bytes. The other team's
quota and same-digest replica remain unchanged. Public GET changes the recoverable
replica from unavailable to exact readable bytes, while the fresh upload remains
unavailable and retained. The test does not independently hash stored R2 bytes
inside production reconciliation; it tests the existing SHA-metadata check.

Known expired and live OAuth/code/email/rate records, plus old-expired,
recently-expired, live and revoked-live sessions distinguish the cleanup rules.
Expected removal identities are authored explicitly rather than calculated by
reusing the production expiration predicate. The scheduled event runs once,
followed only by bounded read-only observations. A second invocation must leave
all retained media, quota and expiry state unchanged. Both project records and
the earlier ASSETS bucket remain unchanged.

These counts are not distinct feature counts or native execution. Final results must be read from the current run and independent audit receipts. No live email/provider/billing reconciliation, upload interruption or crash, concurrent replacement/CAS rejection, exact age-boundary, batch-limit, transient storage failure, full R2 metadata or deployed cron acceptance is claimed.
