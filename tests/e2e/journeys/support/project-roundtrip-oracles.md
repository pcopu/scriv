# Loaded-project roundtrip oracle

Status: source specification; no public execution attestation.

## Interaction and evidence

Each of two fresh, isolated actual-app runs saves the startup synthetic project,
imports one reconciled JSON fixture using the production importer, and captures
the complete loaded `WorkspaceStore.project`. The baseline is captured before
explicit Command-S, but the ordinary importer has already scheduled its initial
save. This does not pretend import preserves the input envelope.

The journey invokes normal Save, checks saved JSON, opens the project browser,
searches for the unique startup title and clicks Open project, then repeats the
browser search/Open for the imported title. The distinct loaded project ID is
checked at each transition. Entire observer outputs compare deeply before and
after, without removing ID, dates, revision, optional metadata or any payload.

`ProjectBrowserController.openSelected` calls `WorkspaceStore.openLocalProject`;
`open` flushes pending saves and uses `loadProjectForOpening`/`ProjectRepository.load`.
Repository loading decodes with `ScrivJSON.decoder` and calls
`TimingEngine.validate`. The observer does not invoke a validator or load path.
A successful different-project switch and return therefore exercises actual
production storage decoding and validation rather than repeated file reads.

`loaded-project` returns `project` (the complete production Codable model), plus
`dateReferenceTimeBits` (decimal UInt64 strings of exact Date reference-time
Double bit patterns for root createdAt/modifiedAt and every image createdAt).
The witnesses prevent a timestamp encoder from concealing precision loss. These
fixtures contain no images; image/date and cloud-present variants are not claimed.
Cloud identity's actual absence and every other optional encoded field are still
part of the full comparison. Source fixture IDs/word IDs are deterministic test
inputs; after production import, the full app-generated identity is preserved.

## Frozen assertions

- CueAnchoringTests::0008 line 89: full anchored-project roundtrip equality plus
  normal production validator on reopen. The original assertion uses vanilla
  JSONEncoder/JSONDecoder, while the real application's storage uses ScrivJSON.
  This exercises the intended full-model behavior via actual storage, not the
  exact Foundation codec API pairing. Legacy cue nil ownership remains the
  separate additional/2 case, not silently covered by this journey.
- AudioTrackTests::0004 line 44: full project equality through real ScrivJSON
  persistence/reopen, including audio asset and clip metadata. No audio bytes are
  installed, fetched or played. Legacy omissions/defaults remain additional/5;
  JSONSerialization/XCTUnwrap setup at line 45 is not an independent behavior.

A method may only be retired after native proof and reconciliation of ALL its
assertions, including those separate legacy cases. Strict JSON cannot represent
NaN/Infinity, and this journey makes no nonfinite-input coverage claim.

## Observation boundary

Only automation builds contain the command. It accepts no parameters, requires
both CLI/screenshot launch flags, the current UUID run environment, the exact
system-temp-root name and configured-root match, a private current-owner root,
and the loaded UUID package strictly at `Projects/<id>.scriv`. Descriptor-relative
no-follow opens and inode/device identity checks protect every run component.
Only the trusted system temporary prefix may resolve symlinks. It requires the
mounted workspace with no presented controller or store error. It never opens
project.json, reads arbitrary paths, mutates state, validates, or reloads models.
Errors are generic, and serialized observations are limited to 4 MiB.

## Exact native gate

1. Build the existing CLI automation Catalyst target with the authorized saved
   SDK/standalone CLI workflow. `scripts/rebuild-catalyst-cli.py` discovers the new
   Swift file through its recursive UIKit source collection. Do not invoke the
   denied native accessibility helper, install Xcode, or change production settings.
2. Set SCRIV_E2E_APP to that verified automation bundle, then run:
   `node tests/e2e/journeys/project-roundtrip.mjs`.
3. Both cases must complete their actual browser switch/reopen and exact observer
   comparison. A mismatch, including Date bits, is a failure to investigate, not
   a field to normalize. Any error/timeout stops mutations; no automatic retry.
4. Run the additional JSON cases separately with
   `node tests/e2e/journeys/json-validation.mjs --group additional` before any
   whole-method retirement claim. Preserve runner results as native evidence.

Portable checks: `node --check` on the entry and support modules, plus
`node tests/e2e/journeys/project-roundtrip.mjs --list-cases`. They reconcile input
and command authorship only, never substitute for a native app result.
