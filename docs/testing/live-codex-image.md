# One real Codex image: blocked scaffold

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

`tests/live-e2e/codex-image.mjs` is intentionally **not an implemented live image test**.
It validates opt-in attestations and exits nonzero with `BLOCKED`, always before
launch, connection, authentication, or generation. No flag bypasses this stop.
It does not create an image, use mocks, inspect credentials, or call a provider.
It must remain outside default test discovery and CI. A blocked result is not a pass.

The companion `codex-connection.mjs` is the separate real connect/disconnect lane.
Its connection result cannot establish image-generation support. The broader
matrix and isolation rationale are in `live-codex-image-plan.md`.

## Required approvals and isolation

Before any future live image execution, establish all of the following:

- An automation-only Catalyst build with `SCRIV_CLI_AUTOMATION`, launched by
  `ScrivSession` with `--scriv-cli --screenshots`, a fresh run UUID, and its private
  app-created verification root. Never use a production project or user images.
- A separately owned real Codex app-server at an unused numeric loopback endpoint,
  with verified executable/version and process ownership. No discovered existing
  user server, managed helper, public bind, or process-wide kill.
- Fresh synthetic runtime HOME, CODEX_HOME, working directory and temporary
  directory, and a verified isolated credential backend (or separately authorized
  OS test account). CODEX_HOME alone does not prove Keychain isolation. Do not copy
  authentication files. Authentication is a separate approved operation, completed
  outside captured UI/evidence. This scenario must not sign in or sign out.
- A dedicated approved test identity, image entitlement/model support, sufficient
  approved quota, optional telemetry disabled through documented runtime settings,
  and verified standard service rather than Fast/priority configuration.
- Explicit permission for exactly one usage-producing synthetic image request,
  including a finite approved budget and currency. A one-turn counter is not a
  monetary spending cap: establish that this request fits the approved included
  quota or supported cost boundary before submitting. Do not add billing, purchase
  a plan, change service/model, or retry to overcome a quota error.
- Scriv cloud remains signed out. No reference assets, personal script, portraits,
  account emails, tokens, login URLs, raw RPC responses, or unrelated diagnostics
  are included in evidence.
- Both the legitimate shared-filesystem artifact path below and the versioned
  read-only evidence capability below are available and verified **before** the
  Generate control is activated. Attestation strings alone are not proof.

The scaffold inherits all required settings from `codex-connection.mjs`:
`SCRIV_E2E_APP`, `SCRIV_LIVE_CODEX_ENDPOINT`,
`SCRIV_LIVE_CODEX_EXPECT_ACCOUNT=authenticated`, and affirmative (`yes`) values
for `SCRIV_LIVE_CODEX_ALLOWED`, `SCRIV_LIVE_CODEX_ISOLATED_RUNTIME`,
`SCRIV_LIVE_CODEX_VERIFIED_CREDENTIAL_BACKEND`,
`SCRIV_LIVE_CODEX_TELEMETRY_DISABLED`, `SCRIV_LIVE_CODEX_STANDARD_SERVICE`,
and `SCRIV_LIVE_CODEX_DEDICATED_TEST_IDENTITY`.

Additional image attestations are `SCRIV_LIVE_IMAGE_ALLOWED=yes`,
`SCRIV_LIVE_IMAGE_CAPABILITY_VERIFIED=yes`,
`SCRIV_LIVE_IMAGE_USAGE_APPROVED=yes`, and
`SCRIV_LIVE_IMAGE_SHARED_ARTIFACT_ACCESS_VERIFIED=yes`.
`SCRIV_LIVE_IMAGE_MAX_TURNS` must equal `1`.
`SCRIV_LIVE_IMAGE_BUDGET_LIMIT` is a nonnegative decimal amount (zero only for
approved included quota), and `SCRIV_LIVE_IMAGE_BUDGET_CURRENCY` is its three-letter
currency. Do not set these flags merely to get past validation.

## Artifact boundary: no network image import

`CodexController.generateImage` creates `Generation/<job UUID>` inside the app's
verification root and sends that exact directory as `thread/start.cwd` with
`approvalPolicy=never` and `sandbox=workspace-write`. The turn asks the runtime to
write an image there. On completion, Scriv accepts eligible readable local image
files inside that directory, bounded to 25 MiB. `completeJob` records the artifact
relative path/hash, and `WorkspaceStore.attachImage` reads those local bytes and
imports them into the project before `markJobAttached` records the output image ID.

