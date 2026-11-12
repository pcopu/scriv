# Parallel source-to-feature categorization

This catalog answers **which feature a source range belongs to**. It is a fast
navigation and planning layer. It does not say the range was tested or executed.
The separate Tracer manual links, test-run evidence and measured execution data
remain unchanged by every command here.

## Data contract

- `feature-taxonomy.json` gives stable feature IDs and plain-language names.
- `code-feature-catalog.json` contains a pinned source inventory and contiguous
  feature ranges. Every row remains `model-proposed`, including high-confidence
  rows and those sampled by a reviewer. Confidence is the worker's estimate,
  not a verified probability.
- Each row has one primary feature, a short reason, an assignment ID, a whole-file
  hash and an exact span hash. Shared code can serve multiple features; the
  primary category is a navigation aid rather than an ownership boundary.
- Counted lines use the supplied Tracer report's included scope and its exact
  blank/comment exclusions. Categorization cannot alter that denominator.
  Every not-yet-assigned line remains visibly uncategorized.
- The inventory is explicitly a snapshot. New files are not silently added and
  changed files fail validation. Rebase onto a new source manifest and report to retain only byte-identical
  classifications; changed files become uncategorized until inspected again.

## Parallel workflow

Export the current source manifest and generate a current Tracer JSON report.
Run the preparer with paths to those files, outside the source tree:

```sh
node scripts/catalog-features.mjs prepare \
  --report /path/tracer-report.json --manifest /path/source-manifest.json \
  --out /path/feature-work --shards 8 --scope 'Exact checkpoint name'
```

The preparer validates source hashes and balances whole files across disjoint
assignments by included-line count. `--prefix PATH` can select a subsystem;
repeat it for several. The full inventory remains visible even when work is
limited to those prefixes. A worker reads only its assigned source files and
returns a JSON proposal with `assignmentId`, `model`, `ranges` and explicit
`unclassified` ranges. Range fields are `path`, `start`, `end`, `featureId`,
`confidence` (`low`, `medium`, `high`) and `rationale`. The proposal kind is
`feature-classification-proposal`, schema version 1. Workers never edit the
shared catalog, test links, source or one another's proposals.

One integration owner checks proposals and merges a meaningful batch:

```sh
node scripts/catalog-features.mjs merge \
  --inventory /path/feature-work/inventory.json \
  --taxonomy docs/testing/feature-taxonomy.json \
  --assignment /path/worker-assignment.json --proposal /path/worker-proposal.json \
  --out docs/testing/code-feature-catalog.json
node scripts/catalog-features.mjs check --catalog docs/testing/code-feature-catalog.json
node scripts/catalog-features.mjs report --catalog docs/testing/code-feature-catalog.json
node scripts/catalog-features.mjs report --catalog docs/testing/code-feature-catalog.json --feature collaboration
node scripts/catalog-features.mjs report --catalog docs/testing/code-feature-catalog.json --source cloud/src/project-room.ts --json
```

Repeat `--assignment` and `--proposal` for all completed disjoint workers. The
integrator rejects stale source, out-of-bounds or overlapping ranges, unknown
features, conflicting ownership and duplicate worker proposals. It constructs
all hashes itself, discards unsupported worker fields, and cannot promote rows
to verified status. Reviewers should sample mixed-feature files and low/medium
confidence ranges. Integrity validation cannot prove that a feature label is
semantically correct.

## Runtime and acceptance boundaries

Server code is active application code. `cloud/src/` and the update service
are separate runtime surfaces, not unused native code. Run their isolated
real HTTP journeys through `tracer app -- test services`; a Mac is not needed.
The current Catalyst app also compiles selected shared code under `apps/mac/`.
The old AppKit target and UI were explicitly retired in this checkpoint; their
source remains in recovery history. They were removed for product scope, not
to claim execution credit. Build membership and features are different concepts;
server and helper code remain in the current denominator.

Native scenarios still require the matching source-built Catalyst app and
macOS. Categorization does not clear build capacity, input-route restrictions,
stale measured evidence, missing service journeys, or any accepted baseline.
No implementation-level test suite is introduced by this workflow.

## Rebase after source integration

`rebase` compares whole-file hashes against a new manifest and Tracer report. It
retains only unchanged source ranges, drops changed or removed ones with reasons,
and records the previous catalog hash. It never updates a changed range hash
to make the old label look current. New files remain uncategorized.

```sh
node scripts/catalog-features.mjs rebase --catalog docs/testing/code-feature-catalog.json \
  --report /path/new-report.json --manifest /path/new-source-manifest.json \
  --scope "New exact checkpoint" --out docs/testing/code-feature-catalog.json
```
