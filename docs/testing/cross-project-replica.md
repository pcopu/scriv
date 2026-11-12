# Independent hosted copies across projects

Run `tracer app -- test services discussions-assets`. Twenty-four new HTTP checks
extend the prior 83 to 107 within the unchanged 110-request ceiling. Original
lines 1–399, earlier limits and footer remain exact. New setup/cleanup uses public
project and media routes, with read-only D1/R2 observation and no fixture writes.

The same independently known twelve-byte PNG-signature fixture is uploaded to two
projects in one team. Exact rows, R2 bytes/metadata and public quota confirm two
separate keys and charges. Retrying either copy as another permitted writer does
not change its attribution, key or quota. This tests signature-identified content,
not decoding of a complete PNG.

Viewer GET/HEAD reads have exact body/header checks. Outsider reads with a known
validator and viewer/member deletions are refused without changing stored state.
Deleting one project copy leaves the other exact and readable. Repeated deletion
is harmless. Reuploading uses a different key while retaining the other copy.
Sequential cleanup returns quota to zero and removes all hosted rows/objects.
Only the new project is then archived; original project/team/identity rows remain
exact, and the archived project's timestamps and public read denial are checked.

These are sequential observations, not forced internal races, delayed deletion,
R2 failure or scheduled reconciliation. Security counters and internal room state
are outside the preservation claim. Known-validator requests do not establish
general conditional-cache conformance. No native UI, real image decoding or live
provider execution. Mapping is source navigation, not measured coverage.
