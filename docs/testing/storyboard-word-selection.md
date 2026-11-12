# Storyboard word selection migration candidate

Status: syntax checked only; actual-app execution pending Mac reconnection. No legacy test retired.

Candidate: `tests/e2e/storyboard-word-selection.mjs`.
Frozen baseline: `apps/catalyst/Tests/ScrivUIKitTests/WorkspaceEndToEndTests.swift::0006`, `testStoryboardWordCutMoveAndAudioImport`.

The scenario uses native Storyboard tab and word UIControls. It checks uniqueness and complete saved-scene word membership, Deselect enabled after word activation and disabled after deselection, rejects disabled activation, repeats three times, and verifies saved entries/cues remain unchanged. Scene membership is established from the exact word-ID set instead of assuming sample selection.

Remaining original assertions: exact selected-word IDs and selected-cue identity, right-click-only menu state, Move to previous image and contiguous cut persistence, Current moment selecting a specific cue, real one-second audio import/asset copy/placement and saved audio, and nil store error. These are not inferred from the Deselect control. Multi-selection, drag, held modifiers and physical input dispatch are also not covered. This is partial replacement coverage, not equivalence certification.
