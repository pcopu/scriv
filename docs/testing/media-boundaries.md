# Hosted media boundary journey

Run the entire existing public CLI journey:

    tracer app -- test services discussions-assets

The appended chapter preserves the original discussion, access, PNG and
subscription-lapse checks. It then reactivates only the synthetic team fixture
and uploads two distinct inert MIME-signature fixtures: a three-byte JPEG and a
12-byte WebP. These are signature-recognition inputs, not decoded images.

Each upload includes a valid asset ID and a Content-Type parameter. Retry,
viewer download and HEAD check exact bytes, MIME, length and digest headers.
The test also checks the two ready asset rows and corresponding R2 bytes,
content type and custom metadata.

Eight separate refusals check exact status, code, message and JSON response
headers: empty media, truncated signature, MIME disagreement, digest mismatch,
invalid asset ID, buffered and streaming oversize bodies, and unsupported POST.
The ordinary ASSET_MAX_BYTES setting is 12 only in this isolated Worker fixture,
so both 13-byte requests exceed it and the 12-byte original PNG/WebP succeed.
This is not execution of the default 25 MiB limit, and the response oracles do
not independently measure which internal byte-limit branch fired.

After each refusal, all asset rows and R2 keys/content bytes/content type/custom
metadata must remain equal to the two-image baseline. Rate-limit counters may
change. The invalid-ID case uses the already-deleted original PNG, so an
existing-replica retry cannot bypass validation. Deleting JPEG must preserve
WebP exactly; deleting WebP twice must leave no media rows or objects.

All behavior uses real loopback HTTP to the bundled production Worker in
Miniflare. Fixture setup and read-only synthetic storage observations are
separate from public HTTP evidence. No production function is called directly,
no provider login or live account is used, and unexpected outbound access is
denied and counted. The owning process group and temporary state are cleaned.

The named step catalog and incremental proposal record bounded relationships
for independent review. They do not certify native behavior, full image decoding,
quota counters, all R2 metadata, concurrent replacement, reconciliation, or
measured line coverage. The full repository scenario proposal is unchanged.
