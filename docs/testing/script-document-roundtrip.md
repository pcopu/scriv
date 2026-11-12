# Prepared document roundtrip journey

**Native status: NOT RUN.** This adds authored CLI scenarios and source/assertion
navigation, not a passing native result, measured execution or baseline retirement.
No production source or existing witness is changed.

`tests/e2e/journeys/script-document-roundtrip.mjs` is one isolated native process
with 21 named behavioral phases, plus catalog launch/close steps. It uses only
existing public `ScrivSession` commands and mounted UIKit controls. The new
catalog has 23 steps, 182 public-method-plan actions, 28 expectations and one full
ordered action sequence. Its 39 mapping declarations deduplicate to 17 links.
The incremental proposal has 12 bounded contracts related to audited v82 ranges;
it does not replace the complete proposal or recertify its broader claims.

## Exact behavior prepared

- Import a BOM/CRLF document with a multiline mixed-case title and opening
  metadata. A leading timing annotation without an entry is ignored. A forced
  action preserves scene-looking text, an `@` line and a literal annotation.
- Check five exact saved entries, three ordered scenes including an empty middle
  scene, one reused Mara identity and an unspoken parenthetical. Annotation
  boundaries include duration zero, negative/noninteger values and values above
  the duration/coverage maxima. The two-word zero-duration dialogue owns 2 ms.
  `Return now.` owns 1800 ms with the exact weighted boundary at 1079 ms.
- Check that only the 3302 ms first scene gets a cue. The empty and zero-owned-time
  scenes do not. Check complete supported payload and generated identity
  uniqueness, not just substring presence or an import completion flag.
- Export twice with byte-for-byte literal UTF-8 oracles and successful production
  temporary cleanup. Reimport the actual capture and export it twice again.
  New document/item IDs are expected. This is supported script-content parity,
  not lossless preservation of every Scriv field in Fountain.
- Import a JSON copy with an explicit `Nightwatch` alias, a new title, revision17
  and fixed old created/modified dates. The output must reset to revision0, a new
  ID and equal dates within the measured synchronous import call window (allowing
  1 ms rounding). Only documented import identity/date/revision fields may change. Find separately
  by source text, speaker name, alias, no-match and an empty query. Name/alias
  strings are absent from entry text, so the fallback branch is necessary.
  Every variant performs Next twice and Previous twice with exact counts.
- Close a nonempty Find with both Close and Escape, reopen empty and compare
  every saved package plus loaded project and exact Date storage witnesses.
  Clearing the query through the public text command still requires native
  confirmation; the prepared test fails if UIKit does not deliver that change.
- Reject `../outside.fountain` before import. Its leading dot is the first
  rejecting filename predicate; later slash/control-character predicates are
  not separately exercised by this case. No alert or document change is allowed.
- Import/export metadata-only and plain-opening-colon boundary documents. Check
  their complete payloads and exact exports, then verify all six saved packages.

## Actions, polling and limits

Catalog actions are exact public method call plans with explicit bindings,
repeated operations and polling descriptions. They are **not fixed wire command
logs**. Each `session.waitFor` repeats `snapshot` at 50 ms until the named
predicate passes or its 15-second deadline expires. Saved-project polling reads
at 75 ms and retries only the exact initial-publication-pending error. Individual
command timeouts can extend wall time. Mutation commands are never retried.
Targets are fresh observed paths; no conditional scrolling is hidden in helpers.
The runner checks its declared call-description order at each phase. It does not
integrate Tracer's runtime capture adapter or claim a callback execution record.

Native document pickers, physical key delivery, Find-field Return, external
export destinations/cancellation, app relaunch, draft recovery, editing/undo,
alias editing UI, cloud leases and full parser/schema parity remain excluded.
The semantic import route accepts bounded UTF-8 text, so it does not exercise the
production 16 MiB limit or invalid UTF-8 branches. The new suite has no mock
backend, direct implementation unit tests, model setters or production bypass.

## Discovery and verification

With a trusted installed Tracer selected in `SCRIV_TRACER_CLI`:

```sh
node scripts/tracer-cli.mjs app -- test --list --scenario journeys/script-document-roundtrip
node tests/e2e/journeys/script-document-roundtrip.mjs --list-cases
node scripts/tracer-cli.mjs scenario check --file docs/testing/script-document-roundtrip-steps.json --json
node scripts/tracer-cli.mjs proposal check --file docs/testing/script-document-roundtrip-proposal.json --json
```

An authorized future native run requires a matching automation-enabled Catalyst
bundle on macOS and source/build provenance accepted by the repository runner:

```sh
node scripts/tracer-cli.mjs app -- test --scenario journeys/script-document-roundtrip --app /path/to/ScrivAutomation.app
```

Authorship checks passed: syntax on all three new modules; no-launch manifest and
CLI discovery; catalog/proposal integrity; all 1302 existing link pins; assertion
registry integrity; `scripts/check-repo.mjs`. These checks do not run UIKit.
Independent semantic audit and hash-guarded reviewed-link integration remain
separate owner-controlled gates.

At the v82 source denominator of 30,675 included lines, the unreviewed catalog
union covers 163 included lines, of which 58 are not already manually linked.
This is a candidate calculation, not a published mapping change. The incremental
proposal covers 164 included lines because it includes one additional structural
closing line. Execution percentage remains unknown.
