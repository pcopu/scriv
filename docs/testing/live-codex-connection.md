# Live Codex connection scenario

**Status: prepared code, not live execution evidence.** No account connection,
authentication, generation, Mac interaction, or billable request was executed
while preparing this scenario. Static validation is not a live pass.

`tests/live-e2e/codex-connection.mjs` drives an actual automation-enabled
Catalyst app through `ScrivSession`. It uses no fake server, injected controller
state, or mocked RPC. It is deliberately outside `tests/e2e` and `*.test.mjs`
discovery. Neither `npm test` nor `npm run test:e2e` should execute it.

## Preconditions and explicit opt-in

Read [the live scenario plan](live-codex-image-plan.md) first. The operator must:

1. Prepare a separately launched, harness-owned **real** Codex WebSocket
   app-server on an unused numeric loopback port. Confirm its version and
   supported launch syntax against the installed runtime. Do not discover or
   reuse the user's normal Codex listener. The operator owns runtime startup,
   process identity, and eventual teardown; this script does none of those.
2. Use fresh synthetic HOME, CODEX_HOME, working directory, and temporary
   directory with an allowlisted nonsecret process environment. Verify actual
   credential-store isolation using the runtime's supported backend or an
   authorized separate OS test account. A different CODEX_HOME by itself is not
   sufficient evidence of Keychain isolation. Never copy or read production
   credentials. A flag below is an operator attestation, not technical proof.
3. For `signed-out`, use fresh empty HOME/CODEX_HOME directories and a
   verified file-only credential backend, with no authentication at all. No
   dedicated signed-in identity is required for this mode; do not sign out a
   real user to achieve it. For `authenticated`, use a dedicated authorized
   test identity and complete approved authentication separately, outside
   captures. No login, logout, or browser action is tested.
4. Verify optional runtime telemetry is disabled using supported settings and
   standard service is configured, never Fast/priority. No provider turn is
   requested here, but the inherited configuration must still be verified.
