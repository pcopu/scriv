# CLI cloud isolation foundations

## Local Worker fixture

`tracer app -- test --scenario journeys/native-cloud-sign-in` uses the locked
cloud development dependencies. It runs two fresh Catalyst sessions against
one owned, loopback-only Worker. The default session shows the offline error
and sends zero messages. The fixture session requests one code for a synthetic
address, verifies delivery and the native code prompt, then cancels. Both
sessions check the complete loaded project and saved package.

`tracer app -- test --scenario journeys/native-cloud-project-sync` creates
and seeds a cloud project through Discussion, edits dialogue in the native
editor, and reopens it from the cloud project list. It verifies the complete
edited script, the matching Worker project row, and an unchanged local project.
A second app session starts with no local replica and downloads the same edited
script into a new saved package. The journey posts and replies in the project
discussion, resolves the thread, and verifies its saved state through Project
activity in the second session before reopening it. A note on the edited line
stays separate from the project-wide thread across both sessions. The member
picker verifies an empty search and a case-insensitive role match, then adds,
removes, and re-adds the project owner. The journey posts the mention, opens it
from the line thread through Project activity, and verifies the original project
discussion and saved project. CLI `activate` dispatches visible single-select
rows in these two discussion pickers through their UIKit selection handlers.
Each session verifies one synthetic code. When the workspace shows the account
toolbar button, the second session uses the account sheet to sync the linked
script and sign out. The loaded and saved projects stay equal to the downloaded
copy after each action. The Worker fixture checks that the second sign-in was
revoked and the first remains active, using ordered revocation flags that expose
no session identifiers or tokens. A compact workspace checks that the account
menu item is present and reports the sheet actions as skipped.
Only the active native prompt for the fixture's synthetic address can consume
its code from a separate unlinked mailbox descriptor. The normal Sign in with
code button submits it to the Worker. General CLI text entry still refuses the
protected field, and snapshots redact its contents.

The scenario passes the exact loopback origin in an unlinked, read-only
descriptor tied to the fresh run's UUID. The automation app validates it
before constructing its cloud client. Ordinary CLI sessions stay offline.
Persistent and resumed sessions reject fixture grants. Both launch modes keep
OAuth and peer transport disabled. The Worker denies outbound requests.

## Original isolation checkpoint

Status: implementation and source review only. No login/team journey is enabled
or certified by this change.
The existing 27 eligible native entrypoints and 43 retired legacy methods are
unchanged. Source assertions are maintenance checks, not end-to-end acceptance.

## Launch and capability boundary

- Only the application module compiled with `SCRIV_CLI_AUTOMATION` includes the
  capability. `ScrivCore` does not receive that define. No core-only switch is
  relied on for credential or outbox isolation.
- `main.swift` already calls `prepareScrivCLIEnvironment()` before
  `UIApplicationMain`. That function now creates `ScrivCLIRunCapability` before
  any stored `WorkspaceStore.cloud = CloudClient()` construction.
- A CLI launch requires both `--scriv-cli` and `--screenshots`, plus a canonical
  UUID in `SCRIV_CLI_RUN_ID`. The app creates a previously nonexistent directory
  under its own temporary directory using `mkdirat`, mode 0700. It creates a
  private `Outbox` child at the same time. Preexisting roots are never adopted.
- Preparation records open root/outbox descriptors and the UUID in a
  process-private capability. The environment path alone cannot recreate it.
  Validation checks UUID/arguments/environment binding, effective owner,
  directory modes, inode/device identity, and absence of run-path symlinks.
- Setup failure exits before UIKit starts. A requested CLI launch that reaches
  CloudClient without a valid capability terminates rather than selecting
  Keychain. Later validation failure throws and never switches to normal
  credentials/storage. CLI start and command dispatch also require the prepared
  capability, including asynchronous synthetic audio dispatch.
- Non-CLI launches and non-automation builds retain the existing Keychain,
  application-support outbox, endpoint preferences, and screenshot/peer-smoke
  initial-token-read suppression. The backend is selected before origin or
  token access in CloudClient's constructor.

## Credential and side-effect matrix

