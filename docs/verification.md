# Verification report

Date: 2026-10-29. This report distinguishes source implementation, actual automated results and account-bound release checks. No production service has been deployed and no real subscription or image-generation charge was created by this build work.

## Completed automated checks

| Check | Result | Environment and evidence |
| --- | --- | --- |
| Portable Swift core | **28 tests passed, zero failures** | Official Swift 6.0.3 toolchain on Ubuntu 24.04; Foundation-only core. Covers timing, direction overlap, word transfer, Fountain, crash-safe immutable history, hashes and three-way reconciliation. |
| Native source syntax | **Passed** | Swift frontend parsing of app/views/services. Syntax parsing is not a substitute for macOS typechecking. |
| Codex protocol | **18/18 checks passed** | Official Codex 0.165.0 generated JSON Schema; 15 valid fixtures plus 3 negative regressions. No login or model turn. See [contract evidence](codex-integration.md). |
| Cloud TypeScript | **Passed** | Strict `tsc --noEmit` with the pinned Worker bindings/toolchain. |
| Worker integration | **24 tests passed** | Actual local Workers runtime, D1/SQLite Durable Objects and R2 emulation. External GitHub/Stripe responses are controlled test responses. One optional load test is skipped in the normal suite. |
| Worker packaging | **Passed, dry run** | Wrangler bundle generated without deployment. |
| Room capacity | **Passed** | Separate opt-in test: 500 distinct authenticated members/WebSockets, 100 concurrent independent script writers, all 50,000 expected mutation observations and durable final sequence. |
| Browser peer transfer | **4 tests passed locally; final CI rerun pending** | Actual Chromium WebRTC channels: 750,321-byte multi-chunk transfer, forced simultaneous offers, varied request ordering, invalid/missing/unsolicited media rejection and peer reconnection. The preceding three-test suite passed CI after the negotiation fix. |
| Design fixture | **3 tests passed** | Exact accepted duration/cue/word/coverage invariants. |
| Asset preservation | **Passed** | All 25 original design images and all 3 sample frames match their stored SHA-256 manifests. |
| Shell/package source checks | **Passed** | Shell syntax, bridge JavaScript syntax and required release-file checks. |

The latest integration checkpoint is [4fce12c](https://github.com/pcopu/scriv/commit/4fce12c57198e07ecf061d2c76bb90a716115eb9). The earlier independent WebRTC CI success is in [run 40914464559](https://github.com/pcopu/scriv/actions/runs/40914464559).

## Native build and visual gate

**Passed at commit `f612e5f`:** actual AppKit/SwiftUI/WebKit compilation, 26 native core tests, optimized builds for both `arm64` and `x86_64`, universal app packaging and signature verification, packaged application launch, real WebKit peer transfer, and all three native screenshot captures. Evidence: [Intel Mac job 123599222261](https://github.com/pcopu/scriv/actions/runs/40916837672/job/123599222261).

The WebKit smoke test transferred **2,150,385 bytes**, verified byte-for-byte equality and SHA-256, and completed in **7.417 seconds**, including two fresh WebKit instances. It used no cloud account and no external ICE server. This proves the shipped WebKit bridge locally; production TURN/cross-network checks remain separate.

Visual inspection confirmed all three views render their real images, script/character links, direction rails, layers and word cards. It found a Discussion launcher covering the generation button and duplicate native/custom menu indicators. Those controls, arrow/text clearance and saved-prompt generation enablement have been corrected. The final persistence/visual/reconnection corrections are awaiting the next native build at this documentation checkpoint.

The required Mac job compiles both architectures and executes on `macos-15-intel`. A manual `apple_silicon_runtime` workflow input additionally executes on `macos-26`; that public runner remained queued during the first run, so Apple Silicon execution is not claimed as completed.

The initial macOS 14 job could not run during GitHub's published October 29 runner-retirement brownout. The workflow was moved to supported runner labels. This infrastructure correction does not establish that the native build passes; the resulting jobs must complete successfully.

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