5. Provide an automation-only non-distributed Catalyst `.app` compiled with
   `SCRIV_CLI_AUTOMATION` (the supported build's `--automation` route). Keep
   Scriv cloud signed out. `ScrivSession` supplies a fresh run UUID and checks
   the app's private synthetic verification root. The normal production build
   must not expose these commands. This lane needs no Xcode.app installation.
6. Confirm permission for the connection/read-account/read-model operations
   against this particular isolated runtime (and dedicated identity if authenticated). No usage-producing
   turns are authorized or sent by this scenario. Image generation needs a
   separate explicitly bounded test and is not covered here.

Only after verifying those prerequisites, set the following variables in the
operator's environment, then invoke the script explicitly:

```sh
export SCRIV_E2E_APP='/absolute/path/to/ScrivAutomation.app'
export SCRIV_LIVE_CODEX_ENDPOINT='ws://127.0.0.1:49152'
export SCRIV_LIVE_CODEX_EXPECT_ACCOUNT='signed-out' # or authenticated
export SCRIV_LIVE_CODEX_ALLOWED=yes
export SCRIV_LIVE_CODEX_ISOLATED_RUNTIME=yes
export SCRIV_LIVE_CODEX_VERIFIED_CREDENTIAL_BACKEND=yes
# Required only for authenticated mode, after verifying the dedicated identity:
# export SCRIV_LIVE_CODEX_DEDICATED_TEST_IDENTITY=yes
export SCRIV_LIVE_CODEX_TELEMETRY_DISABLED=yes
export SCRIV_LIVE_CODEX_STANDARD_SERVICE=yes
node tests/live-e2e/codex-connection.mjs
```

The example port is a placeholder, not permission to use any listener at that
port. Use the actual verified dedicated listener's port. Only canonical
`ws://127.0.0.1:PORT` and `ws://[::1]:PORT` are accepted, with a port from
1024 through 65535 and an optional trailing slash. Hostnames (including
localhost), normalized integer/hex IP aliases, credentials, paths, queries,
fragments, and remote addresses are rejected. Missing flags/configuration exit
nonzero before app launch or network access; unsupported hosts fail before a
socket probe. There is no skip or fake-pass fallback.

## Actual UI path and assertions

The script opens native Settings with Command-comma, activates the collection
cell `scriv.settings.codex`, and requires an initially disconnected pane.
Three consecutive cycles each:

- Scroll the actual `codex-setup-scroll` pane to the text field whose accessible
  label is `Saved loopback server address`, replace its contents, verify the
  entered text, and finish editing.
- Activate **only** `codex-connect`, requiring the exact label
  `Connect to this address`. This is the manual external-server route, not
  `codex-check` (managed helper), `codex-start`, or a copied Terminal command.
- Wait up to 30 seconds for the expected UI state without setup errors.
  Signed-out means `Connected · sign-in needed` and `Not signed in`, with the
  model view absent. Authenticated means `Connected`, a checked account label
  other than the known unsigned/checking/no-auth placeholders, and an enabled
  model control with a non-placeholder selected model. The account label and
  model are never printed. Authentication-free providers are not accepted as
  authenticated ChatGPT test identities.
- Activate **only** `codex-stop` when its exact label is `Disconnect`. A `Stop`
  label fails closed, avoiding managed-runtime shutdown semantics.
- Require `Not connected`, no visible account/model/stop nodes, and re-enabled
  manual connection. A fresh connection must satisfy readiness again.
- Probe only the supplied numeric address with a TCP connection and immediately
  close it, verifying the external listener remains reachable after disconnect.

After the third disconnect the app closes. On failure the isolated app is
closed, but the external runtime is never killed or signed out. An uncertain
mutation is not automatically retried. A failed run can leave the dedicated
runtime alive by design; its owning operator should inspect and clean it up.

## Driver contract

The following are required from `cli/scriv.mjs` and `ScrivCLI.swift`:

- `ScrivSession.launch()` validates fresh isolated run identity/root and starts
  only the requested automation bundle; `close()` targets only that app child.
- `key` dispatches Command-comma through the real app-menu command handler.
- `activate` supports native Settings collection selection through its delegate
  as well as enabled, hittable UIControls. No business-logic shortcuts.
- Snapshots cover the synthetic workspace's Settings window sharing its exact
  WorkspaceStore, not arbitrary app windows, omit hidden views, and expose
  `path`, `identifier`, `label`, `text`, `enabled`, `hittable`, and scroll
  `contentHeight`. Paths are refreshed after navigation/scrolling.
- `text` edits a real UITextField through selection/input behavior; `scroll`
  takes an absolute `y`; `end-editing` finishes active field editing.

Missing controls, unsupported keys, ambiguous panes, disabled or clipped
controls, or incompatible state labels fail nonzero. The script does not
quietly substitute a managed helper or direct controller injection.

## Evidence and honest coverage limits

Output contains only fixed stage names and allowlisted cycle numbers, expected
account-state category, disconnected/listener booleans, and submitted-turn
count (zero). It does not save screenshots, tree dumps, account email, login
URLs, raw RPC replies, provider errors, credentials, or runtime home contents.
Error details from the app are deliberately suppressed; the stage identifies
which UI/prerequisite to inspect locally without exporting auth diagnostics.
The operator should separately record sanitized runtime version/build identity,
run UUID, and final exit status in the test record. No PASS is printed unless
all three UI cycles and listener probes complete and the app closes.

A reachable socket proves reachability, not runtime ownership, continuous
process identity, absence of duplicate listeners, or a correct credential
backend. Those remain externally verified prerequisites. Successful repeated
UI readiness is evidence of the controller's real connection route, not a
packet-level assertion of exact RPC counts. Hidden account/model controls prove
readiness is no longer offered in the UI, not private controller array contents.
Signed-out mode cannot establish model readiness, image capability, quota, or
successful generation. Authenticated mode establishes displayed model readiness
but still does not establish image entitlement. This does not test managed
helper lifecycle, account login/logout/cancel, transport loss, or image jobs.
Use the broader live scenario plan for those separately authorized cases.
