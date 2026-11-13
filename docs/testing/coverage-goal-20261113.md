# Coverage goal checkpoint, November 13, 2026

The resumed goal is 100% overall Tracer coverage with fewer meaningful journeys
and better agent tooling. This checkpoint is an increment, not completion.
Production source remains at `9d4f717`; only journey coverage, reviewed mappings
and documentation changed in this batch. The previous two weeks of Scriv and
`pcopu/tracerCLI` commits were reviewed before selecting work.

## Current checkpoint

The second reuse increment reaches **6,176 / 30,831 assertion-linked lines
(20.03%)**. It adds 724 previously unlinked lines and 214 reviewed associations;
all 2,399 links and 1,211 comment declarations pass integrity checks. There are
24,655 lines below the unchanged one-trace minimum. The denominator and source
exclusions are unchanged. This remains manual assertion mapping, not measured
execution coverage or goal completion.

| Existing journey area | New included lines |
| --- | ---: |
| External analysis output and preservation | 55 |
| CLI discovery, rejection and provenance | 39 |
| Pending-save and cue-draft recovery journals | 325 |
| Audio import, editing and workspace state | 71 |
| Script splitting, merging and edit sessions | 90 |
| Generation brief review and idle state | 144 |

The six catalogs passed independent semantic review. One exact preexisting
generation-profile mapping was omitted from the new catalog, retaining the
original record and explanation. Empty job lists are not credited as proof of
generation-journal recovery, and the unopened jobs screen and editor-draft
journal remain gaps. Playback device output, drawing/dragging and unasserted
callback, ownership and failure paths remain unclaimed.

All **39 permitted native journeys** have now passed on the pinned automation
build across the retained batches. The character-alias fallback remains blocked
and was not retried, so this is not a complete 40-journey suite pass. The earlier
capture-limited run remains a failed run even though its interrupted journey
passed later. All 17 public CLI tooling checks and the separate provenance
journey, including its 13 synthetic measurement-output checks, passed. No
application or test source changed in either reuse increment. Repository,
catalog and global link checks passed.

The six native batches share the retained source-manifest and executable
hashes, and each reports its bundle unchanged during that run. The first two
recorded an 80-file bundle fingerprint; the later four recorded a different
77-file fingerprint. These records do not establish identical complete bundles
across all six runs.

Tracer's read-only `next` packet and compact measurement storage are published
in `pcopu/tracerCLI` commit `8d0cfa5`. Its required aggregate check passed 137
tests, with four existing Linux-only skips. The owned checkout is used
explicitly; the installed binary and installed skill were not changed.

## First reuse increment

The next increment reuses existing journeys without changing application or test
source. Current assertion-linked lines are **5,452 / 30,831 (17.68%)**, leaving
25,379 below the one-trace minimum. All 2,185 links and 1,211 comment declarations
pass integrity checks. The denominator, exclusions and minimum are unchanged.
The planned-association milestone remains separate and complete.

Five catalogs add 835 previously unlinked lines through 251 reviewed mappings:

| Catalog | New included lines |
| --- | ---: |
| Model, persistence and Fountain | 124 |
| Audio, word timing and Layers | 162 |
| CLI dispatch and snapshot state | 264 |
| Script and character state | 109 |
| Preview and Storyboard | 176 |

Independent source/assertion review removed claims for unasserted labels,
layout, preview output and callbacks. One already-linked Storyboard range was
omitted from the new catalog, preserving its existing explanation. All 41
source/witness files referenced by these catalogs match the immutable native
build source exactly. No new top-level journey was added.

Nineteen selected native journeys passed across two batches. The first batch
passed seven journeys before a 64-session measurement limit interrupted
model-document; twelve remaining journeys, including model-document, then
passed without capture. The original failed batch record is retained. The
earlier workspace and short-film runs are additional results on the same build.
Repository checks and catalog/link integrity checks passed. Native input parity,
the denied character-alias fallback and release readiness remain unclaimed.

The first batch retained 64 genuine cumulative intervals but imported only 37
before its indented measurement dataset approached the 64 MiB cap. Tracer's
compact serializer was independently validated in a separate analysis copy:
all 64 intervals imported and passed measurement integrity checks, using
15,385,206 bytes versus 66,256,967 bytes for the original 37. Duplicate imports
preserved the old bytes; new imports preserved every original record. The
original dataset, raw exports and manifests remain byte-identical. The cap and
schema did not change. Some intervals belong to the interrupted journey;
counter observations do not turn that failed run into a passing assertion.

