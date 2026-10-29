# Build checkpoints

This branch was rebuilt as a new native Scriv application. This document preserves
the historical implementation checkpoints. The [current integration handoff](verification/current-handoff.md) identifies later source work; [verification.md](verification.md) separates historical runtime evidence from current verification and deployment gates.

## First implementation checkpoint — 2026-10-29

- Removed the inherited Movie AI Workspace implementation; its Git history remains.
- Preserved all 25 Scriv concept images and the product/timing/collaboration plans.
- Added native Swift models, timing, local project persistence, Fountain import/export,
  content hashing, cloud protocol models and a native cloud client.
- Added the Script/Storyboard UI and layered editor; remaining views are in progress.
- Added Cloudflare identity/team schema, OAuth, access control and project-room work.
- Added an encrypted WebRTC peer-media bridge and three generated sample frames.

Pending at this checkpoint: finish cross-component integration, cloud runtime tests,
Swift compilation, native visual review, billing verification and release packaging.
No service has been deployed and no payment has been created.

The final release report and deployment handoff will record actual verification results.

## Integrated implementation checkpoints — 2026-10-29

- `854a054`: replaced inherited code with the native/Cloudflare implementation foundation.
- `f424878`: preserved all 25 conversation designs and added three generated sample frames.
- `f292971`: integrated native editing, account/team/discussion UI, backend and packaging/CI.
- `beae0de`: moved away from the retiring macOS 14 runner and added real WebRTC CI tests.
- `4fce12c`: durable offline reconciliation/outbox, timing fences, complete cloud bootstrap, paginated discussion/history, source-safe media generation and native UI finishing.
- `f612e5f`: corrected app-server contracts against the official Codex 0.165.0 generated schema; first successful native universal package and WebKit smoke test.
- `03cc3d2`: immutable history recovery and the visual corrections from the three actual Mac screenshots; native build, 28 core tests, universal packaging, WebKit transfer and renders passed.
- `ee55a46`: deterministic lower-device-ID WebRTC offerer, explicit connection request, serialized SDP/candidates and higher-ID native smoke coverage.
- `0eb779b`: timeout retirement, responder renewal on a fresh nonce, and recovery after lost connect/offer/answer signals for either requester.

## Release verification checkpoint

- 28 portable Swift core tests and 24 local Workers integration tests pass.
- A real local room test accepts 500 authenticated sockets and 100 concurrent
  independent content writes; all 50,000 expected mutation observations arrive.
- All original design/sample image digests match their manifests.
- The official Codex 0.165.0 generated schema exposed concrete request/transport
  mismatches; those have been corrected and contract-checked.
- The actual Intel Mac job passed compilation, core tests, optimized universal
  packaging, native screenshot capture and a real 2,150,385-byte WebKit transfer.
  Visual review produced a small control-placement correction; the final build
  includes that correction and additional history/reconnect regression tests.
- Browser CI exposed an intermittent initial-negotiation race. The transport now
  uses a sole deterministic offerer, queues early ICE candidates, and renews both
  sides on a fresh connection attempt. All six final browser tests pass, including
  25 simultaneous/staggered scenarios under CPU throttling and five lost-signal
  recovery cases in the local stress run.
- The current source map, architecture, cloud setup and deployment runbook now
  describe the implemented Cloudflare/$9.99-per-team product.

See [verification.md](verification.md) for the final test state rather than treating
any individual work-in-progress commit as a production release.

## Final source verification and handoff

Runtime commit `0eb779b8e07935235d4584b09abe05bd0504be01` passed all three jobs in
[run 40921544866](https://github.com/pcopu/scriv/actions/runs/40921544866): cloud,
real-browser peer transport, and native Mac. The Mac job built the universal app,
ran the higher-ID-requester WebKit smoke test, and captured the three actual
views. The final documentation-only checkpoint preserves those captures, artifact
checksums and test evidence. Production configuration, account-bound acceptance,
Developer ID signing and notarization are recorded in the deployment handoff.
