# Local synthetic image boundary (source draft, not native proof)

The test-build-only `import-local-image` accepts exactly one fixture token,
`coral` or `blue`. Each is a checked-in 73-byte 2 × 2 RGB PNG. There is no
caller path, URL, arbitrary byte input, filename, prompt, asset ID or model setter.
The existing asynchronous CLI lock must serialize this command with all others.
It uses the production `WorkspaceStore.importImage(from:cueId:)` boundary after
ordinary editing completion, not a duplicate attachment implementation.

The importer requires the prepared private CLI run, an owned 0700 root,
no-follow descriptor traversal, a local current project, no account/cloud
project, no generation jobs, no playback/error/modal and existing verification
analysis disablement. It writes an exclusive owned single-link 0600 fixed-name
source inside a fresh owned 0700 scratch directory. Cleanup is inode-bound and
nonrecursive. Its result reports actual production import and cleanup outcomes.
The source remains alive throughout the awaited production import. The path-based
production importer is unchanged: descriptor checks do not claim to lock trusted
container ancestors against a malicious same-user process.

`local-image-evidence` reads only current synthetic-package assets. It requires
exact digest-derived PNG filenames, exact 73-byte fixture contents, matching hash,
no-follow regular single-link owned files and actual ImageIO decoding. It does not
read generation journals or fall back to another directory. Render evidence uses
actual visible `UIKitAssetImageView` loaded digest and `UIImageView` image dimensions,
clipping and active-controller membership on the validated workspace or exact sheet surface.
This proves decoded loaded-image state and visible surface geometry, not composited
screen pixels or full occlusion analysis. Only the current workspace or its
same-store/current-context image detail sheet is permitted; other modals fail closed.

## Current actual-app journey candidate

`tests/e2e/journeys/local-images.mjs`:

- Reject unsupported input shapes without saved-project mutation.
- Import original and successor using the real post-picker importer.
- Observe exact content-addressed bytes and visible decoded preview/inspector.
- Choose the historical version using existing collection-cell and Use version controls.
- Compare every field of every saved project, preserving source, timing, other cue,
  assets and ancestry, and reopen through the real project browser.
- Require no generation jobs and no active analysis throughout observations.

Both this fixture and the frozen fixture have empty unrelated audio and character
arrays. That is not the reason for partial coverage. The current fixture instead
lacks the original overlapping anchored cues and literal per-version manual/
captured-prompt metadata. It has only partial semantic overlap with frozen
`apps/mac/Tests/ScrivCoreTests/ImageInspectorInvariantTests.swift::0001`, not full
fixture/assertion equivalence. It is not
`apps/mac/Tests/ScrivAppTests/ImageInspectorTests.swift::0001`, whose exact inspector
placement/title choice needs two concurrently placed versions and another setup.

Exact first-line import and zero-owned direction candidates
`apps/mac/Tests/ScrivCoreTests/ImageImportPlacementTests.swift::0001` and `::0004`
remain uncovered by this first replacement/version journey. Neither is retired.
Picker capture/cancel/pause, stale/race/fault branches, portrait/prompt menus,
automatic character analysis and provider behavior are not exercised.

## Validation gates

Node syntax, case enumeration and inline fixture-byte startup assertions are available without an
Apple runtime. They prove neither native compilation nor actual-app execution.
An independent read-only boundary review must pass before native transfer, followed
by a matching native build and complete journey evidence. No legacy tests or
registry entries should be removed based on this source draft.
