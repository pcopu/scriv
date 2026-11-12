# Storyboard placement interaction

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

The default picture-coverage journey now runs the existing numeric editor group followed by an isolated Add placement group.

The new group uses the actual playback slider and Storyboard Add placement button. At playhead 3000 it fills the 2500–4000 gap; at 500 it splits the existing Parent cue, preserving its prompt and overlapping Child. Each edit checks the full authored model, unchanged identity/creation time, finite nondecreasing modification time, and exactly one revision. Undo/Redo must preserve generated identities and all unrelated fields. Browser reopen compares the complete loaded model and exact date-bit witnesses.

This does not exercise the separate picture-menu split/merge handlers, physical scrubbing, external pickers, restart recovery, or justify legacy-test retirement by itself.
