# Update distribution CLI journey

Current tests enter through `tracer app -- test services` from the repository root. Legacy Vitest, Node unit and Python unit suites are removed; historical results below do not establish full replacement coverage. See [CLI-only testing](../../docs/testing/cli-only-tests.md).

Run `npm --prefix updates run test:e2e` from the repository root, using the
already-installed `cloud/node_modules` dependencies. No new framework or
package installation is required.

One scenario starts an owned child process and real Miniflare/workerd HTTP
listener on an ephemeral `127.0.0.1` port. Node HTTP fetches exercise the unchanged
`updates/src/worker.mjs`; this does not use `dispatchFetch` or mocked responses.
Local R2 APIs only prepare synthetic publication and corruption fixtures.

The scenario follows an empty feed through signed synthetic publication,
client check/download/Ed25519 verification, cache requests, corruption refusal,
broken-pointer and feed-boundary refusal, repaired publication, and isolated
acceptance-channel publication. It retains the behavior asserted by
runtime methods 0001, 0002, 0004, 0005, and 0006 in `tests/feed.test.mjs`.
The two HEAD checks share one response. Additional checks cover response security
headers, feed tamper verification, malformed pointer shape and mismatched artifact
metadata. The five runtime methods were retired after independent equivalence review and
a passing independent run. Default `npm --prefix updates test` includes this
journey; the remaining channel-helper test and all Python tests remain intact.

## Containment and evidence

- Private fresh temporary HOME, config/cache, R2 state and temporary directories.
- Child environment allowlist excludes inherited credentials, proxies and
  NODE_OPTIONS; Cloudflare telemetry and remote configuration fetch disabled.
- Explicit worker outbound-service rejection counts attempts and requires zero.
- At most 48 requests, 5 seconds per request, request bodies below 8 KiB,
  responses at most 16 KiB, and a 90-second child process-group watchdog.
- Parent cleanup kills its owned process group and removes temporary state,
  including on error. Nothing is deployed or published to a provider.
- Only inert bytes and newly generated in-memory Ed25519 keys are used. The
  ephemeral signed-feed hash changes each run. Output reports the actual worker,
  artifact and signed-feed SHA-256 hashes and request count.

These are HTTP service-process integration results, not Catalyst application,
native Sparkle updater, packaging, installation, notarization, production signing
or provider-publication E2E results. The outbound denial applies to Worker fetches;
it is not an operating-system network sandbox.

## Publication integrity and remaining acceptance gap

The same journey now makes 42 HTTP requests. With valid downstream bytes it
rejects negative, fractional, string, zero and over-limit builds and schema 2.
The literal traversal-shaped R2 key is seeded and read back before rejection.
For key/digest mismatch, bytes matching the advertised digest are stored under
the wrong key, so downstream absence or hash failure cannot mask the guard.

Valid maximum-build metadata padded with JSON whitespace succeeds at 2048
bytes; 2049 bytes returns the exact unpublished response and Retry-After 3600.
A real-hash 262144-byte feed succeeds via HEAD with XML type, length, ETag and
empty body; a real-hash 262145-byte feed is refused. A missing small feed is
then repaired, recovering exact bytes and headers with minimum valid build 1.
Metadata refusals require the exact body, no Retry-After and no-store. Every
HTTP response requires the security headers. Large local fixtures never raise
the 16 KiB HTTP response budget.

The channel-helper method (0007) remains. These discriminating public HTTP
observations do not establish literal helper/branch equivalence. Invalid channel strings are rejected by
route parsing before `validChannel` is called; traversal strings also undergo
URL normalization. Those internal channel cases remain outside this journey's
acceptance. No application signing identity or native updater is exercised.

The pointer-shape method (frozen 0003) is now replaced as an observable service
contract after an independent 42-request run and eight isolated guard-removal
experiments, each detected by HTTP 200 where 503 was required. This does not
claim identical literal helper return values or complete branch execution.
