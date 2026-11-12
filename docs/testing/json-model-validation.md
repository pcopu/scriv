# Actual-app JSON model validation

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

```sh
SCRIV_E2E_APP=/path/to/ScrivAutomation.app node tests/e2e/journeys/json-validation.mjs --group model
```

Independent frozen-source audit confirmed all assertions in Timing::0010 and CueAnchoring::0006/0013; those three methods are now retired.

## Genuine import boundary

The scenario submits only `{ "text": "raw synthetic JSON document" }` to
`import-json`. The automation adapter creates its bounded private `Import.json`
file using the isolated import safeguards and calls the same
`WorkspaceStore.importScript(from:)` entry point used after the real document
picker. No runner path, external file, account, credential or network request is
supplied. The runner never writes into the app's container.

The production importer uses `ScrivJSON.decoder`, calls
`TimingEngine.validate` on the decoded project, resets project ID, cloud ID,
revision and timestamps, validates again, then installs and normally saves the
accepted project. A validation failure is caught by production code and sent to
the real `WorkspaceErrorPresenter`. A `projectChanged: false` response alone is
**not** a pass.

Each invalid case gets a fresh real app session. The scenario first imports the
corresponding valid JSON, requires a new project identity, exact authored payload
in its saved package, and the mounted workspace title. This preserves the
successful validation performed by the original anchor fixture. It then imports
the invalid copy, requires the exact error in a stable attached public
UIAlertController titled Scriv with one enabled OK action, and compares the full
saved project set twice. Workspace tabs must be blocked and the accepted project
title unchanged. This is public controller presentation state, not pixels or
accessibility reachability. The original rendered-label assumption failed on
Catalyst and is not claimed. See public-alert-observation.md for diagnosis.
No private store error, native helper, handler invocation or mutation retry is
used. Each invalid document has its own fresh app session.

This is semantic document import coverage. It does not claim OS picker,
security-scoped external access, pointer/keyboard-event, alert-dismissal,
screenshots/pixel layout, cold reopen or exhaustive invalid-model coverage.

## Frozen baseline

Commit: `4d14b29f4fb49891e850fa9a8e5742dc878603c8`.

- `apps/mac/Tests/ScrivCoreTests/TimingTests.swift` SHA-256:
  `26b6b40639a22d73269ab511e4d7472d63001f0df2adb1cb9dfc568936ffca9e`.
- `apps/mac/Tests/ScrivCoreTests/CueAnchoringTests.swift` SHA-256:
  `bd5c8bb7516f83e4ca54cf72599e792165a729818a8873ffabd6a5e7f7c920c4`.

IDs are taken from the frozen inventory, not the shifted working-file order.
In particular, the orphan/duplicate method is `TimingTests.swift::0010`, not
`::0009`.

### TimingTests.swift::0010

`testOrphanCueAndDuplicateWordAreRejected`, frozen lines 81–88, contains two
rejection assertions on independent `ScrivProject.example()` instances.

1. Change `cues[0].sceneId` to `"missing"`. Require the real error
   `An image cue refers to a missing scene.`
2. Change `entries[2].words[0].id` to `entries[0].words[0].id`. Require
   `Word identities must be unique throughout the project.`

The scenario obtains the sample's exact authored text, timing and random word
IDs from the actual app's saved startup sample. Isolated CLI startup has 18
entries, 19 cues and zero installed images. The scenario asserts that actual
saved baseline and prepares a JSON copy without external asset dependencies.
The original saved sample is retained and compared exactly after each import.

### CueAnchoringTests.swift::0006

`testInvalidAnchorsAndUnanchoredOverlapRejected`, frozen lines 68–77, contains
four independent invalid mutations of the valid shared fixture:

1. Parent anchor entry ID `"missing"`: require
   `An image's resolved timing must match its source-owned script anchor.`
2. Parent anchor offset `1000`, equal to entry `a`'s owned duration: same exact
   production anchor error.
3. Remove parent `authoredDurationMs`, retaining its anchor: require
   `Image timing needs both its source anchor and authored extent.`
