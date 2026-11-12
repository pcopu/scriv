# Additional project-validation import oracles

Status: source specification; no public execution attestation.

## Integration and common oracle

Import `projectValidationExtensionTests` from
`json-project-validation-extension.mjs` into the existing IJ-02 JSON validation
table and run each entry with the unchanged `runJSONValidationCase`. The group
is `project-validation-extension`. These are six rows in one existing journey,
not six scripts or wrappers around Swift tests. Each row owns a fresh actual
app, because the public alert cannot currently be dismissed by a supported
interaction. Do not share an alert-bearing session or clear an error silently.

The shared runner first imports the valid counterpart through `import-json`,
then requires a new app-generated project ID, a visible mounted workspace,
exact saved authored payload, reset revision/cloud identity/timestamps and an
unchanged original startup package. It then submits the invalid copy, requires
`{ dispatched: true, projectChanged: false }`, the exact error below in an
attached public `UIAlertController`, the same mounted project title blocked by
the alert, and the entire saved package set unchanged on two observations.
`projectChanged: false` alone does not pass.

The production path is `WorkspaceStore.importScript(from:)` ->
`ScrivJSON.decoder.decode(ScrivProject.self)` -> `TimingEngine.validate`.
`TimingEngine.validate` invokes `AudioTimeline.validate` first, and invokes
`GenerationPrompt.validateStorage` for each image. `validateStorage` calls
`GenerationPrompt.validate` for an existing captured prompt. The successful
import validates again after its intentional envelope reset, installs, and
saves through the ordinary app path. A failure uses the ordinary error
presenter. No parallel validator is implemented in JavaScript.

Only serialized synthetic INPUT is prepared. No installed app model is assigned
or modified by the runner. Media records are metadata only: no image or audio
bytes are installed, fetched, played or opened outside the isolated run. The
string `../outside.wav` is rejected metadata, not a filesystem operation. The
historical captured generation prompts are inert synthetic document text, not
instructions to a provider or requests to run tools. No account, network or
provider access is required.

This is public controller presentation-state evidence, not pixel evidence,
physical input, alert action invocation, document-picker handling, security
scopes, audio playback, image rendering, cloud projection, native-helper access
or loaded-state reopen. Repeated persisted-package reads are not reopening.

## Frozen sources and exact assertion mapping

All IDs and line numbers below refer to frozen commit
`4d14b29f4fb49891e850fa9a8e5742dc878603c8`, not current working-file positions.
Inventory: `docs/testing/cli-migration-inventory.json`.

- `apps/mac/Tests/ScrivCoreTests/AudioTrackTests.swift`, SHA-256
  `748b5ea27f359312b8e5e4d7a48e243846b2d83ff16d354ef8380c608bc1ccd6`.
- `apps/mac/Tests/ScrivCoreTests/EditingTests.swift`, SHA-256
  `d3f69339fc5d303713696c3ae18ea21bba5882ad89f376ebf1dc18d7e8f1a1de`.
- `apps/mac/Tests/ScrivCoreTests/GenerationPromptTests.swift`, SHA-256
  `8267ff803438b95004efc43d3576e856064e239930caf454ca13e31dd074cc91`.

### AudioTrackTests.swift::0003: three new rejection rows

`testAudioValidationRejectsBrokenReferencesTrimsAndNonfiniteVolume`, lines
35–41. The positive assertion at line 36 is
`var p = project(); XCTAssertNoThrow(try AudioTimeline.validate(p))`.
The three rows preserve these exact subsequent assertions and their reset order:

- Line 38: `p.audioClips[0].sourceStartMs = 4000; XCTAssertThrowsError(try AudioTimeline.validate(p)); p.audioClips[0].sourceStartMs = 500`.
  `audio-trim` changes only `sourceStartMs: 500 -> 4000`. The asset duration
  remains 4000, so the source start is at the asset's exclusive end.
