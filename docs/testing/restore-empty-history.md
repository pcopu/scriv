# Restore empty content and retain discussion history

Run `tracer app -- test services revision-safety`. The original 18 callbacks and
74 HTTP requests remain unchanged, followed by 49 additional requests for 123 total.
The original 200-request cap and 90-second process deadline remain. Original natural
lease expiry still runs; no new waits, direct fixture writes or production changes.

After the original two live scenes and one tombstone, a member creates one project
discussion and authored message. Fresh member/viewer restores fail without visible
state changes. Owner restoration of the existing content preserves every item
version. Restoration of sequence zero tombstones the two live scenes once and keeps
the older tombstone version fixed. A second empty restore leaves every tombstone
version unchanged. Each fresh restore still advances head/epoch/timing once, clears
active public leases, and adds one exact snapshotRequired receipt/event.

All three restores preserve the exact discussion and message. Empty content remains
non-importable: a valid fresh owner import returns project_not_empty. Three exact
restore retries return the old receipts without new mutations. Historical sequence
zero is empty, while three limit-one cursor pages for sequence six retain the prior
live items, metadata-only tombstone and original event metadata. Historical snapshots
intentionally project empty threads/leases; current discussion stays on its own routes.

Current snapshot/journal/thread/messages are checked between mutations. Read batches
run concurrently without concurrent writes; lease fields are excluded from refusal
comparisons, while successful restores explicitly require no active leases. Original
users/sessions remain exact, R2 empty and outbound zero. All new data is synthetic.

This is public local HTTP evidence. No permanent erasure, raw DO row equality,
large-page limits, storage faults, forced race, restart/crash persistence, websocket
broadcast, changed entitlement, native UI or live provider guarantee is claimed.
Mapping, semantic review and execution remain separate. Catalog and proposal
dependencies must be rechecked when the test source changes.
