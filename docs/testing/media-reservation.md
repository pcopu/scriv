# Hosted media quota and interrupted uploads

Run `tracer app -- test services discussions-assets`. The original 63 requests
remain unchanged. This appended chapter adds 20 real HTTP requests, for 83 total.

A synthetic team quota of 12 bytes makes the boundary practical without changing
production guards. A 12-byte PNG reaches exact quota; retry returns the existing
replica without another reservation. Public team state reports 12 bytes. A distinct
3-byte JPEG gets exact 413/storage_quota and preserves complete asset rows,
objects and team state. Deleting PNG releases capacity so the same JPEG succeeds.
Deleting JPEG twice leaves no media and public storageUsed=0.

Two fresh synthetic members provide separate upload counters. Each valid PNG PUT
sends only its first byte under exact Content-Length. A newly observed upload
counter at one proves the initial premium/write checks passed, because those
checks precede the counter write. The session request counter also reaches one.
This marker does not prove that the byte reader has already started.

While the remainder is withheld, one request's session is publicly logged out.
For the other, the owner publicly changes the uploader to viewer. Stored
revocation/role and relevant live-session state are verified before finishing the
body. Both held requests get exact 409/upload_unavailable with complete media,
object and team/quota state unchanged. No reservation or orphan object remains.

The revoked token then gets 401. A fresh viewer upload gets 402 before incrementing
its upload counter. The retained session after logout and the restored member
session after downgrade each successfully upload the identical PNG. Exact ready
row, uploader, object bytes, MIME and specified metadata are checked; owner deletion
releases its quota. The original storage limit and full team row are restored,
original memberships are preserved, and media ends empty. Added synthetic users,
sessions and memberships are fixture state, not real account actions.

Read-only storage observations cover all asset rows, R2 keys/content bytes,
contentType/customMetadata and team rows. They do not cover every persistent table
or all R2 metadata. Session/member/counter changes are intentional. The two
controlled interleavings are not arbitrary concurrency or competing reservations.
No subscription-lapse, expiry/archive/removal interleaving, storage failure,
reconciliation failure, default 10 GiB/25 MiB scale, image decoding, native app or
measured line coverage is claimed.

The original request helper limits stay unchanged. New requests are capped at
110 total, with five-second ordinary requests, ten-second held requests,
five-second marker polling and the existing 90-second owned-process watchdog.
Unexpected outbound access is denied; telemetry is disabled and temporary state
is cleaned. No production hooks or clock changes are introduced.
