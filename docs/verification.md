# Verification report

Date: 2026-10-29. This report distinguishes source implementation, actual automated results and account-bound release checks. No production service has been deployed and no real subscription or image-generation charge was created by this build work.

## Completed automated checks

| Check | Result | Environment and evidence |
| --- | --- | --- |
| Swift core | **28 tests passed, zero failures, on Linux and macOS** | Portable Foundation core, tested with the official Swift 6.0.3 Linux toolchain and the native Mac CI build. Covers timing, direction overlap, word transfer, Fountain, crash-safe immutable history, hashes and three-way reconciliation. |
| Native application | **Passed** | Actual AppKit/SwiftUI/WebKit compilation and core tests on macOS, optimized `arm64` and `x86_64` builds, universal packaging, signature validation and packaged application launch. |
| Codex protocol | **18/18 checks passed** | Official Codex 0.165.0 generated JSON Schema; 15 valid fixtures plus 3 negative regressions. No login or model turn. See [contract evidence](codex-integration.md). |
| Cloud TypeScript | **Passed** | Strict `tsc --noEmit` with the pinned Worker bindings/toolchain. |
| Worker integration | **24 tests passed** | Actual local Workers runtime, D1/SQLite Durable Objects and R2 emulation. External GitHub/Stripe responses are controlled test responses. One optional load test is skipped in the normal suite. |
| Worker packaging | **Passed, dry run** | Wrangler bundle generated without deployment. |
| Room capacity | **Passed** | Separate opt-in test: 500 distinct authenticated members/WebSockets, 100 concurrent independent script writers, all 50,000 expected mutation observations and durable final sequence. |
| Browser peer transfer | **6 tests passed locally and in final-code CI** | Actual Chromium WebRTC channels: multi-chunk transfer, either device initiating, simultaneous/staggered requests with throttled CPUs and ICE before SDP, invalid/missing/unsolicited media rejection, reconnection and recovery after dropped connect/offer/answer signals. |
| Design fixture | **3 tests passed** | Exact accepted duration/cue/word/coverage invariants. |
| Asset preservation | **Passed** | All 25 original design images and all 3 sample frames match their stored SHA-256 manifests. |
| Shell/package source checks | **Passed** | Shell syntax, bridge JavaScript syntax and required release-file checks. |

The final runtime source is [0eb779b](https://github.com/pcopu/scriv/commit/0eb779b8e07935235d4584b09abe05bd0504be01). Its [verification run 40921544866](https://github.com/pcopu/scriv/actions/runs/40921544866) **completed successfully**: the [cloud job](https://github.com/pcopu/scriv/actions/runs/40921544866/job/123616157671), [peer job](https://github.com/pcopu/scriv/actions/runs/40921544866/job/123616157656) and [native Mac job](https://github.com/pcopu/scriv/actions/runs/40921544866/job/123616157151) all passed. The later documentation-only commit adds the captured images and this report without changing the verified runtime source.

A separate final-source browser stress run used CPU throttling rate 4 and five repetitions of all five simultaneous/staggered scenarios: **25 scenarios**, plus the other five test categories, with **6/6 tests passing** in **11.199 seconds**. Its recovery test covers all five lost-signal combinations: the higher-ID requester losing a connect request, offer or answer, and the lower-ID requester losing an offer or answer. Only the request deadline is advanced for the timeout test; image bytes still cross the real browser transport. No retry-on-failure wrapper or increased production timeout hides negotiation failures.

## Native build and visual gate

**Passed at the final runtime commit `0eb779b`:** actual AppKit/SwiftUI/WebKit compilation, 28 native core tests, optimized builds for both `arm64` and `x86_64`, universal app packaging and signature verification, packaged application launch, real WebKit peer transfer, and all three native screenshot captures. Evidence: [Mac job 123616157151](https://github.com/pcopu/scriv/actions/runs/40921544866/job/123616157151).

The native smoke test opened two genuine WKWebView instances and transferred **2,150,385 bytes** over WebRTC in **6.905 seconds**, including fresh view startup. It checked SHA-256 and byte equality and deliberately made the higher-ID device request the image, proving that its explicit connection request reached the lower-ID offerer. It observed one connect request and one offer, and used no cloud account or external ICE service. The exact byte count, elapsed time, signal counts, artifact checksum and image hashes are retained in [native-ci.json](verification/native-ci.json).

Visual review of the actual [Script](screenshots/01-script.png), [Characters](screenshots/02-characters.png) and [Storyboard](screenshots/03-storyboard.png) captures confirms the shared direction rails, linked names, image preview, playback layers, character gallery and storyboard word cards. The Discussion launcher clears the Generate button, direction arrowheads clear the text, and scene/speaker controls show a single menu indicator. The [capture notes](screenshots/README.md) identify the source build. These are native renders; the original design images remain separately preserved.

The required Mac job compiles both architectures and executes on `macos-15-intel`. A manual `apple_silicon_runtime` workflow input additionally executes on `macos-26`; **Apple Silicon execution has not been completed**, although its optimized binary is compiled and included. A native local transfer does not establish TURN or cross-network behavior, and screenshots do not substitute for human interaction/accessibility acceptance.

## Capacity measurements and limits

After narrowing geometry validation to actual geometry changes, the final local burst test recorded connection p95 **452 ms**, write acknowledgement p95 **1,145 ms**, observer delivery p95 **1,170 ms**, and scenario time **11.129 s**. All logical deliveries were observed. The report retains earlier checkpoints (including the slower batched run); these short local runs are noisy and do not establish a production performance guarantee.

The test sends one presence update per connected client. It does not simulate 500 sustained moving cursors, real wide-area network latency, production Cloudflare billing, or an unlimited editing rate. The earlier aspirational 500 ms p95 target is **not established** by this burst benchmark. See [backend verification](backend-verification.md) for the exact test and limits.

## Account-bound release gates

The following require deployment inputs or a real user's runtime/account and have **not** been claimed as tested:

- Production Cloudflare routing, D1/R2/DO provisioning and recovery/backup drill.
- Actual GitHub OAuth authorization and native callback on a user's Mac.
- Stripe test-mode and live-mode checkout/portal/webhook delivery in the intended account.
- TURN-only transfer between Macs on separate networks.
- ChatGPT sign-in and a real image generation through the installed local Codex runtime.
- Developer ID signing, Apple notarization and Gatekeeper verification of the distributed download.
- Extended human interaction/accessibility review on both Mac architectures and supported OS versions.

The [deployment handoff](deployment.md) gives exact configuration, packaging and smoke-test steps. These gates are separate from the already runnable local core/cloud tests; completing them is necessary before advertising a production release.