The manual WebSocket connection does **not** transfer image bytes into the app.
A runtime-only output path, remote host, or otherwise inaccessible output cannot
satisfy this flow. The external runtime must legitimately access the same exact
app-created job directory, and the app must read the result under its existing
sandbox. This is a prerequisite to verify on the authorized host, not a proven
blocker on every host. An image outside that root is deliberately rejected.

Do not bypass entitlements, helper identity checks, permissions, or sandbox policy;
do not copy a runtime image into place as test injection. If the authorized runtime
cannot share that directory, stop before a billed turn. A separately reviewed
supported transfer design or approved isolated runtime arrangement is needed.

## Minimal read-only evidence request (not currently implemented)

Ask the driver owner for a versioned capability advertised by `capabilities`, with
an exact schema and command name agreed before implementing the scenario. This
document does not claim an `image-evidence` command exists.

The extension must be compiled only in the automation driver. It must derive paths
from this run's verified root, accept no caller-supplied paths, reject symlinks and
unsafe traversal at every path component, bound file counts/bytes and decoding
cost, and perform no writes, generation, attachment, repair, or controller actions.
Missing or malformed evidence must fail closed. Return only:

- Run ID and sanitized journal records for this synthetic run: job ID, terminal
  status, project/cue IDs, output image ID, whether thread/turn IDs exist (not their
  raw content), and stored artifact SHA-256. Do not export prompt/error text or
  the full journal/installation identity.
- Verified generated-file SHA-256, byte count, and decoded pixel width/height.
  Resolve only the journal's bounded run-owned artifact; compare the computed hash
  to the stored hash. A filename or image header alone is insufficient.
- For the persisted target cue's image asset, validated SHA-256, byte count, and
  decoded dimensions, tied to persisted project/cue/image IDs. Cross-check the
  normal `persisted-projects` export; do not substitute an in-memory project.
- An observation of the actual visible `preview-picture` image: selected project,
  cue and asset identity, decoded image dimensions, and visible nonempty frame.
  Verify this is the loaded image, not a placeholder or stale previous preview.
  Capture a synthetic-only UI screenshot separately if supported; raw image bytes
  and account settings screenshots are unnecessary for this evidence API.

## Remaining one-submit scenario implementation

After the evidence API and artifact path are available, implement and review:

1. Verify capabilities and version before any usage-producing action. Create a
   uniquely named synthetic project and one cue through normal UIKit controls.
   Confirm its persisted identity, no existing images/jobs, and cloud signed out.
2. Use Command-comma, `scriv.settings.codex`, the `Saved loopback server address`
   field and `codex-connect` (Connect to this address). Never use `codex-check`,
   which prepares the managed helper. Observe account/model readiness, then use
   `codex-stop` to Disconnect and prove readiness cleared and owned listener alive.
   Reconnect through the same manual controls and verify fresh readiness. Close
   settings without exporting its identity-bearing snapshot.
3. Select the synthetic cue in the real workspace. Set
   `generation-optional-direction` to: “One blue paper triangle on a plain white
   tabletop. No people, text, logos, or reference images.” Review the actual request
   via `generation-review-brief` and verify only synthetic content is included.
   Establish selectors for project/cue creation, saving, navigation, and review
   dismissal against the real UI; do not inject model state or assume menu actions
   are already supported by the CLI.
4. Require one visible enabled `generation-generate-image` control with the exact
   intended cue target. Reserve the sole submission **before** dispatch, so an
   uncertain activation is never retried. Activate once. Observe real progress,
   then one completed job and a persisted attachment, with a bounded wait matching
   the controller's 15-minute timeout plus bounded attachment persistence time.
5. Require one new job, terminal `completed`, actual thread/turn presence, output
   image ID matching the original persisted cue, exactly one new project image,
   positive dimensions/bytes, and matching validated artifact/project hashes.
   Require the real preview to show that asset. A completed transport turn, UI
   status, stored filename, candidate image, or unattached job is not success.
6. Record only sanitized IDs, runtime/build version, run UUID, case status,
   submission count, terminal status, hashes and dimensions. On uncertain outcome,
   report it and inspect the existing job; never resubmit or announce success.
   Teardown must not silently terminate an active generation, sign out an account,
   delete evidence, or stop a process not owned by this harness.

Cancellation, transport-loss recovery, extra images, and logout/login each require
separate scope and usage approval. They are not hidden retries in this one-image lane.

## Verification status

This change is source-only scaffolding. No live scenario, provider operation,
authentication, Mac app launch, image generation, or billing was performed.
Syntax checks are not live integration coverage. The scaffold cannot pass until
its explicit implementation blockers are resolved in reviewed source changes.
