# Character search Escape actual-app scenario

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

```sh
SCRIV_E2E_APP=/path/to/Scriv.app node tests/e2e/character-search-escape.mjs
```

The scenario launches the actual automation-enabled Catalyst application in its
UUID-isolated synthetic workspace using the existing `ScrivSession`. It selects
the Characters tab, edits the real native search field, and dispatches the
registered Escape action through the active responder chain. No store mutation,
model fixture injection, source-text assertion, or XCTest invocation is used.

## Exact baseline mapping

- Source: `apps/catalyst/Tests/ScrivUIKitTests/WorkspaceEndToEndTests.swift`
- Frozen inventory ID: `apps/catalyst/Tests/ScrivUIKitTests/WorkspaceEndToEndTests.swift::0009`
- Test: `testCharacterSearchEscapeClearsTheFilter` (original line 531).

Every behavioral assertion in that test maps to this scenario:

| Original assertion | Actual-app observation |
| --- | --- |
| Randy is initially shown | The mounted character ribbon includes Randy, alongside Miya. |
| Searching Miya hides Randy | Native text insertion focuses the field; Miya remains and Randy disappears from the mounted ribbon. |
| Escape command exists and has priority | `controller-keys` exposes the mounted CharactersController's actual Escape UIKeyCommand and `wantsPriorityOverSystemBehavior === true`. |
| Escape action is enabled with the field focused | `controller-keys` reports `enabled === true`, computed from the actual controller's `canPerformAction` and active presentation. |
| Escape empties the field | A post-dispatch snapshot observes an empty search field. |
| Escape restores Randy and the filter | Randy returns and the complete sorted ribbon identifier set equals the initial set. |
| Escape becomes disabled outside the field | The field loses first-responder status and the same registered controller action reports `enabled === false`. This does not infer disabled state merely from its absence in a responder chain. |

The whole filter/Escape cycle repeats twice in the same session, additionally
checking stale filter state and repeat focus handling. The scenario checks the
UIKeyCommand priority property just as the original test did; neither test
claims to synthesize a physical macOS keyboard event or establish system-level
keyboard interception behavior.

## Driver contract

`controller-keys` is read-only: it observes mounted app-owned controllers and
returns `controllerType`, `input`, `modifiers`, `action`, `enabled`, and
`wantsPriorityOverSystemBehavior`, including disabled commands. This scenario
selects the exact `CharactersController` / `clearSearchCommand` / unmodified
Escape record. Mutation uses only the existing `select`, `text`, and `key`
commands. No arbitrary selector invocation is exposed.
