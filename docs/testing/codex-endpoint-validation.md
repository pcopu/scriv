# Codex manual endpoint validation

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Candidate actual-app scenario, not a completed migration or retirement approval.
Only two new files belong to this slice; no legacy tests, inventories, shared
helpers, production code, build settings or Actions are changed.

```sh
node --check tests/e2e/codex-endpoint-validation.mjs
node tests/e2e/codex-endpoint-validation.mjs --check-source-only
SCRIV_E2E_APP=/path/to/ScrivAutomation.app node tests/e2e/codex-endpoint-validation.mjs
```

Use an automation-enabled Catalyst binary verified to match this checkout. The
launcher creates isolated synthetic application storage. No service, credentials,
provider, listener, authentication session or separate runtime is needed. The
scenario never imports the live connection script or probes a socket.

## Exact baseline and assertion mapping

Frozen baseline commit: `4d14b29f4fb49891e850fa9a8e5742dc878603c8`.

Inventory ID:
`apps/mac/Tests/ScrivCoreTests/CodexConnectionCheckTests.swift::0004`.

Method: `testEndpointIsNumericLoopbackAndRejectsUnsafeInput`, frozen line 24.
Source SHA-256:
`0a25b14c1e9cf59a01860f055400a2d8fe5bbfe016504e4f7596414b0a05e589`.

The original has two positive `XCTAssertEqual` assertions and one
`XCTAssertThrowsError(try CodexLocalSetup.endpointURL(value), value)` loop over
eight values. The scenario preserves all eight rejection inputs exactly:

- `ws://example.com:4500`: non-loopback host.
- `ws://0.0.0.0:4500`: wildcard host.
- `ws://127.0.0.1:80`: privileged port.
- `https://127.0.0.1:4500`: unsupported scheme.
- `ws://a:b@127.0.0.1:4500`: synthetic userinfo.
- `ws://127.0.0.1:4500?token=secret`: synthetic query string.
- `ws://127.0.0.1:4500#fragment`: fragment.
- `ws://127.0.0.1:65536`: out-of-range port.

The userinfo/query literals are copied synthetic test cases, not actual secrets.
They are rejected locally, not transmitted. Only these invalid literals may be
submitted. The visible default address is never submitted. Clearing the field is
observed separately but never followed by activation while blank.

Each rejection maps to actual UIKit Settings > Codex > Manual connection:
Command-comma opens the real Settings scene; the `scriv.settings.codex` cell
selects the pane; native text editing enters the literal; only `codex-connect`
with exact label `Connect to this address` is activated. It must show exactly:

> Use an unprivileged loopback Codex app-server address on this Mac, without credentials or query parameters.

The field must retain the submitted literal. The same snapshot must show
`Not connected`, enabled manual connect, and no visible account-status, model,
Disconnect or Cancel connection controls. Two full cycles cover replacement,
clearing and retry across all eight values. Final clearing remains disconnected.
This is observed UI state, not a private transport-state observation.

## Why these actions cannot reach socket construction in reviewed source

`ScrivSettingsController.installCodexSetup` wires manual `onConnect` to
`saveRuntimeFields()` followed by `store.codex.connect()` inside its error-catching
`run` wrapper. `saveRuntimeFields` copies the endpoint text directly. The scenario
keeps the field first responder and rechecks its exact invalid text immediately
before activation. It deliberately avoids `end-editing`: the older native driver
ended editing in the original workspace rather than the separate Settings scene.
It does not depend on the later, not-yet-compiled fix.

`CodexController.connect` first checks for an existing transport, then executes
`let url = try CodexLocalSetup.endpointURL(endpoint)`. This throwing call precedes
`disconnect(cancelCheck: false)`, `isConnecting = true`, the `Connecting…` status,
`URLSessionConfiguration.ephemeral`, `URLSession(...)`, `webSocketTask(with:)`,
and `ws.resume()`. All eight literals fail the policy guard in `endpointURL` and
throw the permission error above. `ScrivError.errorDescription` returns that
message unchanged; the Settings wrapper displays it as its local error.

The executable source preflight checks the reviewed routing, guard clauses and
ordering before launching. It fails closed on those source changes. It is not a
Swift parser, binary attestation, packet capture or substitute for a native run.
Confirm the native binary matches the inspected implementation before execution.
No primary Connect (`codex-check`), check/start, account, logout, generation,
provider, pairing, installation or external-guide action is performed.

## Gaps and retireability

**Retirement allowed: false.** Native execution has not been performed for this
slice. Even after a successful run, baseline assertion parity is partial:

- The original positive assertion that `ws://localhost:4500` normalizes its host
  to `127.0.0.1` is deliberately not exercised.
- The original positive assertion that `CodexLocalSetup.defaultEndpoint` has port
  4500 is deliberately not exercised.
- UI error/state evidence is not a direct observation of a thrown Swift error or
  proof of no network traffic in an arbitrary stale binary.
- Hidden controls are absent from snapshots by the existing adapter contract;
  this does not inspect account credentials, private controller fields or sockets.
- No connection handshake, valid-loopback submission, authentication, startup,
  cancellation, duplicate in-flight connection, provider use or reconnect is
  claimed. No assertions from other baseline IDs are claimed.
- Native focus retention while scrolling and activating the manual button must
  be verified. If it fails, the scenario stops; do not add a valid-address retry,
  invoke primary Connect or bypass the guard to make it pass.

Keep the entire legacy test until both missing positive assertions have equivalent
verified coverage and the actual-app rejection run is independently recorded.
