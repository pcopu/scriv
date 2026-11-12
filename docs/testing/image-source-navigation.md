# Exact image source navigation

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Real imported PNGs and a normal tag button create two accessible image versions. From another scene/tab/playhead, the historical unplaced version disables Show in script and rejects activation. The placed version's actual Show in script button selects the correct scene, time, cue/version and source row. Repeating from a different origin and reopening the document preserve the complete model and exact dates.

The source row is identified by its split-control descendant, not merely visible text. This does not test portrait/crop analysis, provider calls, physical input, or legacy-method equivalence.
