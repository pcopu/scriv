# Approved supporting UI and manual-direction recovery — 2026-10-30

This follow-up implements the eleven owner-approved supporting-view boards and combines the previously held text-wrapping fixes. It is a native-source implementation, not a claim that Linux parsing proves macOS screenshot parity.

## Included behavior

- Project browsing has search/filtering, a selected-project preview and explicit local/cloud state. History keeps revision selection separate from readable preview/restore. Recovered script drafts remain reviewable; character-link review captures its entry and navigation context in one sheet payload.
- Audio trimming and word timing use precise numeric controls and previews. A batch word edit validates its original words/duration and saves the entire new sequence atomically. Cancel never commits partial changes.
- Character creation starts with a local form rather than immediately inserting a placeholder. Save validates the name, preserves stable identity and existing mention decisions, and keeps failures visible. Character links and image galleries have dedicated review/detail surfaces.
- Image placements disclose their target, script anchors and owned duration. Image details separate manual direction from an immutable version's captured generation prompt; absent historical captures remain unknown. Loading and missing-image states are distinct, and authored text/errors wrap vertically.
- Authentication, account/sync, settings and generation-job surfaces keep real state and existing authentication/ownership fences. Team roles, paid sharing, invitations and billing controls retain their existing permission checks. Discussion mentions, project activity and unsent composition have clearer hierarchy without inventing email notifications.
- Shared cards, notices, typography, button styles, empty-state actions and duration controls follow the approved supporting-view language while retaining adaptive native colors and keyboard behavior.

## Manual visual override: actual data-loss correction

The ungenerated visual override previously lived only in an in-memory dictionary. It could disappear after Save/Quit/Reopen even though generated images' captured effective prompts were already durable. These are separate issues.

Typing now first writes an atomic, bounded, private local recovery record outside the project package. Its key includes package, project, cloud project, server, account, scene and cue identity. A debounced leased mutation writes the direction to the canonical cue's `prompt` field, which is included in ordinary free/paid cloud metadata. Recovery is cleared only after a successful canonical disk save, with revision compare-and-swap protection against newer typing. Invalid/oversized text and save failures retain the exact recovery draft. Changed source/epoch requires explicit comparison and review; navigation cannot redirect a pending save to another cue or account. Generation waits for pending prompt saves before capturing its attachment target and rejects unreconciled recovered directions.

No local package paths, recovery records, portrait bytes or credentials are projected into cloud metadata. Image binary hosting remains paid-only. The backend and its deployment are unchanged in this follow-up.

## Checks and remaining native gate

- Portable Swift: **222 core tests passed**, including 16 new prompt-journal cases, 4 atomic word-timing cases and 3 image-inspector invariants; optimized ScrivCore build passed.
- **99 Swift source/test files plus the icon script parsed**. Parsing is not AppKit/SwiftUI type-checking.
- Cloud tests: **188 passed, 1 intentionally skipped**. Node repository regressions: **21 passed**. TypeScript and repository checks passed.
- Eight new presentation-helper tests additionally ran in an isolated Foundation-only harness. The macOS app test target contains 24 new tests across presentation, character forms, image inspectors and native text measurement; the complete native target has not run on Linux.
- Read-only integration review and whitespace checks accompany the frozen source snapshot. No hosted workflow was changed or dispatched.

The exact published successor must be rebuilt and tested on macOS: Review Links via pointer/menu, long text/errors, character creation/edit/cancel, audio and multi-word validation, image loading/detail/placement controls, auth/account/jobs, team and discussion surfaces, and an ungenerated manual override across Save/Quit/Reopen and project/cue switches. Compare fresh native captures with the eleven approved boards. Live generation, native visual parity and multiplayer are not certified by these portable checks.
