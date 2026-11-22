# Model Document journeys

This IJ-02 extension covers 23 document cases in the real app. Five accepted document families import a synthetic JSON document, compare every authored field against explicit expected input/defaults, require new project identity, revision zero, absent cloud identity and equal dates inside the import call window, observe saved metadata, then Save, switch to the startup project through the actual project browser and reopen. Reopened full model and exposed Date reference bits must equal the original loaded baseline.

Eighteen rejection cases first accept the complete valid counterpart, then change one bounded semantic condition. They require rejected dispatch, a stable public error alert, and exact preservation of loaded model/date bits and the persisted project metadata set. They do not assert history files, asset bytes or entire packages are unchanged. Decoder failures deliberately require a nonempty stable public error rather than a guessed Foundation-localized message. Every validator failure requires its exact source message.

A matching app runs the browser-reopen and rejection cases in one owned
session. Each accepted import adds exactly one saved
project, and the journey verifies that all earlier projects in the session are
unchanged. The rejection session uses `acknowledge-json-import-error` after
checking the presented alert. It then verifies the restored workspace and the
complete loaded model, date bits and saved projects again. Apps that do not
advertise `jsonImportAcknowledgementScope: owned-presentations` use one session per case. Set
`SCRIV_JSON_VALIDATION_ISOLATION=fresh` to measure that mode on a matching app.

The five accepted families are complete metadata, minimal legacy envelope, explicit-null project audio defaults, explicit-null nested optional fields, and audio upper boundaries. Required fields are never assumed to use initializer defaults. Complete includes two scenes (one empty), authored and estimated word metadata, exact decomposed Unicode source, an explicit unlink, a zero-owned direction, two image metadata versions, crop and captured prompt, anchored cue with authored extent beyond scene end, relative and absolute audio clips and mute/volume endpoints. Metadata references intentionally have no media files: no file integrity, rendered image, sound, waveform processing or playback claim.

`model-document-fixtures.json` freezes every exact input, expected authored payload and invalid input. The actual runner builds these independently from `model-document-cases.mjs`. `model-document-steps.json`, `model-document-audit-contract.json` and `model-document-candidate-gain.json` describe the original review of the fresh-session journey. They retain its source pins and candidate associations.

There is no supported export-json command. Full saved-model observation and ordinary browser reopening are covered instead. Fountain export is lossy for these model fields and was deliberately not claimed as JSON roundtrip. Package export is not driven by this journey. No unsupported commands or security guard bypasses were introduced.

Portable checks:

- `node --check tests/e2e/journeys/model-document.mjs`
- `node --check tests/e2e/journeys/support/model-document-cases.mjs`
- `node --check tests/e2e/journeys/support/model-document-steps.mjs`
- `node tests/e2e/journeys/model-document.mjs --list-cases`

Run the native journey with a matching Catalyst bundle using `tracer app -- test --scenario journeys/model-document --app /path/ScrivAutomation.app`. The [native capture workflow](measurement-first-coverage.md#native-capture-with-separately-pinned-journeys) gives the source and build options for measuring the run.
