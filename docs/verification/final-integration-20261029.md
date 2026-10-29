# Final source integration checks — 2026-10-29

The current delivery target is the single-user service and completed source integration. Multiplayer acceptance is explicitly deferred, as is Stripe configuration. Existing authorization, private-media and paid-team gates remain intact; deferral is not a permission bypass.

## Frozen implementation

All implementation owners stopped writing before the final portable run. This integrates the six approved intent corrections (source-owned image coverage, independent authored word timing, stable character links, script-aware generation, larger atomic edits and streaming/presence improvements), durable invalid-editor recovery, email-first login and two final recovery corrections:

- Definitively rejected transactional commands retain an exact `.rejected` audit copy without permanently blocking corrected edits. Ambiguous/transport/auth failures keep their pending command identity.
- Delayed canonical snapshots cannot overwrite newer history or accepted-receipt state. Replay progress and receipt progress remain separate.

The email flow includes bounded request/verify state, owner-scoped cancellation across native surfaces, PKCE, short expiry, atomic single-use consumption, attempt/rate limits and origin checks. Existing GitHub contact emails are not silently linked to new email identities. See the [API contract](../cloud-api.md), [editor recovery](editor-draft-recovery-20261029.md) and [source-owned timing](source-owned-timing-20261029.md).

## Checks actually run

| Check | Result and scope |
| --- | --- |
| Portable Swift core | **181 tests passed, zero failures**, Swift 6.4.1 on Debian 13 x86_64. |
| Swift syntax | **81 source/test files plus the icon script parsed.** This is not AppKit/SwiftUI type-checking. |
| Optimized `ScrivCore` | Release build passed on Linux. |
| Source guard | All **107** native/script/test files had identical SHA-256 before and after the final run. |
| Cloud TypeScript | Strict typecheck passed. |
| Local Worker/D1/DO/R2 suite | **182 passed, one opt-in load test skipped.** Includes 21 email-auth tests with an injected fake sender; no live mail from tests. |
| Worker bundle / deployment preflight | Dry-run bundle and configured-resource/sender validation passed. The first bundle attempt failed on the read-only home Wrangler config path; retry with a workspace-local `XDG_CONFIG_HOME` passed. |
| Root Node suite | **21 passed, zero failures.** Includes isolated Codex protocol/process checks and native-verifier harness tests, not native execution. |
| Preservation | All **25 original concepts** and **three sample frames** matched their manifests; root `transcript.MD` and `.github` remain unchanged. |
| Real Chromium peer suite | **One passed, eight failed** waiting for peer events. Captured diagnostics showed an offerer remaining in ICE gathering with a connecting channel. No retry or claim of peer acceptance; multiplayer is outside current acceptance. |
| Whitespace / source scan | `git diff --check` passed; no private-key, GitHub-token, live-Stripe-key or AWS-access-key pattern found in the source scan. This is a narrow pattern check, not a comprehensive security certification. |

The passing cloud suite still logs workerd request-stream and teardown exceptions. Preserve that qualification rather than presenting warning-free runtime output. The historical six-peer-test/native-CI passes elsewhere in the repository belong to their recorded older source, not this integration.

Local evidence is under `/workspace/shared/scriv-final-integration-20261029/`: `portable-final.log`, `swift-source-before.json`, `swift-source-after.json`, `test-summary.json`, `cloud-checks.log`, `cloud-build-retry.log`, `node-checks.log` and `peer-browser.log`. These are diagnostic paths, not published user project data. The source-only publication snapshot/manifest is separate from generated build output.

## Deployed service and remaining acceptance

The Cloudflare backend was deployed at **2026-10-29 23:12:49 UTC**, Worker version `f2f69d46-ca01-4810-a767-08de4b015c32`. Its deployed bundle SHA-256 is `6862640a2aae152549b77a63c02619395bbdfa14eca88cb0d17bf9f65ed46d64`. Resource, route and email-delivery/session evidence are recorded separately in [cloud deployment verification](cloud-deployment-20261029.md); a 202 code request is not proof of delivery or completed sign-in.

No current-source native Mac build, AppKit/SwiftUI type-check, real app interaction, Keychain runtime test, fresh native screenshot comparison, live Codex image generation, cross-network transfer, Developer ID signing or notarization ran in this Linux workspace. Stripe was not configured or charged. No GitHub Actions workflow was edited or dispatched; publication uses `[skip ci]`.

The older remote `Doppler` branch has not been deleted: the available connector has no supported branch-deletion operation and the local checkout has no authenticated push transport. Retaining it is a documented cleanup gap, not evidence that a deletion succeeded.