Tracer's new read-only `next` command supplies one bounded work packet with
uncovered ranges, source snippets, candidate existing witnesses, plan actions,
hashes and explicit continuation commands. It does not execute a journey or
approve a mapping. The installed Tracer remains unchanged; this work uses the
owned checkout explicitly.

## First increment accounting

Tracer 0.3 at `8e12583`, run explicitly from the owned checkout, reports:

| Measure | Result | Scope |
| --- | ---: | --- |
| Proposed associations | 30,831 / 30,831 (100%) | Current proposal integrity; not a new full semantic audit |
| Current assertion-linked lines | 4,617 / 30,831 (14.98%) | Manual source-to-assertion mapping |
| Lines below the one-trace minimum | 26,214 | Remaining mapping gaps |
| Valid reviewed links | 1,934 / 1,934 | Exact source/witness integrity |
| Valid comment declarations | 1,211 / 1,211 | Existing denominator policy preserved |

The baseline was 4,555 / 30,831. Four graph-transition associations add ten
distinct lines; nineteen audited auth/team associations add 52. No source
exclusions or minimums changed. `check --require-minimum` correctly exits 1 for
the remaining gaps. The completed historical planning milestone remains intact;
the current proposal has 553 current associations and 514 scenario plans.

## Asserted workflows

The document-integrity journey now continues through a cross-scene entry move
and image revision lineage. Source-only and incomplete destination edits are
rejected without changing the public document or history. A repaired move
reuses the rejected command ID and commits once; exact replay preserves it.
Invalid, absent, wrong-kind, self and non-increasing image predecessors are
rejected. A dependent-first valid image pair commits together, and deleting a
referenced predecessor is refused. Independently authored expected snapshots,
receipts and events are compared after each operation, excluding expiring leases.

The existing journey grew from 223 to 278 HTTP checks. The author run and an
independent integration run both passed: 55 new checks, three accepted edits,
eleven rejected edits, one exact replay and zero outbound requests. This is one
extended workflow, not fifteen new top-level scenarios. The separate catalog
and proposal preserve exact actions, source ranges, assertions and limitations.

The auth/team catalog reuses three unchanged journeys and their observed
persistence assertions. The integration review checked both source and witness
ranges before applying all nineteen associations. Persisted fields and exercised
conflict keys are covered; raw SQL constraint violations, cascade behavior,
random-code distribution and unrelated rate-limit branches are not claimed.
See [the author review](auth-existing-audited-review.md) for the detailed scope.

All thirteen isolated service journeys passed during this goal turn, including
the newly authorized email-auth, OAuth, team-lifecycle and synthetic billing
journeys. The four use local fixtures; no real billing operation occurred.
All seventeen tooling journeys passed, and the batch passed cloud typechecking,
repository checks, catalog checks and whitespace validation.

## Native measurements

A fresh standalone-CLI automation build from an immutable source copy passed
Developer ID signature, icon and Catalyst platform checks. It used the existing
approved template and retained Sparkle framework; Xcode and simulators were not
installed. The build-source manifest SHA-256 is
`81e8bf51df498ff80b434cebe56c2bdb69d3847ed136ad95c5bed848a6a9a443`.
The build record and raw evidence remain outside Git.

Workspace and short-film journeys passed on that build. Each interval contains
150 app/Core files and 21,667 current instrumented lines, with zero stale files:

| Interval | Lines whose counters increased |
| --- | ---: |
| Workspace | 1,966 |
| Short film, authoring session | 8,332 |
| Short film, reopen session | 4,752 |

These are separate before/after observations. Do not add their numerators or
denominators: they overlap. They do not cover uninstrumented helpers, browser or
server code, establish per-action causality, or form an overall percentage.
Source/build binding is producer-declared, not cryptographic attestation.
This automation build is not a distributable or notarized release, and these
journeys do not establish native auth or trusted-helper behavior. The denied
character-alias fallback was not retried.

## Live sign-in

The two user-authorized accounts separately completed real email-code sign-in.
Codes were retrieved through the inboxes the user opened in the Codex browser.
Each resulting token authenticated a session-list request, replay of its consumed
code was refused, and the temporary verification session was revoked and then
refused. This direct API verification is separate from CLI journey and native
app evidence. No account address, code, verifier or session token is included in
the repository or this report.

## Next selection

Tracer's proposed prioritizer ranks unique witnessed gaps and shared existing
journey paths. Its output is a work queue, not accepted evidence or proof of an
optimal scenario set. The larger next opportunities include existing CLI
provenance/tooling journeys and native image, picture and workspace workflows.
Continue reviewing actual assertions before promoting their source links.