- Line 39: `p.audioClips[0].entryId = "removed"; XCTAssertThrowsError(try AudioTimeline.validate(p)); p.audioClips[0].entryId = "second"`.
  `audio-entry` changes only the entry ID to `removed`, after the trim reset.
- Line 40: `p.audioAssets[0].fileName = "../outside.wav"; XCTAssertThrowsError(try AudioTimeline.validate(p))`.
  `audio-filename` retains the valid entry and trim; only the filename changes.

Expected public error for the first two rows:

> An audio clip has an invalid source, entry, trim or volume.

Expected public error for the filename row:

> An audio asset has invalid timing, waveform or content-addressed file metadata.

The positive fixture reuses the reconciled `additional/4` input constructor
from `json-additional-cases.mjs`; that positive metadata roundtrip test is not
counted as new coverage. It is the frozen `project()` fixture at lines 5–13:

- Scene `scene`, title `Untitled scene`, order 0; project title `Untitled`.
- Dialogue `first`, order 0, text `One`, owned 2000 ms, its only word 0–2000.
- Dialogue `second`, order 1, text `Two`, owned 3000 ms, its only word 0–3000.
- Both entries have zero coverage and the default purple color.
- Asset ID `voice`; SHA-256 and filename derive from the exact 16 UTF-8 bytes
  `audio test bytes`; `.wav` suffix, byte count 16, duration 4000 ms, sample
  rate 48000, channels 2, waveform `[0, 0.25, 0.75, 1]`, original name `Voice.wav`.
- Clip ID `clip`, scene `scene`, entry `second`, asset `voice`, start 250 ms,
  source start 500 ms, duration 3500 ms, volume 1, not muted; project volume 1.
- No characters, images or image cues.

Line 37's `.nan` volume remains uncovered. Strict JSON cannot encode that
value. Writing `null`, a string, a large exponent that overflows, or raw `NaN`
would test a decoder failure, not the original model guard. These three native
rows, even if they pass, cannot retire ::0003 as a whole.

### EditingTests.swift::0012: one new lineage rejection

`testPortraitTaggingAndVersionLineageDoNotRetargetExistingCues`, lines 125–142.
Frozen lines 140–141 are:

```
p.images[0].previousVersionId = second.id
XCTAssertThrowsError(try TimingEngine.validate(p))
```

`image-lineage` imports the exact authored state after successful cue/portrait
assignment and the rejected unknown-portrait operation, before line 140. The
only invalid mutation sets `v1.previousVersionId = "v2"`, although `v1.version`
is 1 and `v2.version` is 2. Expected public error:

> An image version must refer to an earlier existing version.

The positive state retains the original full fixture, not a smaller invented
lineage graph:

- Scene `s`, title `INT. ROOM`, order 0; project title `Untitled`.
- `note`: direction `Keep watching`, order 0, owned 0, coverage 2500, no words.
- `a`: dialogue `One two`, order 1, owned 1000, word endpoints `[0, 500, 1000]`.
- `b`: dialogue `Three four`, order 2, owned 1000, endpoints `[0, 555, 1000]`.
- `later`: direction `Look away`, order 3, owned 0, coverage 1000, no words.
- `c`: dialogue `Five six`, order 4, owned 1000, endpoints `[0, 571, 1000]`.
- Dialogue coverage is zero; all entries use default purple.
- Character `person`, name `Person`, empty aliases/biography/appearance, blue,
  portrait `v2`, no portrait region.
- Image `v1`: version 1, filename `v1.png`, 64 `a` hash characters, 12 bytes.
- Image `v2`: version 2, filename `v2.png`, 64 `b` hash characters, 12 bytes,
  predecessor `v1`, tags `["person"]`.
- Image `branch`: version 2, filename `branch.png`, 64 `c` hash characters,
  12 bytes, predecessor `v1`, no tags.
- Each image has MIME `image/png`, empty manual prompt, absent captured prompt
  and absent character analysis. Only originally generated dates are fixed.
