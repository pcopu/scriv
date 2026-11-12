# Optional measured CLI action sequence

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

The retained tab-switch prototype below is now complemented by the
[real-scenario session collector](cli-scenario-coverage.md), invoked through
`tracer app -- test --coverage` with explicit scenario selection. It shares the
same bounded profile transport. Its successful native path still needs a fresh
matching instrumented build and actual execution.

The language-neutral map is `code-e2e-map.md`. Its links are manual associations.
This separate prototype asks whether the actual Catalyst app can export LLVM
execution evidence for a bounded sequence. It does not replace that map, and it
is not an ordinary regression-suite entrypoint or proof of full coverage.

Build a new isolated bundle using the existing verified template and normal
signing settings, adding `--automation --coverage` to `rebuild-catalyst-cli.py`.
Current coverage builds additionally require the pre-build source-manifest,
digest and external build-record options documented in the scenario workflow.
Coverage without automation is rejected. Ordinary builds remain uninstrumented.
Only the current Core/application compiler inputs are instrumented; native
helpers, carried template plugins, browser runtime, backend and other languages
are not measured by this adapter. Paths in coverage maps use `/scriv-source`.

Run `node scripts/probe-cli-coverage.mjs --help` for the explicit app/output
arguments and separate `llvm-profdata`/`llvm-cov` decoding commands. The probe
selects workspace tab 1 and then 0, with normal UI postconditions. It records two
cumulative snapshots, verifies chunk hashes, releases their memory, and writes
only a new caller-selected output directory. It never reads the app container.
No credentials, model payloads, provider actions or counter resets are involved.

The optional in-app adapter is gated by both build flags and the prepared
synthetic run capability. It allows two immutable snapshots of at most 16 MiB
each and reads at most 128 KiB per request. It accepts no filesystem paths or
profile inputs. The uninstrumented C shim uses LLVM's public buffer interfaces
and documented file-initializer suppression symbol. Native link/runtime behavior
and LLVM raw-format compatibility must be verified; host stub checks do not
establish those properties.

Index before and after profiles separately against the exact instrumented
executable. Never merge the cumulative pair together. Positive count changes
mean execution observed during the sequence, not exclusive causation. Transport,
polling, capture and background work overlap the interval; snapshots are not
globally atomic. Inconsistent or decreasing deltas are ambiguous, and a hit is
not an assertion or permission to retire a test. An optional LCOV import can
later provide the same file/line evidence format for other languages/CLIs.