4. Remove both parent anchor fields, retaining its 0–2500 ms projection and
   the anchored child at 1000–2500 ms: require
   `Overlapping image cues need source-owned script anchors.` The rejection
   occurs when the child overlaps the preceding legacy parent's coverage.

### CueAnchoringTests.swift::0013

`testLegacyOrMidSceneZeroProjectionIsInvalid`, frozen lines 137–143:

1. Set parent `endMs = startMs` (both zero), preserving the anchor.
2. Keep that zero projection, remove both parent anchor fields.

Both require the exact error
`Image cues must have positive coverage inside the scene.` The scene is still
4000 ms long, so neither case qualifies for the valid dormant anchored cue at
the scene's terminal boundary. The second JSON document includes both the
first mutation and the subsequent field removals, matching the original method.

## Exact anchor fixture and decoding differences

The literal JSON fixture represents the state **after** the original fixture's
`CueAnchoring.materialize` call:

- Scene `s`, title `Untitled scene`, order 0; project title `Untitled`.
- `a`: direction `Watch the road`, order 0, owned 1000 ms, coverage 2500 ms,
  no words.
- `b`: dialogue `Move me`, order 1, owned 1000 ms, word endpoints
  `[0, 666, 1000]`.
- `c`: dialogue `Stay here`, order 2, owned 1000 ms, word endpoints
  `[0, 500, 1000]`.
- `d`: dialogue `Then leave`, order 3, owned 1000 ms, word endpoints
  `[0, 444, 1000]`.
- Dialogue coverage is zero; all entries use the original default purple.
- Parent: ID `parent`, label `Parent`, 0–2500 ms, anchor `a` offset 0,
  authored duration 2500 ms.
- Child: ID `child`, label `Child`, 1000–2500 ms, anchor `b` offset 0,
  authored duration 1500 ms.
- No characters, images, audio assets or clips; audio volume 1.

Only originally generated project/word identities and timestamps become fixed
synthetic constants in the input. Production import regenerates project-level
identity/timestamps as designed; comparison excludes those envelope fields but
requires every authored payload field unchanged. Missing optional anchor values
are omitted in JSON, decoding to the original Swift `nil`.

`ScriptEntry`'s synthesized Codable decoder does not call its memberwise
initializer: it does not clamp duration, expand direction coverage or generate
words. The fixture therefore explicitly includes the original word intervals.
Import also does not materialize legacy cue anchors; supplying a legacy
overlapping fixture and expecting automatic repair would exercise the wrong
branch. These scenarios supply the exact post-materialization anchors, then
alter only the fields named in the frozen methods.

JSON cannot encode NaN or Infinity under the production decoder's default
strict numeric policy. Thus this boundary cannot retire the complete
`AudioTrackTests.swift::0003` nonfinite-volume method or model-operation tests
that require nonfinite inputs. Image lineage and generation-prompt validation
assertions embedded in larger edit/cloud methods also remain separate: JSON
rejection alone cannot replace their other assertions.

## Source references and checks

- Production import: `apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift`,
  `importScript(from:)`.
- Real validation: `apps/mac/Sources/ScrivCore/TimingEngine.swift`, `validate`;
  `apps/mac/Sources/ScrivCore/CueAnchoring.swift`, `validate`.
- JSON/model decoding: `apps/mac/Sources/ScrivCore/CloudModels.swift`,
  `ScrivJSON`; `apps/mac/Sources/ScrivCore/Models.swift`, `ScrivProject.init(from:)`.
- Actual error UI:
  `apps/catalyst/ScrivUIKit/Shared/WorkspaceErrorPresenter.swift`.
- Isolated import and observations:
  `apps/catalyst/ScrivUIKit/Automation/ScrivCLIImport.swift` and `ScrivCLI.swift`.

Portable checks:

```sh
node --check tests/e2e/journeys/json-validation.mjs
node tests/e2e/journeys/json-validation.mjs --group model --list-cases
```

The fixture-only command checks JSON syntax/bounds and case mapping. It never
launches the app or claims the production validation branch passed. These portable checks are distinct from the recorded native pass.