- Cue `first`: 0–1000 ms, image `v1`; cue `second`: 1000–3000 ms, no image.
  Both have empty labels/prompts and absent anchor/authored-duration fields.
  The frozen setCueImage/setPortrait operations validate but do not materialize
  anchors. No audio assets or clips; audio volume 1.

The positive import proves that this already-authored valid state is accepted.
It does not execute or replace the operations/assertions at lines 132–139:
portrait/tag assignment, cue non-retargeting, imageVersions traversal, or the
atomic unknown-portrait rejection. Those remain required before whole-method
retirement, independent of this stronger import-rejection package oracle.

### GenerationPromptTests.swift::0007: one new captured-prompt rejection

`testEachImmutableVersionKeepsItsOwnSnapshotAfterScriptChanges`, lines 99–117.
Frozen lines 115–116 are:

```
project.images[1].generationPrompt = String(repeating:"x",count:30_001)
XCTAssertThrowsError(try TimingEngine.validate(project),"Final actual assets must pass the same bounds, even after model completion")
```

`captured-prompt` imports the complete authored state at line 110, where the
original test calls `try TimingEngine.validate(project)` successfully. It
changes only the second image's captured prompt to exactly 30,001 ASCII `x`
characters. Expected public error:

> The complete image-generation prompt exceeds 30,000 UTF-16 characters. Shorten this cue's source or visual direction before starting a new generation; captured prompts will not be truncated.

The positive fixture preserves:

- Project ID input `project`, title `Untitled`; scene `scene`, title `Room`.
- Entry `entry`, dialogue `New scene words.`, owned 1000 ms, order 0, coverage
  0, purple, literal word endpoints `[0, 214, 571, 1000]`, no speaker/links.
- Cue `cue`, empty label, 0–1000 ms, manual direction `Wide shot`, still image
  `v1`, no anchors. The second image is not silently assigned to the cue.
- Images `v1` and `v2`, filename 64 `a` characters plus `.png`, same 64-character
  `a` hash, MIME `image/png`, byte count 100, no character tags or analysis,
  exact frozen image timestamp 1,800,000,000 seconds (1,800,000,000,000 JSON
  milliseconds). `v1` is version 1 with manual prompt `Close-up`; `v2` is
  version 2 with predecessor `v1` and manual prompt `Wide shot`.
- Two independent literal historical prompt snapshots: exact instruction
  prefix from frozen line 15 followed by the cue-scoped source output at lines
  101 and 106. They retain `First words.` / `Close-up` and
  `New scene words.` / `Wide shot`, respectively, with all section labels,
  quotation marks, Unicode em dashes, blank lines and no trailing newline.
  The original image's text is not regenerated from the later script.

These fixed strings are fixture data, not a copy of GenerationContext's
algorithm. Frozen source reference for their format:
`apps/mac/Sources/ScrivCore/GenerationContext.swift` SHA-256
`ed8020e3359a9563ca7d27457f429214cf2e4a3670eed8b4936a824d4548b837`.
Frozen `GenerationPrompt.swift` SHA-256:
`d66db12124f09b9c33f8bf7aa1c268e502f65af6befc38db8b566b6e6fc40c49`.

The row does not build context, generate versions, contact a provider, or
exercise CloudCodec projection. Saved historical snapshots cannot replace the
cloud item equality assertions at lines 112–113 or the contextual comparison at
line 114. The complete method remains partially covered.

### GenerationPromptTests.swift::0004: exact UTF-16 boundary input

`testFullEffectivePromptUsesUTF16NotGraphemesAndIncludesWrapperBudget`, lines
59–68. Frozen input at line 60 is `String(repeating:"😀",count:15_000)`.
Positive line 62 is `XCTAssertNoThrow(try GenerationPrompt.validate(exact))`;
negative line 63 is
`XCTAssertThrowsError(try GenerationPrompt.validate(exact+"a"))`.

