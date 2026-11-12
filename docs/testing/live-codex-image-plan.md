# Real Codex and image scenarios

Status: source inspection and scenario design only. No account connection, authentication, provider request, image generation, Mac execution, or billing was performed for this plan. The existing fake-runtime/self-check tests are not live integration evidence.

## Isolation boundary and execution blockers

The automation app must be a non-distributed Catalyst build compiled with `SCRIV_CLI_AUTOMATION`, launched with `--scriv-cli --screenshots` and a fresh UUID `SCRIV_CLI_RUN_ID`. `prepareScrivCLIEnvironment()` creates an exclusive private sandbox temporary root and sets `SCRIV_VERIFICATION_ROOT`. Synthetic projects and Generation output belong there. Never open an existing production project or import user images. Keep Scriv cloud signed out.

This does **not** isolate Codex authentication. `CodexController.init` skips existing pairing and generation bookmarks in screenshot mode, but an explicit primary Connect prepares the bundled helper and can read saved pairing. The companion starts Codex with its inherited environment. Do not assume setting the app's HOME/CODEX_HOME controls an XPC-launched helper.

Use a separately launched, harness-owned **real** Codex app-server on an unused numeric loopback port. Its HOME, CODEX_HOME, current directory, and temporary directory must be fresh synthetic directories; inherit only necessary nonsecret environment values, not provider credentials or user configuration. Verify the installed runtime's supported WebSocket launch syntax first (`CodexLocalSetup.serverCommand` is the application's documented command). Do not bind publicly or connect to a discovered existing user's server. Keep process ownership and stop only that process on teardown. The existing `scripts/smoke-codex-runtime.py` demonstrates an allowlisted isolated environment, but exercises stdio and is not a Catalyst UI/live-image test.

Before authenticated execution, verify the runtime's credential-store configuration actually isolates secrets (a distinct CODEX_HOME alone does not prove OS Keychain isolation). Use a dedicated test identity and runtime-supported isolated credential backend or a separate authorized OS test account. Never copy production auth files, inspect credential values, or sign out the user's existing account. Account login can create persistent access and must follow the applicable approval/handoff requirements. Browser authentication must stay out of automation snapshots and logs.

An approved test ChatGPT account with image-generation entitlement and sufficient quota is required. `model/list` success does not establish image capability. Establish permission and a bounded allowance for usage-producing turns before running them; do not buy a plan, add billing, or silently switch provider/model when blocked. Use standard service, not Fast: this app's image thread/turn parameters do not explicitly select a service tier, so verify the isolated runtime's effective configuration does not inherit a fast/priority tier. Disable optional telemetry using supported settings for the installed runtime, without guessing configuration keys.

Remaining execution prerequisites: macOS automation build, real executable/version, owned loopback listener, verified isolated auth backend, approved dedicated sign-in and usage, image-capable account/model, and synthetic artifact evidence collector. Until supplied/verified, mark live cases BLOCKED or NOT RUN, never passed.

## UI route (not controller injection)

1. Create a uniquely named synthetic project and cue using normal UIKit controls. Add a harmless visual direction, such as a blue paper triangle on a white tabletop. Do not load real scripts or portraits.
2. Open Codex settings. From the compact popup, `codex-advanced` opens the settings pane. Use the field labeled `Saved loopback server address`, then `codex-connect` (Connect to this address), **not** `codex-check` (primary Connect, managed helper).
3. Observe `codex-connection-status`, `codex-account-status`, `codex-setup-error`, and `codex-model` via the visible UI. The actual controller sends initialize, initialized, account/read, and model/list to the real runtime.
4. Use `codex-stop` to Disconnect. The external server must remain alive. A disconnected app does not mean the account is signed out.
5. Generate from the cue's real Generate image control and review its actual preview, journal, and persisted project attachment. Do not call controller methods directly, inject a completed image, or fabricate RPC success.

## Scenario matrix

