# Generation Worker counter capture

The existing generation CLI journey supports opt-in cumulative counters for
selected statement entries in `cloud/src/generation.ts`. All 80 ordinary HTTP
checks and their assertions remain unchanged. Six separate collector requests
check the measurement channel. The normal route uses the ordinary Worker build.

Set `SCRIV_TRACER_CLI` and `SCRIV_TRACER_RUNTIME` to the verified installed Tracer
0.3 entrypoint and scenario runtime. Set `SCRIV_GENERATION_COVERAGE_DIR` to a new
absolute directory under an existing canonical, user-owned private parent outside
the source repository. Then run:

```sh
SCRIV_GENERATION_COVERAGE_DIR=/absolute/private/parent/capture-1 \
  node scripts/tracer-cli.mjs app -- test services generation
```

Use a fresh directory for every capture. No software is installed, no live account
is contacted, and no Mac access is needed. Existing auth/team journey exclusions
are unchanged. This mode supports the existing esbuild platform package layout on
Linux/macOS; it refuses an `ESBUILD_BINARY_PATH` override rather than trusting an
unrecorded binary. Preserve all earlier captures and partial failure evidence.

## Source and build boundary

The test-only instrumenter selects variable, expression, return, throw and if
statements in existing statement lists. It inserts fixed-slot counter increments
at exact original TypeScript offsets. Removing the recorded insertions, header
and footer must reproduce the original source exactly. It does not reprint the
source, wrap standalone control bodies or infer hits across a function/range.

A narrowly scoped esbuild loader validates every loaded production TypeScript
file against the strict source manifest and substitutes only the instrumented
`generation.ts` content. The ordinary index import and snapshot import resolve
to that same module. The loader graph, build options, emitted bundle, source
hashes, insertion ledger and tool input hashes are retained privately. Other
source modules stay uninstrumented. The wrapper delegates to the real index
handler and re-exports the original Durable Object classes. Neither production
source nor deployment configuration is edited. Tool/build identities are
producer-declared evidence, not cryptographic compiler attestation.

The nonce-guarded snapshot route exists only in this measurement build. It
returns bounded counter data and identity fields, never fixtures, environment,
request data or credentials. The nonce is temporary and kept out of stored
source, URLs and evidence. Transport is restricted to the owned loopback origin
with five-second request deadlines, size limits and explicit outbound denial.
The existing owned child watchdog and cleanup remain in effect. Cancellation
during preparation prevents later Worker launch and import; failed or uncertain
imports are not automatically retried.

## What the numbers mean

The denominator is selected original statement-anchor lines in one generation
module instance in the main Worker. The counter on each line sums its selected
statement-site counters. A hit means statement entry, not completion, every
expression/branch, all TypeScript lines, SQL engine coverage or assertion quality.
Concise arrows, standalone control bodies, unselected statements, multiline
continuations and other uninstrumented code remain unknown. This is not a
universal TypeScript instrumenter.

Real repeated before/after reads must preserve cumulative counts, one generation
and advancing snapshot sequences. Missing/wrong nonce requests must leave those
counters unchanged. Module initialization occurs before the real baseline, so
its already-nonzero counters are not interval increases. Never manufacture zero
baselines or claim those initialization lines ran again during the HTTP interval.

The official interval contains the entire 80-check journey, including its existing
synthetic recovery and concurrent-callback continuations. It does not establish
per-action causality or force a particular internal SQL overlap. Other backend
modules, Durable Objects, native app and helpers are outside this measurement.
Do not combine this denominator with manual mapping, native intervals or other
captures to claim overall coverage.

After successful owned cleanup, the collector verifies source/tools/build inputs,
requires genuine Tracer to reject the real endpoints reversed, and imports the
real pair into a separate verified analysis copy. The original source remains
unchanged before and after import. Use `measure report` and `measure check` on
that external analysis root. Keep raw profiles, datasets and local paths out of
Git. Report the exact source checkpoint, observed and instrumented anchor counts,
stale/invalid status and these limits alongside the result.