`utf16-prompt` transports that exact value inside a valid synthetic image and
empty project. The image container uses the frozen `image()` helper's metadata
semantics: ID `image`, 64 `a` characters for hash and `.png` filename, version
1, MIME `image/png`, 100 bytes, manual prompt `Manual direction`, no tags,
1,800,000,000,000 timestamp. The original two assertions had only a String
argument; this transport container is additional and is not claimed as an
original whole-project fixture. The invalid copy appends exactly one ASCII `a`
to the captured prompt. The public error is the same prompt-length error quoted
above.

The production call to `GenerationPrompt.validate` is the same function and
exact String argument as lines 62–63, now reached through actual document
import and image-storage validation. It does not reach
`GenerationPrompt.validateBeforeGeneration`, its conservative image metadata,
version increment, or provider-start boundary. The wrapper-budget cases at
lines 66–67 remain uncovered. The JavaScript code-point and UTF-16 count checks
reconcile input only; they are not native evidence for Swift's String-count
assertions at line 61.

The exact valid prompt contains 15,000 Unicode scalar values, 30,000 UTF-16
units, and 60,000 raw UTF-8 bytes. The full serialized document is 60,563 bytes;
the invalid document is 60,564 bytes. Both fit the existing 65,536-byte
`import-json` semantic boundary, so that limit must not mask the intended
production validator. The listing reports raw nested document bytes, not the
outer CLI JSON envelope's escaped character count.

## Remaining audit limits

The remaining frozen direct rejection sites for TimingEngine.validate,
AudioTimeline.validate and GenerationPrompt.validateStorage were compared with
the existing eight model cases, six character-link cases and five acceptance
cases. This extension does not repeat those invalid cases. It adds no broad
invented invalid-schema matrix and assigns no legacy credit to unasserted
branches.

Other contracts cannot be faithfully substituted here:

- GenerationPromptTests::0005 lines 76/79 validate a compact individual image
  of exactly 65,536/65,537 bytes. A complete project containing either image
  cannot fit the CLI's 65,536-byte document limit. Its 402/403-character tag IDs
  also exceed the full project's item-ID policy. Import rejection would not
  preserve the original storage-boundary success/rejection pair. No fixture is
  truncated, limit increased, or alternate injection route added.
- GenerationPromptTests::0006 includes pre-generation metadata sizing,
  inherited tags and Int.max increment overflow. Those operations are not
  performed by import. Escaped/multibyte oversized documents can fail at the
  import envelope before reaching storage validation. No equivalent claim.
- CharacterImageAnalysisTests::0011 calls analysis application on detections,
  including Infinity and atomic project equality. Importing a hand-authored
  annotation would reach a different API and omit detection/application and
  stale-state behavior. It is not a replacement.
- Editing/word/cue operation rejection tests exercise mutation transactions,
  ownership repair or in-memory preservation. Importing already-invalid JSON
  cannot replace those operations even if a later validator guard is shared.
- Successful codec-only default assertions and full-project roundtrip equality
  must keep their own default/reopen oracles. JSON import intentionally resets
  project ID, revision, cloud identity and root dates. This module excludes
  only those envelope fields for accepted authored-payload comparison, then
  separately checks the required reset behavior. It does not claim exact input
  envelope roundtrip or IEEE Date-bit preservation.

No mixed old method covered by these six rows is eligible for retirement on
these results alone, including after a successful native run.

## Portable and native gates

```
node --check tests/e2e/journeys/support/json-project-validation-extension.mjs
node tests/e2e/journeys/support/json-project-validation-extension.mjs --list-cases
```

The module checks lossless JSON input serialization, exact mutation and no
collateral field changes, unique case keys, expected case count, no cloud ID,
and both input byte counts. It lists IDs, frozen assertion lines, exact public
errors, production validator paths, explicit partial status and native status
`false`. This command cannot launch the app and does not implement a validator.

After integrating the table into the existing IJ-02 runner, a matching real
Catalyst automation app must pass all six fresh sessions and valid counterparts.
Record the exact integrated source and executable hashes, full native result,
and any new failure before claiming actual-app coverage. No native run was
performed by this Linux worker. A mismatch is a failure to investigate, not a
field to normalize or an old assertion to drop. No commit or push was made.
