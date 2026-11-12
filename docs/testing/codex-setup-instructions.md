# Codex setup instruction coverage

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Candidate actual-app coverage, **native execution pending**. This slice changes
only its scenario and this mapping document. It does not retire or edit a legacy
test, change production behavior, update evidence ledgers, or modify Actions.

```sh
node --check tests/e2e/codex-setup-instructions.mjs
node tests/e2e/codex-setup-instructions.mjs --check-source-only
SCRIV_E2E_APP=/path/to/ScrivAutomation.app node tests/e2e/codex-setup-instructions.mjs
```

Use an automation-enabled UIKit Mac Catalyst bundle independently verified to
match the inspected checkout. `ScrivSession` launches the actual app with its
isolated synthetic storage. No Codex runtime, provider, server listener,
credentials or authentication session is needed. The runner discovers this
top-level scenario. The source-only mode does not launch the application and
explicitly reports that actual UIKit coverage was not run.

## Frozen baseline and exact assertion mapping

- Frozen commit: `4d14b29f4fb49891e850fa9a8e5742dc878603c8`.
- File: `apps/mac/Tests/ScrivCoreTests/CodexConnectionCheckTests.swift`.
- File SHA-256:
  `0a25b14c1e9cf59a01860f055400a2d8fe5bbfe016504e4f7596414b0a05e589`.
- Inventory ID:
  `apps/mac/Tests/ScrivCoreTests/CodexConnectionCheckTests.swift::0006`.
- Method: `testSetupCommandsAreLiteralOfficialLocalInstructions`, frozen line 36.

The original has exactly three `XCTAssertEqual` calls, at lines 37–39. Each has
an explicit displayed-label replacement:

1. `CodexLocalSetup.installCommand` equals
   `curl -fsSL https://chatgpt.com/codex/install.sh | sh`.
   Observe the actual `UILabel` identified by `codex-copy-install-command`
   inside expanded Installation help.
2. `CodexLocalSetup.signInCommand` equals `codex`.
   Observe the actual `UILabel` identified by `codex-copy-sign-in-command`
   inside expanded Installation help.
3. `CodexLocalSetup.serverCommand` equals
   `codex app-server --listen ws://127.0.0.1:4500`.
   Observe the actual `UILabel` identified by `codex-copy-server-command`
   under Manual connection, independent of the help disclosure.

Comparisons are exact JavaScript string equality with the full native label
text, without trimming, normalization, substring matching or reconstruction.
The frozen declaration and file hash were checked against the baseline commit
and inventory, rather than current working-tree line numbers.

In the reviewed `ScrivCodexSetupView.buildSettings`, these three production
constants are passed directly to `commandStep`. Its actual label is created
with the command text and the stable identifier `codex-<copy ID>-command`.
The scenario observes those mounted labels rather than importing a test model,
reading constants as the assertion result, or invoking a setup/controller method.

## Actual application sequence and observation boundary

1. Wait for the real enabled, hittable workspace tabs; invoke the installed
   Command-comma key action to open Settings; select only the actual
   `scriv.settings.codex` navigation cell.
2. Require one `codex-settings` pane in the native snapshot, exact connection
   text `Not connected`, enabled primary and manual Connect controls, and no
   account-status, account-action, refresh-account, model, Disconnect,
   Cancel connection or setup-error node. Merely observing a Connect control
   does not activate it.
3. Record the untouched executable and endpoint field texts. Require both
   fields to remain enabled, unique, and not first responder at every later
   idle-state checkpoint. Do not change or submit either field.
4. Require Installation help initially `Collapsed`, with both installation
   command labels absent. Scroll the native settings scroll view and observe
   the exact custom-server label before opening help.
5. Open Installation help, observe `Expanded` and both added labels, and
   separately scroll each of the three command labels fully into view. Assert
   all three exact texts from actual `UILabel` snapshot nodes.
6. Close help, require `Collapsed` and both help labels absent, then re-observe
   the unchanged custom-server label. Repeat the complete open/read/close
   sequence once more. Return to the top with help collapsed and the UI still
   disconnected. Always terminate the owned isolated session, including failure.

Every command-label observation resolves current native paths from a fresh
snapshot. Hidden subtrees are absent under the driver's existing snapshot
contract. The snapshot may include nonhidden offscreen views, so the scenario
does not treat presence alone as display: bounded scrolling requires the
entire label frame to fit inside both the native scroll viewport and its owned
window, allowing half a point for geometry rounding. Label text is then read
from that visible-positioned node. `UILabel` is noninteractive and therefore
not required to be `hittable`; the disclosure button must be both hittable and
enabled. This is native view-tree/text/geometry observation, not a pixel capture,
VoiceOver announcement, physical click or physical keystroke test.

The disclosure must have its exact title and expected pre-toggle accessibility
value. Its current path, value, enabled and hittable state are checked again
immediately before activation. A timeout or ambiguous state is a failure, not
permission to repeat an uncertain mutation. Scroll height is bounded to 20,000
points, a usable viewport is required, and session waits are bounded.

## Action safety and source-only preflight

Only Settings navigation, native scroll positioning, and the
`codex-installation-help` disclosure are used. The scenario never activates:

- Primary Connect (`codex-check`), manual Connect (`codex-connect`), Start,
  Stop, Cancel connection, account, login, logout or refresh actions.
- Any Copy button, so it does not read or change the clipboard.
- Official setup guide, any executable/pairing/history picker, pairing
  disclosure or actions, generation jobs, a provider or an external URL.

The install shell pipeline and server command are inert expected label strings.
They are never sent to a shell. No runtime launch, server startup, authentication,
network/provider request or installation is part of this scenario. This is an
action-scope claim, not a packet-capture claim about all app startup behavior.

Before any app launch, an exact-source preflight checks that the one allowed
installation-help handler only toggles `installationExpanded` and calls
`updateDisclosures`. It also checks the full reviewed disclosure updater,
which changes hidden state, chevrons and accessibility values, then requests
layout. Whitespace is normalized only for this source guard, never the displayed
command assertions. Unexpected source changes fail closed for review.

This guard neither verifies the three command literals nor counts as their
replacement test. It is not a Swift parser, transitive call-graph proof, compiled
binary attestation or network trace. A stale or unrelated bundle must not be run
on the strength of the guard alone.