| Boundary | Isolated behavior | Ordinary behavior |
| --- | --- | --- |
| Constructor token read | In-memory backend selected before URLSession/base URL; screenshot launch still skips the initial read | Same initial-read guard and Keychain service/account |
| Base URL setter | Requires the immutable approved origin before cancellation, preferences, token read, or other state changes | Existing validated URL, preference save and saved-session read |
| Authenticated HTTP 401 | Backend delete touches only process memory | Same Keychain deletion and local sign-out |
| Email verification session write | Backend write; request/verification cannot run with network disabled | Same validation, production handler and Keychain write |
| OAuth exchange write | Backend-routed, but OAuth entry rejects isolated mode before state changes or browser creation | Existing OAuth flow and Keychain write |
| Sign out | Backend delete is local; direct revocation requires network authorization before request construction/send | Same local sign-out and direct server revocation |
| Nested delete during credential write | `ScrivCLIMemoryCredentials.write` calls its own memory delete | `KeychainToken.write` calls its own Keychain delete |
| Ordinary and anonymous API requests | Final API URL authorized before request headers/body or URLSession activity | Existing production requests |
| Redirects | Existing URLSession delegate rejects every redirect | Unchanged reject-all redirect policy |
| Authentication challenges | Session and task challenge delegates cancel before default credential/certificate handling | Default handling, as before |
| Project attachment | Network checked before disconnect/project attachment mutation | Existing attachment sequence |
| WebSocket | `ws` URL checked before socket state mutation, task creation or resume | Existing WebSocket/reconnect behavior |
| Peer attachment | `WorkspaceStore.configurePeers` cancels/disconnects, then stops before fetching ICE or starting WKWebView | Existing peer setup |
| Outbox commit/import/retry/read/list/rename/remove | All operations use the capability's guarded descriptor-relative storage | Same bytes and Foundation storage calls |

All `SecItemCopyMatching`, `SecItemAdd`, and `SecItemDelete` calls remain confined
to `KeychainToken`, which is never constructed for a validated CLI run. The
CloudClient call sites all use `CloudCredentialBackend`, including both sign-in
writes and both deletion paths. There is no install-token, account injection,
credential export, persistent grant, or token-bearing capability command.

## Network boundary

The only capability creation site passes `approvedOrigin: nil`. Therefore all
CloudClient network attempts, including anonymous email requests, are disabled.
No command, environment setting, saved preference, or launch argument grants a
cloud origin. The displayed base URL in isolated mode is an inert loopback
placeholder, not permission to connect to it.

The future optional-origin validator accepts only canonical
`http://127.0.0.1:<explicit-port>` origins, with no user info, path other than `/`,
query, fragment, hostname/DNS alias, or alternate IP spelling. Authorized API
and WebSocket URLs would have to retain that exact host and port, with HTTP or
WS respectively. Enabling that future path requires a separately reviewed
fixture and explicit scope; it is not enabled here. Isolated URLSession also
disables credential storage, cookies, URL cache, and configured proxies. Both
session-level and task-level authentication challenges are explicitly canceled
in isolated mode; ordinary launches keep default challenge handling.

OAuth is rejected even if a future loopback origin exists. Peer WebRTC is
separately disabled because WK networking and the service's default external
STUN server are outside URLSession policy. The immutable isolated mode cannot
become non-isolated while a peer configuration task is pending.

This is a CloudClient boundary, not a process-wide network sandbox. Codex's
separate manual WebSocket client is unchanged and is not covered by these
credential or cloud transport claims. No server was started or contacted to
verify this implementation.

## Outbox boundary and exact retry behavior

CloudClient still encodes the same record, payload, command ID, manifest and
part bytes. It still retries the serialized record rather than reconstructing
the edit. Normal builds call the same Foundation read/write/list/rename/remove
operations through small wrappers.

For isolated mode, only the private run's `Outbox/<scope-hash>` is accessible:

- Scope hashes must be 64 lowercase hex characters. Scope directories are
  created by this process at 0700, kept open, and checked against their named
  device/inode/owner/mode on reuse. An existing, unowned scope is rejected.
- File names are bounded single ASCII basenames. Every operation validates
  the exact run-root namespace; no caller-supplied external path is accepted.
