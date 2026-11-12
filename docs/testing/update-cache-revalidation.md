# Update cache revalidation

Run `tracer app -- test services updates`. Six appended requests bring the original
42-request journey to 48, within the original cap. Existing lines 1–240 and all
original assertions are preserved; the production Worker remains unchanged.

A validator matching an artifact filename cannot turn mismatched metadata into a
304 response. Both GET and HEAD return 503 with no ETag and no-store. After that
synthetic object is deleted, the same validator receives 404 rather than 304.
A mismatching validator on the intact valid fixture receives its exact full bytes,
verified with its ephemeral Ed25519 key. Matching HEAD returns bodyless 304 without
Content-Length and retains artifact content type, filename, ETag and immutable
cache headers. The valid stable feed still returns exact signed bytes with 200 and
no-store even when its validator matches. GET feed Content-Length is not required
by the local transport; exact bytes provide the content oracle.

R2 changes are isolated fixture setup only. No live publication, signing identity,
provider call, native install or Sparkle acceptance occurs. Origin revalidation
does not revoke bytes already stored in a client/CDN cache. The streamed artifact
path trusts publisher metadata rather than rehashing every download; this test
does not claim otherwise. Weak/list/wildcard validators, Range requests, storage
faults, large-archive memory limits and native update execution remain untested.
The historical update-service evidence file remains historical and unchanged.
