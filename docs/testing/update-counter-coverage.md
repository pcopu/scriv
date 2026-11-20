# Update Worker counter capture

This opt-in test build records actual cumulative statement-entry counters around
the existing 48 public update-distribution HTTP checks. It adds six separately
counted collector requests. The normal journey still loads unchanged production
JavaScript without instrumentation.

Run only where local test writes and the installed dependencies are authorized.
Set SCRIV_TRACER_CLI to an absolute verified Tracer 0.3 bin/tracer.mjs path. Set
SCRIV_UPDATES_COVERAGE_DIR to a new directory beneath an existing canonical,
user-owned private parent with no group/world write permission. The output must
be outside the repository and must not already exist. Then run:

```sh
SCRIV_UPDATES_COVERAGE_DIR=/absolute/private/parent/capture-1 \
  node scripts/tracer-cli.mjs app -- test services updates
```

The collector never installs Tracer or other software. It requires the existing
TypeScript parser, Miniflare and platform workerd packages. Do not move this work
to a computer with a storage or access restriction to get around that restriction.

Set `SCRIV_UPDATES_STARTUP_COVERAGE=1` with the same command to capture
initialization of the isolated Worker as a second interval. The original HTTP
interval still uses its measured request baseline and has its usual file paths.
The `startup/` directory contains two additional collector snapshots, its own
LCOV pair, and a distinct interval ID for the same source and build.

## What is measured

The parser selects certain statement-list entries in the original JavaScript.
Fixed-slot increments are inserted before their exact original UTF-16 positions.
Removing only the recorded insertions, header and footer must recover the source
exactly. There is no reprinting, wrapping of standalone control bodies, source-map
inference or attribution of an entire function to one hit. The instrumenter is
reviewed for this update Worker, not advertised as a universal JavaScript tool.

The denominator is the unique original anchor lines with selected probes. A
line's counter is the sum of its recorded statement-site counters. Its observed
count increases only when those real counters increase. Multiline completion,
branches, skipped statements, concise arrows, unprobed declaration headers, comments and all
other uninstrumented lines are not inferred. Module initialization happens before
the real baseline, so initialization counters may already be nonzero without
increasing during the recorded HTTP interval. Startup mode reads actual counter
copies taken inside the instrumented module before and after evaluation of its
original body. Both must belong to the HTTP baseline's module generation and
neither can exceed that baseline. The two authenticated reads leave the request
counter and snapshot sequence intact.

The application Worker and collector share one module-private counter instance.
A separate test-only wrapper delegates ordinary requests to the real handler.
A per-run nonce exists only in a temporary local binding and request headers,
not in stored source, URLs or retained evidence. Missing and wrong nonces must
be refused without changing original-source counters. Snapshots must keep one
module generation, advance their sequence, retain the same slots and contain
safe nonnegative cumulative integers. There is no reset endpoint.

Two before and two after snapshots prove repeated reads do not reset or increment
counters. The official interval uses the second before snapshot and first after
snapshot. All 48 ordinary HTTP checks must pass, with zero outbound attempts,
loopback-only transport, five-second HTTP request deadlines and owned cleanup.
Cancellation during preparation prevents later Worker launch and measurement import; preserve evidence
and inspect the result before retrying an interrupted import.

## Evidence and interpretation

Private evidence includes original and instrumented source, wrapper, insertion
ledger, sites, raw snapshots, exact LCOV bytes, source/probe/tool hashes, import
receipt and the official measurement report/check. The exported source manifest
is bound explicitly to the Worker and probe bytes used by the capture. Source
identity remains strict before and after import. A verified external source copy
holds the Tracer dataset, never the pinned original source checkout.

A separate fresh validation copy must reject the actual captured endpoints in
reverse order as negative deltas. That deliberately invalid control is not a
measured interval. An uncertain real import is attempted only once; its marker
and artifacts remain for inspection rather than being blindly retried.

Use Tracer measure report and measure check with the returned analysis root.
Report numerator, denominator, scope and source identity. These are producer-
declared input identities, not cryptographic build attestation. Counter increases
are interval observations, not proof of assertion adequacy or per-action causality.
This is not native, Sparkle, release-signing, all-Worker-line, backend-wide or
whole-project coverage. Do not add unrelated denominators or sum repeated runs.

Use a different new output directory for each later capture. Keep previous data.
If a source tree already contains measurement output, preserve it and select a
separate verified clean source tree; never delete it or relax exact identity
checks to make capture succeed. Do not commit private datasets, profiles, logs,
local paths or tool-input evidence to the repository.