- **Real signed-out connection:** fresh isolated real runtime, Connect to this address, compatible protocol and explicit signed-out state. No login or turn should happen merely by opening settings or connecting. Observe runtime process still alive after Disconnect.
- **Disconnect and reconnect:** repeat connect/disconnect through UIKit three times. Assert stale model/account readiness clears after disconnect and fresh account/model reads establish readiness after reconnect. Ensure no duplicate listeners, no inherited active turn, no generation, and no process-wide kill command.
- **Real sign-in and cancel:** on the isolated identity only, invoke account Sign in, cancel pending sign-in through the app, close/reopen the popup, and retry. Complete approved authentication outside captured evidence. Verify real account readiness afterward. This requires separate browser/auth control beyond the UIKit stdio driver.
- **Authenticated refresh:** refresh the connected account and reopen settings. Verify readiness without repeating login. Avoid retaining the account email or login URL in screenshots/tree dumps.
- **Logout and login again:** on the verified isolated test runtime only, use account menu → Sign out of ChatGPT. Confirm real signed-out state, then approved sign-in and fresh readiness. This is distinct from Disconnect: `signOut()` calls account/logout. Never run against the user's normal CLI/Desktop account.
- **One real image:** submit one synthetic cue through Generate image; observe progress and terminal status. Require a readable newly generated image, a completed generation job, and the target cue's persisted image attachment. Decode actual pixels and verify nonzero dimensions/byte count; merely finding a filename or seeing Connected is insufficient. Keep source/generated files in the synthetic root.
- **Generation cancellation:** separately budget one turn; cancel using the visible progress control, observe terminal cancellation or an honestly reported completion race, and verify there is no automatic retry or extra attached image. During work, confirm unsafe disconnect/account controls are disabled where designed. Do not forcibly disconnect through a hidden test command to bypass UI guards.
- **Real transport loss:** terminate only the harness-owned runtime, then verify the app clears readiness and surfaces disconnection. Restart a new owned process using the same isolated test home, explicitly reconnect, and inspect the original job before any retry. No automatic resubmission or charge.
- **Retry/recovery:** only after an intentionally interrupted synthetic job and an approved additional turn, use the real job recovery/retry UI. Check original job remains distinguishable and only the intended cue changes. Do not claim unsupported image/quota error paths were tested unless actually observed.

## Evidence and limits

Record executable version, build identity, case status, synthetic run UUID, sanitized UI transitions, number of submitted turns, terminal job state, synthetic project/cue/asset IDs, and image dimensions/hash. Do not persist raw authentication responses, browser login URLs, tokens, account email, full runtime home dumps, or unrelated logs. A read-only evidence extension may inspect only the exact run-owned Generation and Projects trees with no caller-supplied paths, symlink traversal, or writes. Do not weaken production helpers, signing, entitlement, or sandbox checks to obtain evidence.

The current synthetic app driver only proves its implemented UI actions and bounded project-export checks; new runtime lifecycle/image evidence must be implemented and actually run before making a live-coverage claim. Managed helper Start/Stop/pairing are a separate lane requiring a genuinely isolated OS/session boundary; the loopback lane must not be described as testing the bundled helper.

## Source anchors

- `apps/catalyst/ScrivUIKit/Automation/ScrivCLI.swift`: private run-root creation, UIKit dispatch, bounded persisted project export.
- `apps/catalyst/ScrivUIKit/Account/ScrivCodexSetupView.swift`: control identifiers, external-server instructions, model and account presentation.
- `apps/catalyst/ScrivUIKit/Account/ScrivSettingsController.swift`: distinct primary check/helper and advanced connect handlers; account menu and logout.
- `apps/mac/Sources/ScrivApp/Services/CodexController.swift`: init isolation exclusions; connect/initialize/readModels; signIn/cancelSignIn/signOut; disconnect ownership; generationRoot; generateImage thread/start, turn/start, artifact checks and timeout.
- `apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift`: cue-scoped context, real image generation and attachment flow.
- `apps/runtime-bridge/Sources/ScrivRuntimeCompanion/main.swift`: child environment inheritance and runtime ownership.
- `scripts/smoke-codex-runtime.py`: real executable version check and isolated non-authenticated stdio smoke environment.

## Codex 0.167.0 isolation preflight

The installed release was identified read-only as codex-cli0.167.0. Exact tag
`rust-v0.167.0` still loads system config and managed requirements independently
of HOME/CODEX_HOME. Before launching any real test server, check existence only
of `/etc/codex/config.toml`, `requirements.toml` and `managed_config.toml`.
Permission errors are not absence. On macOS, use the same-user CoreFoundation
`CFPreferencesAppValueIsForced` API for domain `com.openai.codex`, keys
`config_toml_base64` and `requirements_toml_base64`; do not retrieve their contents.
If any layer is present, stop for review rather than bypassing it. These checks
are point-in-time observations, not a guarantee against later policy changes.

A verified isolated runtime must use `cli_auth_credentials_store="file"`, a new
canonical HOME/CODEX_HOME/cwd, an allowlisted environment without auth/provider/
proxy/OTEL variables, and explicit `service_tier="default"`. Default here means
standard routing; omission can inherit a catalog tier, and `fast`/`priority` are
Fast. Disable analytics, feedback and all OTEL exporters. Do not use the debug-
only managed-config bypass. Authentication and later turns still require their
own approval and effective-tier checks. No runtime was launched for this plan.

Exact-version references:
- https://github.com/openai/codex/blob/rust-v0.167.0/codex-rs/config/src/loader/macos.rs
- https://github.com/openai/codex/blob/rust-v0.167.0/codex-rs/config/src/loader/mod.rs
- https://github.com/openai/codex/blob/rust-v0.167.0/codex-rs/login/src/auth/storage.rs
- https://github.com/openai/codex/blob/rust-v0.167.0/codex-rs/protocol/src/config_types.rs
