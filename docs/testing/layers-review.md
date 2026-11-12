# Layers review journey (AUT-J11)

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

The new journey uses the actual mounted Preview disclosure, Timeline zoom slider,
Snap to words switch and expanded Layers sheet. It runs two full open/inspect/
close cycles and compares all saved project packages before and after each.
It invokes a registered UIKit Escape command, not a physical keyboard event.
No provider, asset import, drag or authored timing command is issued.

## Escape behavior

Source inspection found that LayerTimelineViewController replaced the shared sheet Escape command with unconditional drag cancellation.

The production correction keeps the first Escape owned by an active timing drag. When idle, an expanded Layers sheet uses the existing guarded sheet dismissal; an embedded timeline remains open. Disappearance still only cancels drags. Active gesture cancellation, second-Escape behavior during real dragging and physical key delivery remain unverified, even if the idle-sheet scenario passes.

## Coverage limits

This covers IMG-005 presentation variants plus controls from IMG-006/007. It does
not prove the result of snapping a drag, exact timeline geometry at every zoom,
scene-length caps, tile selection/rebuild identity, cached image digests or
physical pointer manipulation. The frozen Preview/Layers test also inspects
object identity, parent containment, a fixed 620×840 fixture and a 276-point view;
this journey does not replace that whole method. No old test is retired here.
