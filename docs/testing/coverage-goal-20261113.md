# Coverage goal checkpoint, November 13, 2026

The resumed goal is 100% overall Tracer coverage with fewer meaningful journeys
and better agent tooling. This checkpoint is an increment, not completion.
Production source remains at `9d4f717`; only journey coverage, reviewed mappings
and documentation changed in this batch. The previous two weeks of Scriv and
`pcopu/tracerCLI` commits were reviewed before selecting work.

## Current accounting

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
