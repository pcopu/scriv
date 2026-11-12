# Script Find actual-app scenario

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Run explicitly against an automation-enabled Catalyst bundle:

```sh
SCRIV_E2E_APP=/path/to/Scriv.app node tests/e2e/script-search.mjs
```

This scenario creates two synthetic dialogue entries through the real add,
editor and Escape actions. The session owns a fresh UUID verification root;
it never opens production data or writes model/package fixtures directly.
Its read-only persistence assertions use the app's bounded `persisted-projects`
observation command, not host-side access to the app container.

## Assertions

- Opening Find focuses an initially empty native search field.
- Mixed-case search counts matching entries rather than text occurrences.
- Next and Previous navigate and wrap in both directions.
- Command-G and Shift-Command-G invoke the enabled responder commands.
- Repeated Command-F keeps Find open and retains the query.
- A missing query shows `0 results`; Next/Previous remain harmless, and
  replacing the query recovers single and multiple matches.
- Unicode query text survives native text insertion and finds the expected row.
- A single result remains `1 / 1` after Next.
- Changing the query resets the result index.
- Escape and Close hide the bar; reopening clears the query and starts at the
  first result. Both dismissal paths are repeated.
- Searching leaves all mounted scene lines present and does not alter the
  persisted script entries. This is navigation/highlighting, not row filtering.

## Baseline overlap and remaining gaps

Candidate partial overlap only:
`apps/catalyst/Tests/ScrivUIKitTests/WorkspaceEndToEndTests.swift::0008`
(`testFindMarksTheCurrentMatch`, frozen inventory).

The legacy test verifies current-match highlight colours and their removal,
including distinctions from an already selected line. The present snapshot
protocol does not expose those colours or attributed-text ranges. This scenario
therefore does **not** replace that test or certify regression equivalence.
It observes counters and mounted text, not the actual highlighted match or
pixel-level scroll destination. It also does not cover character-name/alias
search, cross-scene changes, Return delegate routing, physical keyboard event
priority, system Escape handling, menu-bar shortcuts or visual layout.

No launcher, shared adapter, inventory, retirement ledger or legacy test was
changed by this slice. Native execution must be recorded before adding passing
run evidence or including this scenario in any retirement decision.
