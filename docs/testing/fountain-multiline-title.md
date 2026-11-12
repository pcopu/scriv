# Multiline title with an empty line

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Candidate apps/mac/Tests/ScrivCoreTests/FountainTests.swift::0017,
`testExportedMultilineTitleWithBlankLineDoesNotLeakIntoScript`, frozen source
SHA ef94a9c83bd09dcd8055f876a1126f06d16286f2bffc816795a6e3b05bd71e8b.

Setup exports the actual sample, requires its exact known title-page prefix,
and changes only that synthetic input header to the indented three-line title
`First line\n\nThird line`. Production import establishes that title; no model
assignment, rename-field shortcut or alternate serializer is used. Before the
round trip, exact sample entry texts and scene titles are checked unchanged.
Production export/import then exercises all three original assertions against
this verified starting fixture, with real validation before saved publication.
Generated IDs/cues differ after setup import but no original assertion depends
on them. Picker, external-file and title-rename UI parity remain outside scope.

Native pending; legacy test retained. This replaces the earlier assumption
that a single-line Rename field blocked setup: normal Fountain import supports
an indented empty title continuation line.
