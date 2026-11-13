# Narrow WorkspaceStore assertion associations

This catalog connects existing public native journeys to eleven additional
source spans in `WorkspaceStore.swift`. It is a semantic source/assertion audit,
not a fresh native run, compiler counter capture or branch-coverage report.
Use `workspace-store-audited-steps.json` for exact witnesses and the proposal
file for the separately reviewed source ranges. Do not broaden these ranges to
include the gaps between them.

- Complete word-timing Save: line 1193. The plural transaction preserves the
  asserted neighboring word, text, cue and audio model metadata. Audio bytes,
  playback, singular timing edits and rejected store inputs are outside scope.
- Accepted-change journal creation: line 802. The save-failure journey observes
  exact accepted state, unchanged package bytes and one expected pending record.
  It checks content-hash syntax, not independently recomputed hash correctness.
- Cue draft retention: lines 357 and 361–365. Exact oversized text remains in
  one local draft across two owned reopens while canonical state is unchanged.
- Changed cue draft application: lines 447–450 and 452. A valid correction
  changes the prompt and one revision, allowing the observed finite
  nondecreasing modification date; the unrelated model remains equal.
- Eventual cue draft clearing: lines 481, 483–484 and 487. After observing the
  saved correction, the journey observes an empty journal and a clean third
  reopen. It does not establish deletion ordering at an unobserved failure
  window, cancellation of delayed reads or clear-generation fencing.
- Canonical script replacement: lines 1037 and 1039. Exact UTF-16 text is saved
  and displayed with unchanged captured word IDs, endpoints and timing metadata.
  This fixture does not establish full unrelated-project or authored-audio state.

The conditional rebase, unchanged save, busy retry, no-op script path and
clear-generation/read-cancellation lines are deliberately not linked here.
Other exclusions include stale contexts, denied leases, competing writers,
crash durability and production account/provider behavior. Read each catalog
step's limits before reusing its claim.

The cue-recovery assertion message and its existing catalog now describe the
observed eventual state rather than claiming an untested ordering guarantee.
That message-only correction does not change the assertion or establish a new
native result. A matching verified automation bundle and normal public CLI
journey are still required for native execution evidence.
