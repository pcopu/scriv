# Forced-action production round trip

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Candidate frozen FountainTests.swift::0004,
`testForcedActionsAndCustomHeadingsRoundTripWithoutBecomingSpeakers`.
Full source path apps/mac/Tests/ScrivCoreTests/FountainTests.swift;
frozen file SHA ef94a9c83bd09dcd8055f876a1126f06d16286f2bffc816795a6e3b05bd71e8b.

The scenario constructs the exact title, custom scene title, three direction
texts/kinds, owned durations [2000,1000,0] and coverage [86400000,1000,3000]
through actual synthetic Fountain import, asserting the complete starting
fixture before exporting. IDs and initial cues are created by the application,
rather than directly constructing a model. It then invokes production
export/write/cleanup and production import/validation, comparing all four
original arrays: scene titles, entry text, kinds and coverage. It checks prior
saved packages remain unchanged. No JavaScript parser or timing validator.

It covers semantic application import/export, not document pickers or external-file copying. The legacy method remains until native verification passes.

Bounded owned process group exited cleanly. This supersedes pending statements above. The mapped legacy method is now retired.
