# Generation metadata and device recovery

Run `tracer app -- test services generation`. The original 34 named runtime
steps remain unchanged. An appended chapter adds 30 real HTTP requests, for
64 total. Its own evidence reports 14 refused operations, eight successful
claim/update receipts, and actual logout of a synthetic device session.

Nine refusals cover an extra prompt on create, extra credential on claim, extra
localPath on update, a nonboolean recover flag, newline progress, 161-character
progress, output on a running job, error code on a running job, and invalid error
syntax. The markers are nonfunctional synthetic values. Each error has exact
JSON and leaves the declared business tables unchanged. Valid requests using
the same previously unused operation IDs subsequently succeed, including a
160-character progress update.

After the first device explicitly waits, the second must specify recover:true.
Replaying the original first-device claim returns the current second-device
owner and version, without restoring its old grant. Cross-device receipt use
conflicts, and the former device cannot complete the job. After second-device
completion, replaying the original create returns the completed job without reset.

Another job remains stored as running with a future lease when its owner logs
out through the public endpoint. Viewer reads project it to waiting without
rewriting storage; list reads also project an original queued job to waiting.
The second, still-live session must explicitly recover before finishing the job.
The revoked token fails outer authentication. This does not test revocation
mid-request or lease expiry, and no clock is changed.

Checked job payloads contain exactly the 16 public fields. Eight transitions each
append one receipt with the expected operation, actor session, resulting version
and timestamp. Running leases are checked against real request-time bounds;
waiting/completed leases are zero. Read-only D1/R2 observations preserve all
original jobs/receipts, projects, teams, memberships, assets and the empty object
listing. Session and rate-limit changes are intentional exclusions. Receipt hash
shape is checked, not independently recomputed; no storage fault is injected.

The existing request cap, per-request deadline, owned process watchdog,
telemetry-disabled configuration, outbound-deny guard and cleanup stay unchanged.
No provider, real account, local generation engine, native application, full
privacy certification, arbitrary concurrency or measured source coverage is
claimed. The original runtime callback report and appended evidence are separate.
