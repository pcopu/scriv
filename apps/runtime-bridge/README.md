# Scriv Runtime Companion — explicit local bridge

This is a **separate, headless macOS executable/app bundle**, not UI in the Catalyst app. Its sources import Foundation, Network, Security and CoreServices; no AppKit, SwiftUI, hosting view, privileged helper, launch agent or automatic installer. Catalyst cannot call `Process.run`; the ordinary same-user companion owns only the Codex process requested by a paired Scriv connection.

## Installation / launch gate

`bash apps/runtime-bridge/build-companion.sh` builds into `build/runtime-companion/`. It never installs, opens, notarizes or publishes the app. Without an authorized `SCRIV_SIGNING_IDENTITY`, the result is ad-hoc **development-only**, not a distribution-ready signed artifact. The release owner must sign/notarize the separate app and verify the native launch path before shipping.

- Bundle ID: `com.scriv.runtime-companion`
- URL scheme: `scriv-runtime-companion://open` (no arguments, credentials or commands)
- The user explicitly opens the installed companion via Finder or Settings → Open companion. Foundation `NSAppleEventManager` consumes URL activation; `RunLoop.main` services it. Launch initializes a listener only. **It does not start Codex or generate an image.**
- The helper has no UI. Settings gives the installation/pairing instructions and reports connection errors. An unavailable launch handler is an explicit error, never a cloud substitute.
- Pairing file: `~/Library/Application Support/ScrivRuntimeCompanion/Pair with Scriv.scrivbridge`. The containing directory is `0700`, file `0600`; ownership, non-symlink, size and key checks fail closed.
- In Settings choose **Pair companion…**, navigate to that original file, and explicitly select it. The app copies this local capability into its own device-only Keychain. This is **not** ChatGPT's credential or the Scriv Cloud session token. Neither enters the bridge protocol.
- The saved capability persists across normal helper/app restarts. **Forget local pairing** removes only the app's saved copy. **Rotate local pairing…** explicitly replaces the helper capability (only with Codex stopped); all clients must re-import the new private file.

## Wire contract (version 1)

The listener binds **127.0.0.1** on a saved unprivileged port, with required loopback interface. The client uses numeric IPv4 loopback, no DNS, redirects, proxy, cookies or LAN fallback. Frames are a four-byte unsigned big-endian length followed by JSON, capped at 48 MiB. Envelopes contain `version`, UUID `nonce`, millisecond `timestamp`, `direction`, base64-encoded exact `payload` and HMAC-SHA256 `signature`. The secret is never transmitted. The response must prove the same capability and exact request nonce; signing request/response domains differ. Requests older/newer than 60 seconds, replayed nonces, invalid HMACs and oversized frames are rejected.

Pairfile JSON: `{version:1, ownerUID:<current uid>, port:<1024...65535>, secret:<base64 32 random bytes>, installationID:<uuid>}`. No file content belongs in logs or handoff screenshots.

An authenticated `status` handshake returns a fresh per-process `instanceID`. Every state-changing or polling command includes that instance ID. Old commands cannot replay after helper restart even though the pairing secret persists. Commands: `status`, `start`, `send`, `poll`, `stop`, `rotatePairing`. Each also carries a random connection `sessionID`; only that owner may send/poll/stop its child. Polling maintains a 35-second lease. Lost clients, helper termination signals and Stop terminate only the child owned by this companion, never an external server. Lost responses are uncertain and never resubmit a model turn.

`start` accepts an explicitly configured executable and existing private Scriv `Generation` directory under this user's home. Executables must resolve to regular executable files owned by this user or root, without group/world-write permission. No shell, shell command, environment override or alternate process arguments are accepted; arguments are fixed to `app-server`. Output is bounded and stderr drained without copying runtime secrets to app/cloud logs.

`send` further allows only Scriv's existing initialization/account/model/image-thread/turn/inspect/cancel methods. New threads must use a UUID folder directly inside the captured generation root, `workspace-write`, and `approvalPolicy:never`. Turn-level sandbox overrides, arbitrary command RPCs, external image inputs and permission approvals are rejected. The Catalyst CodexController retains exact-prompt journaling, original-reference hashes, bounded artifact validation, cancellation and explicit retry confirmation.

Existing **Connect** is a separate path to an already-running Codex loopback WebSocket. Disconnect never stops that external process. It is not silently substituted for failed companion Start.

## Evidence and remaining native gates

Portable tests cover the RFC HMAC vector, mutual proof, tampering/wrong key/nonce, replay/clock, same-user pairfile fields, restart-instance fencing, method whitelist, permission denial and turn override rejection. Linux parsing is not native typechecking.

Before claiming Start works: build/sign both targets on macOS; verify Finder/custom-URL launch and Foundation event consumption; verify the listener with `lsof` binds only 127.0.0.1; explicitly pair through the real picker; start a local non-generating test runtime; verify initialization/status/models/account, stop, launchfailure, wrongsecret, sameport impostor, rotation, idlelease, sleep/reconnect, artifact filesystem access and existing journal recovery. Live email, ChatGPT login and usage-producing generation remain explicit user actions. No native runtime launch or credential setup was performed by this implementation worker.

### Existing generation history

Catalyst does not assume it can read the legacy app's Application Support directory. **Use existing generation history…** explicitly selects the original `Scriv/Generation` folder through the system picker, retains a security-scoped bookmark and preserves its one original installation identity. Nothing is moved/deleted; exact prompts, references, hashes and journal paths remain in place. Mixed-owner folders are refused. Missing access surfaces an error instead of silently substituting an empty new history. Open each original project package separately before attaching an older job's image.

### Connection is not authentication

A disconnected/stopped Scriv transport is **not** evidence that the CLI or desktop account is logged out. The account row shows that Start/Connect will inspect the existing local login. Only a successful `account/read` returning no account produces the signed-out state. Starting a runtime does not automatically open login or submit a generation. This corrects the earlier misleading combined “Start Codex and sign into ChatGPT” alert.

Primary API references checked during implementation: [Apple NSAppleEventManager](https://developer.apple.com/documentation/foundation/nsappleeventmanager/seteventhandler(_:andselector:foreventclass:andeventid:)), [Apple UIApplication.open](https://developer.apple.com/documentation/uikit/uiapplication/open(_:options:completionhandler:)), [Apple requiredLocalEndpoint](https://developer.apple.com/documentation/network/nwparameters/requiredlocalendpoint). These document supported primitives, not a substitute for testing the actual built app.
