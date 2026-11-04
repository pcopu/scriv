# Scriv Codex acceptance — November 4, 2026

Installed result: **Scriv 1.0.5 (1005)**, UIKit/Mac Catalyst, Apple Silicon,
macOS 26.3, Codex CLI 0.166.0. The signed app is in `/Applications/Scriv.app`.

The audit agent used **gpt-6.1-terra / xhigh**. The live Scriv model was also
selected as **gpt-6.1-terra**. Scriv does not send a reasoning-effort override;
the live turns used the runtime's configuration, not the audit agent's setting.

## Installed-app checks

All generation inputs were synthetic geometric scenes and a synthetic image
reference. The existing user project was not submitted or edited for these tests.
No account was logged out and no credentials were changed.

| Check | Observed result |
| --- | --- |
| Connect after clean launch | One Connect Codex action reached Ready; no address, extra pairing confirmation or new sign-in. |
| Account and model catalog | Existing signed-in account was recognized; Terra was selectable from the returned catalog. |
| Live image generation | A red cube and blue sphere image was generated, imported and attached to the correct cue. |
| Persisted output | Saved artifact digest, image ID, journal output ID and exact submitted request matched. Manual visual direction remained separate. |
| App replacement and restart | Saved project image reopened as Version 1. |
| External project access | Initial bookmark creation failed with Cocoa error 256. After the fix, the picker opened an external package and a later clean relaunch reopened it using its saved grant. |
| Live cancellation | A submitted Terra turn with one copied reference was cancelled. No image was attached; the job stayed waiting for confirmation. |
| Existing-turn inspection | Inspect existing turn changed that job to Cancelled without starting another generation. |
| Reference generation | A second successful Terra turn used one copied, digest-verified local reference and produced a valid image. |
| Source changed during generation | The test source advanced from revision 0 to 1 before completion. The captured request stayed unchanged. The result was imported as a candidate; the changed cue remained unassigned. |

There were **three live generation requests**: two completed images and one
confirmed interruption. Reconnection and inspection did not create model turns.

## Reproducible checks

- `node --test tests/*.test.mjs`: **146 passed**.
- `python3 scripts/check-codex-cancellation.py`: **10 actual-controller cases
  passed**, using an isolated HOME and fake runtimes, without real account access.
- `node scripts/check-repo.mjs`: passed.
- `git diff --check`: passed.
- CLI Catalyst compilation/linking, nested signature verification, approved icon
  verification and native launch: passed. SDK 26.2 / Catalyst deployment 17.0.
- Earlier standalone bootstrap and session-grant checks passed, covering the
  one-action authorization path, cancellation, locked Keychain, session lifetime
  and conflicting or invalid grants.

The ten focused controller cases cover unrelated and missing thread IDs, a
same-thread input request, explicit cancellation, a late turn-start response,
an acknowledged interruption, stale signed-in/signed-out account responses,
a stale account error and a current account failure. Recovery verifies the
interrupted final state. Each cancellation sends at most one interrupt.

The Terra audit also executed disposable synthetic checks for paginated model
discovery, default and image-capable model selection, the selected model in the
actual thread request, usage-limit and missing-image errors, malformed/foreign
completion routing, valid image artifacts, tampered-artifact rejection,
exact-prompt retries and character-analysis turn isolation.

## Fixes included

1. Additional-input requests from a different or unidentified Codex thread no
   longer cancel or contaminate Scriv's active image job.
2. Submitted cancellations remain uncertain until the original turn is inspected.
3. Overlapping account refreshes cannot apply older snapshots or errors after
   newer state. A failed current refresh leaves generation blocked.
4. Catalyst package bookmarks use persistent security scope with the required
   app-scope entitlement. Access failures still propagate.

## Verification limits

This was one Apple Silicon Mac. Intel hardware, other macOS releases, a clean
installation on another Mac, external WebSocket ownership, browser sign-in and
logout, shared-cloud generation, updater installation and release notarization
were not tested here. XCTest is unavailable in the installed standalone CLT.
The cloud typecheck command could not run because its local dependencies were
absent and the global TypeScript launcher was broken; cloud code was unchanged.

The CLI rebuild retains verified compiled assets, icon, native update adapter
and Sparkle from the existing bundle. It is an incremental rebuild, not a clean
resource pipeline or proof of distribution readiness. Existing compiler
concurrency and deprecated-UIKit warnings remain.

If the latest account refresh fails, its error is retained and generation stays
blocked; Stop and Connect retries the connection. A dedicated failed-account
retry presentation remains untested. An installed but signed-out or incompatible
Codex runtime still requires its actual setup.

## Main branch merge verification

The subsequent merge combines `origin/main` at `bc4ec3a` with the tested work
at `0d0c283`. It retains the compact native Codex popup, Settings navigation,
timeline, image-integrity and updater changes from main, together with the
single-action bootstrap, account/cancellation fixes and persistent project
bookmarks. The stronger create-only pairing policy from main remains intact,
including its second storage read before a session fallback is permitted.

- All **182 Node repository checks** passed on the merged source. One existing
  timeout fixture failed during the initial busy parallel run; its focused
  rerun and the final full suite passed without changing that fixture.
- All **10 actual-controller cancellation/account regressions** passed against
  a fresh native Core build.
- The standalone session-grant check passed, including verified absence,
  failed re-reads and conflicting concurrent storage results.
- All **124 Catalyst source/test files** syntax-parsed. The merged UIKit app,
  shared Core and native runtime XPC compiled and linked with standalone CLT.
  Nested signature and approved-icon verification passed; the app records
  Mac Catalyst 17.0 with SDK 26.2.
- Repository integrity and whitespace checks passed. XCTest remains unavailable
  with this CLT installation.

This merge verification made no further live model requests and did not replace
the previously accepted installed app. Its temporary app bundle was removed
after build verification.