- Reads use `openat` with `O_NOFOLLOW | O_NONBLOCK`, regular-file, effective-owner,
  0600, link-count-one and named-inode checks. Enumeration uses a fresh
  descriptor-relative directory stream, not a path-based traversal.
- Writes create a new exclusive 0600 temporary file, write the unchanged bytes,
  fsync, and atomically rename within the retained scope descriptor. Existing
  destination files must pass validation. No symlink target is followed.
- Rejected/local-draft renames retain the exact bytes and use an exclusive
  destination rename. Deletion uses `unlinkat` after validation, not recursive
  removal. Creation-time sorting uses descriptor metadata in isolated mode.
- Isolated records are limited to 64 MiB both before writing and while reading
  actual bytes (including growth during a read); enumeration is capped at 256
  files. Isolated creation-time validation errors propagate rather than becoming
  a fallback sort date. Successful cloud commit/import cleanup also propagates
  isolated removal/validation failures; ordinary cleanup retains its existing
  best-effort behavior. These bounds do not alter ordinary outbox behavior.
- These checks prevent fallback, symlink traversal and accidental reuse, but
  do not claim protection from arbitrary code already executing inside this
  same process or a fully compromised same-user account. Descriptor-relative
  operations keep races from escaping into another directory or following a
  substituted symlink.

Outbox contents, lease tokens, PKCE state and account tokens are not emitted by
capabilities or snapshots. No resume/across-process account recovery is claimed:
credentials disappear with the process and a previous run root is not adopted.
Each CloudClient has its own in-memory credential backend; cross-window session
restoration is not implemented or claimed.

## Sensitive UIKit observations

`UITextField` and `UITextView` are sensitive when secure-entry is enabled **or**
their content type is `.oneTimeCode`. The sign-in code field uses the latter.

- `snapshot` redacts generic accessibility label/value metadata for those
  fields, their UIView descendants and aggregating ancestors. Sensitive
  subtree identifiers/text are redacted. Placeholder, button/segment text,
  attributed text and selection metadata are not read/emitted for those
  subtrees. Hidden sensitive inputs are included when finding ancestors.
- Public and native accessibility snapshot/activation paths reject while any
  sensitive input exists in owned windows, before enumerating accessibility
  containers or loading the native helper. This avoids alternate container
  representations bypassing UIView redaction.
- Text/type/selection/return/delete commands reject sensitive subtrees, so this
  batch does not introduce a raw OTP-entry/logging route.
- Existing loaded-project, script zoom, direction/duration and audio-anchor
  safety guards are preserved. There is no new screenshot capture path.

Only secret-free cloud isolation status is added to `capabilities`: memory
credentials, private-run-root outbox, network disabled, OAuth disabled, and
peer transport disabled. No account/credential or raw outbox observation is
added. The previously denied native accessibility helper was not loaded.

## Verification and remaining gates

Completed here:

- Existing startup diagnostics source checks: 10/10 pass. The single stale
  `KeychainToken.read` expression was changed to `credentialBackend.read` while
  preserving the initial-read guard assertion. This is not native evidence.
- `node scripts/check-repo.mjs` passes.
- `git diff --check` passes.
- Independent security/source review is required before native transfer; its
  final disposition must accompany this batch.

Not run: Apple compilation, normal/isolated native launch, UIKit snapshot tests,
Keychain observation, OS-level outbox/symlink/race checks, HTTP/WebSocket/redirect
fixtures, account/login/team journeys, server tests, OAuth, delivery, peer/WAN,
restart/resume, or app-wide external-network verification. This executor has no
Swift compiler or Apple SDK. No dependency install, server, Mac tool, sign-in,
deployment, push or Actions change occurred. Foundations remain native-unverified.

Before any native compatibility batch, compile both gated and ordinary app
targets and exercise invalid/missing/reused run setup, then basic launch and
the existing non-cloud regressions. Future synthetic local cloud acceptance
must separately prove zero Keychain access, all outbox operations/tamper
rejection, OTP descendants and alternate accessibility surfaces, endpoint/
redirect denial and a zero-external-traffic transport boundary. It must not
substitute source-regex tests or seeded-token claims for real auth UI coverage.
