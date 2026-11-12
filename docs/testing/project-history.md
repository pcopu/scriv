# Local history review journey

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

`tests/e2e/journeys/project-history.mjs` covers the read-only portion of IJ-03 through the actual automation-enabled Catalyst app. This is a source-level read-only review specification, not a claim about restore or cross-restart durability.

The journey imports a synthetic local project, edits its focused text view, saves, and opens Script history. It reviews the default prior revision, returns to Changes, closes, repeats, then switches projects and reopens the saved project before reviewing again. Full saved packages are compared during review; the complete loaded model and date-bit witness are compared after dismissal.

The preview oracle requires the snapshot-only count summary to be absent in Changes, present in Revision preview, and absent again after returning to Changes. Project title, scene title, and the original read-only entry must share the summary's detail subtree. This avoids mistaking the added-entry Changes card for the revision preview, and would fail if the detail-tab callback did not rerender the content.

The test never selects Restore or uses a private alert action. Arbitrary table-row revision selection, restore confirmation/cancellation, restored-state undo/redo, remote history, malformed journals, and restart recovery remain uncovered by this journey. Source links and runtime acceptance are recorded separately.
