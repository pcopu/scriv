# JSON character-link source validation

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Candidate frozen ID:
`apps/mac/Tests/ScrivCoreTests/CharacterMentionTests.swift::0013`.
Method: `testSourceValidationRejectsStaleOverlappingMissingAndInvalidUnicodeRanges`.
Frozen source SHA-256:
`cb01be993cb6a0cb3d6835993cfb9e544404c83054283c8d4bc943dd8ccb10e5`.
The file still matches that hash. No legacy method or migration inventory is
changed by this scenario.

## Actual-app boundary

`tests/e2e/json-character-links.mjs` launches six separate automation-enabled
Catalyst app sessions. Each saves the initial synthetic sample with the actual
Command-S action, waits for the normal sample-image save to finish, then imports
and persists a valid JSON counterpart before
attempting one invalid import. Input is a complete synthetic project passed as
raw JSON text to `import-json`; the app creates its own bounded private input
file and invokes production `WorkspaceStore.importScript(from:)`. The normal
JSON decoder, `TimingEngine.validate`, `CharacterMentions.validate`, install,
and persistence paths must accept the positive fixture. No JavaScript parser,
link validator, direct store assignment, or fabricated saved result is used.

Each positive counterpart has scene `scene`, dialogue entry `line`, character
`randy` named `Randy` with alias `Rand`, and a confirmed link. Required project
metadata, explicit valid word timings, and empty image/cue/audio collections
wrap the frozen source/link fixtures so the real project importer can use them.
The scenario compares every saved model field except the project identity,
creation/modification dates, and cloud identity that production import resets.
The accepted text must also appear in the actual script view.

## Frozen assertions and exact inputs

The original valid `Randy waits.` link is accepted in the first three sessions:
location 0, length 5, text `Randy`, character `randy`, confirmed. The six original
rejection assertions are preserved as follows:

1. Missing character: keep that link and use an empty character catalog.
2. Stale source: retain the range and character, replace link text with `Jason`.
3. Duplicate/overlap: append an exact duplicate of the existing link, including
   its ID. This reproduces the original combined duplicate/overlap fixture; it
   does not claim separate proof of overlap rejection for distinct IDs.
4. Invalid Unicode range: entry `🙂 Randy`, link location 1, length 1, text `x`.
   A valid counterpart first imports location 3, length 5, text `Randy`.
5. Overflow-sized range: the same `🙂 Randy` entry, with both location and length
   equal to Swift's 64-bit `Int.max`, and link text `Randy`. The raw nested JSON
   contains `9223372036854775807` twice. These digits are never converted to a
   JavaScript Number, avoiding a rounded out-of-range decoder rejection that
   would fail to test the intended production range validator.
6. Canonical-equivalent source mismatch: entry is decomposed `e\u0301`, link
   range is location 0 and length 2, but link text is precomposed `\u00e9`.
   The positive counterpart first accepts the exact decomposed source spelling.
   Assertions verify the distinct Unicode code points rather than normalizing.

The fixed IDs replace incidental generated IDs only. Positive Unicode
counterparts add fixture-validity proof; they do not claim additional frozen
migration credit. JavaScript assertions check the hand-authored inputs and
saved outcomes, not a reimplementation of the Swift validation algorithm.

## Rejection evidence and isolation

For every invalid import, the semantic command must report
`{ dispatched: true, projectChanged: false }`. That response alone is
insufficient: a stable attached public UIAlertController must contain exactly:

> Character links must preserve exact, non-overlapping script ranges and refer to existing characters.

The public controller must be titled Scriv with one enabled OK action and no
presentation/dismissal transition. Workspace tabs must be disabled/non-hittable;
the accepted project remains mounted. This is controller presentation metadata,
not rendered labels, pixels or accessibility reachability. Alert state and every
saved project field are observed twice, with no mutation retry or extra package.
Package comparisons are sorted by ID rather than depending on directory order.
The scenario observes saved project metadata, not a byte-level comparison of
history or asset directories.

There is one invalid import per fresh session, so no alert dismissal is needed.
The Library Validation-blocked native AppKit accessibility commands are never
called, even for observation. There is no retry or bypass of that blocked
adapter. Session closure terminates only the scenario's owned app.
