# Staged batch ownership, capacity and receipt recovery

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Run `tracer app -- test services atomic-batch`. Original lines 1–274 and all 29
runtime callbacks/HTTP checks are unchanged. The appendix adds 45 HTTP requests
for 74 total within the unchanged 80-request cap. It seeds only one additional
synthetic auth session for the existing member; all drafts/parts/receipts and
document changes use public HTTP. The original runtime adoption proposal changes
only the reviewed atomic test full-file pin; its witness lines 116–129 are exact.

An existing invalid-part draft and a new draft occupy both user slots. The same
user's second valid auth session cannot create a third draft. Correct-byte uploads
from another authorized user or another auth session are refused; the original
session can still upload. Another user cannot take over preparation. Re-preparing
the uncommitted draft through the same user's different auth session refuses it
and discards its staging. Later re-preparation requires the part to be uploaded
again before commit, rather than resurrecting old uploaded bytes.

Five interleaved capacity refusals check that targeted cleanup frees slots while
unrelated staging still consumes its slot. A real invalid-reference commit leaves
nonlease snapshot/history unchanged and releases its reservation. A final probe
fills the other slot; another is refused, while the original invalid-part manifest
remains reusable at capacity and still cannot commit without a valid part. The
original invalid draft and final probe remain pending only in the owned temporary
worker, which is disposed at journey end.

Two valid scene batches commit once, each with an exact snapshotRequired receipt
and event. Fresh snapshots verify the independently authored scene data and all
five old items. Epoch/timing stay fixed while sequence increments once per commit.
Accepted receipts can be recovered by another live auth session of the same user;
wrong-user or changed-label replays are refused. Three successful receipt recoveries
leave the document and event stream unchanged. All original users/sessions and the
one synthetic new session remain exact; R2 stays empty and outbound is denied.

Staging is auth-session-bound, not a proven physical-device property. Both sessions
remain live/entitled. No logout, entitlement/epoch change, TTL/alarm execution,
room-wide capacity boundary, native UI, forced race/fault or crash/restart recovery
is tested. Snapshot comparisons exclude leases. Internal draft/part/receipt rows
are not read; capacity and cleanup are observed through public route behavior.
Receipt items and event changes are intentionally empty for snapshotRequired
batches, so item content is independently checked in snapshots.

The separate batch-session-capacity-evidence record describes the added 45 HTTP checks. Semantic review, manual mapping, execution and native acceptance remain distinct. Production source, original atomic catalog, native registry and GitHub Actions are untouched. No real account/provider, payment or private user data is involved.
