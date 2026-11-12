# Model document journeys: prepared, not run

This IJ-02 extension contains 23 independent real-app cases. Five accepted document families import a synthetic JSON document, compare every authored field against explicit expected input/defaults, require new project identity, revision zero, absent cloud identity and equal dates inside the import call window, observe saved metadata, then Save, switch to the startup project through the actual project browser and reopen. Reopened full model and exposed Date reference bits must equal the original loaded baseline. This is not cold process reopening.

Eighteen rejection cases first accept the complete valid counterpart, then change one bounded semantic condition. They require rejected dispatch, a stable public error alert, and exact preservation of loaded model/date bits and the persisted project metadata set. They do not assert history files, asset bytes or entire packages are unchanged. Decoder failures deliberately require a nonempty stable public error rather than a guessed Foundation-localized message. Every validator failure requires its exact source message.

The five accepted families are complete metadata, minimal legacy envelope, explicit-null project audio defaults, explicit-null nested optional fields, and audio upper boundaries. Required fields are never assumed to use initializer defaults. Complete includes two scenes (one empty), authored and estimated word metadata, exact decomposed Unicode source, an explicit unlink, a zero-owned direction, two image metadata versions, crop and captured prompt, anchored cue with authored extent beyond scene end, relative and absolute audio clips and mute/volume endpoints. Metadata references intentionally have no media files: no file integrity, rendered image, sound, waveform processing or playback claim.

`model-document-fixtures.json` freezes every exact input, expected authored payload and invalid input. The actual runner builds these independently from `model-document-cases.mjs`; the JSON audit artifact does not substitute for the production model. `model-document-steps.json` is a reusable declared Tracer catalog, not runtime-reported execution. `model-document-audit-contract.json` pins the complete callers, shared observers, browser helper, assertion lines and bounded candidate associations. `model-document-candidate-gain.json` reports only candidate nonblank/noncomment physical lines absent from the baseline reviewed map, not approved coverage.

There is no supported export-json command. Full saved-model observation and ordinary browser reopening are covered instead. Fountain export is lossy for these model fields and was deliberately not claimed as JSON roundtrip. Package export is not driven by this journey. No unsupported commands or security guard bypasses were introduced.

Portable checks:

- `node --check tests/e2e/journeys/model-document.mjs`
- `node --check tests/e2e/journeys/support/model-document-cases.mjs`
- `node --check tests/e2e/journeys/support/model-document-steps.mjs`
- `node tests/e2e/journeys/model-document.mjs --list-cases`
- `node scripts/tracer-cli.mjs scenario check --file docs/testing/model-document-steps.json --json`

Native future command, requiring separate authorization and a matching Catalyst bundle: `tracer app -- test --scenario journeys/model-document --app /path/ScrivAutomation.app`. The scenario is discoverable by the ordinary journey filename; no production file or shared registry is rewritten here. The merge-only registry snippet is an integration suggestion, not an applied registry update. No native results are recorded.
