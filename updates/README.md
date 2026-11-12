# Scriv update distribution

Current tests enter through `tracer app -- test services` from the repository root. Legacy Vitest, Node unit and Python unit suites are removed; historical results below do not establish full replacement coverage. See [CLI-only testing](../docs/testing/cli-only-tests.md).

This separate read-only Worker serves signed public release bytes from a private R2 bucket. It has no publish endpoint, customer database, authentication secrets, cron or optional telemetry. App/source publication does not deploy this Worker or publish a release.

The configured `RELEASES` binding points to `scriv-updates`; the public origin is `scriv-updates.why-not.work`. `workers.dev` and preview URLs are disabled. Inspect existing resources before making any separately authorized infrastructure change.

## Routes and storage

- `GET/HEAD /health`: service liveness, not release acceptance.
- `/appcast.xml`: stable feed, fail-closed 503 before a release exists.
- `/channels/acceptance-<bounded-slug>/appcast.xml`: isolated signed acceptance feed; no fallback to stable.
- `/releases/<build>/<sha256>.zip`: immutable release bytes.
- Write methods: 405. Other paths and arbitrary bucket access: 404.

The operator publisher writes `releases/`, `feeds/`, and `manifests/<channel>/` objects create-once, then conditionally advances `channels/<channel>.json`. A timeout or conditional-write failure requires read-back reconciliation, never blind retry/overwrite. The Worker cannot publish and contains no S3 credentials.

## Local verification

```sh
npm --prefix cloud ci
npm --prefix updates test
npm --prefix updates run build  # deployment dry-run only
```

Tests use local Workers/R2, synthetic payloads and ephemeral in-memory test keys. Release tooling additionally needs the Python packages in `requirements.txt`. See [client policy](../docs/app-updates.md) and [authorized native acceptance procedure](../docs/signed-update-acceptance.md). No portable result is evidence of a signed native installation or UI acceptance.

The current local HTTP journey runs 48 requests, including six [cache revalidation checks](../docs/testing/update-cache-revalidation.md). Matching validators cannot bypass missing or mismatched artifact metadata; feeds remain no-store. These origin checks do not invalidate existing client/CDN caches.
