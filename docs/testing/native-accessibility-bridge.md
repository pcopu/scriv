# Native in-process accessibility bridge

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

## Status and purpose

`ScrivCLIAccessibility.bundle` is a test-only diagnostic implementation. Native enumeration, accessibility activation and persisted application outcomes require separate acceptance. The current CLI keeps the unsupported alias route blocked.

This adapter addresses a CLI coverage gap: the current automation routes do not
provide a supported Add/Cancel action path for a Catalyst `UIAlertController`. It does not replace Scriv's UIKit application or
create an alternate implementation of its actions.

The native macOS bundle is separate from the Catalyst executable, like the
existing native update plugin. Its principal class is
`ScrivCLIAccessibilityBridge`, and its Foundation-only protocol is
`ScrivCLIAccessibility` in
`apps/catalyst/AutomationNative/ScrivCLIAccessibility.h`. The caller loads
`Contents/PlugIns/ScrivCLIAccessibility.bundle`. Only the native implementation
imports AppKit. The build integration must compile/package/sign this bundle
only for the explicit CLI automation build and omit it from production builds.

## Entry points and gate

The protocol has three methods:

- `init`: records whether the runtime test gate is satisfied. It does not inspect
  AppKit, register observers, or create an application.
- `snapshot`: returns an array of JSON-compatible dictionaries.
- `activateRequest:` / Swift `activate(request:)`: receives an exact snapshot
  path and label and returns a sanitized dispatch result.

Both operations independently require all of the following before AppKit
observation:

1. `--scriv-cli` is an exact launch argument.
2. `--screenshots` is an exact launch argument.
3. `SCRIV_CLI_RUN_ID` is a canonical 36-character UUID, case-insensitively.
4. The adapter was initialized with that gate satisfied.
5. The caller is on the main thread.

A gate failure never creates `NSApplication`, activates a window, changes a
permission, or traverses accessibility objects. The host remains responsible
for creating the isolated synthetic-data run before exposing CLI commands.

## Snapshot contract

A successful result begins with:

```json
{
  "kind": "context",
  "context": {
    "windowNumber": 123,
    "modalKind": "accessibility-modal",
    "modalPath": "native/window/123/ax/0/ax/2",
    "active": true,
    "activationAvailable": true
  }
}
```

Each subsequent `kind: "element"` dictionary contains:

- `path`: window number followed by deterministic accessibility-child indexes,
  the content-view edge, or view-child indexes. Paths are stable only while that
  public hierarchy remains unchanged. They contain no raw object addresses.
- `label`: the exact public accessibility label, not a normalized match. Protected
  and text-bearing elements have an empty label. Oversized or invalid labels are
  not returned or actionable.
- `role`: the public accessibility role, such as `AXButton`, or an empty string.
- `enabled`, `visible`, `labelSuppressed`, and `frameKnown`: observed metadata.
- `frame`: finite `x`, `y`, `width`, and `height` in AppKit screen coordinates.
  Unknown/invalid geometry is represented by zeroes with `frameKnown: false`.
- `actionable`: a preliminary button candidate in the active modal. A fresh
  public hit test and revalidation are still required before pressing.
- `inModalScope`: whether the element is inside the resolved current modal.
- `context`: the same window/modal context as the first record.

Without a public modal boundary, nodes remain available for diagnosis, but
`modalKind` is `none`, `modalPath` is empty, and no node is actionable. A
`kind: "diagnostic"` result instead carries
`error: {code, message}` with fixed, sanitized wording. Exceptions are never
serialized, and labels/request data are never interpolated into errors.

The API never reads accessibility values, text contents, selected text,
window titles, file/document URLs, authentication data, or target/action
handlers. `NSSecureTextField`, the public secure-text subrole, and public
protected-content metadata stop label and child traversal. Labels on all
text-field, text-area, and static-text roles are also suppressed.

## Scope, bounds, and modal fencing

Enumeration starts from the existing `NSApp`, never a process lookup or global
accessibility service. Only an own-process window present in `NSApp.windows`
can be selected. The adapter chooses the current application-modal window, or
otherwise the key/main window, and follows only its current attached sheet to
the innermost visible sheet. It does not enumerate other application windows,
menus, the desktop, or other processes.

Public `accessibilityChildren` is traversed first. Public `NSWindow.contentView`
and `NSView.subviews` supplement it. Pointer-identity cycle detection applies
across both traversals. A discovered object with a different declared window is
excluded. Limits are 64 own windows, 2,048 visited objects, depth 64, and 512
children per edge list. Reaching a limit fails closed rather than making a
partial tree actionable.

A current AppKit modal window or attached sheet supplies the outer action
fence. A visible public accessibility modal flag, sheet role, or dialog/system-
dialog subrole can narrow the fence further, including an in-window Catalyst
alert. Nested modal markers select the innermost marker. Unrelated simultaneous
modal markers are ambiguous and fail closed. A missing publicly exposed modal
boundary is a coverage gap, not permission to activate a background control.

Frameless accessibility containers do not automatically hide their children.
Explicit `NSView` hidden/alpha/clipping state propagates down the traversal;
buttons themselves still require positive finite geometry intersecting the own
window. An active key window, visible window occlusion state, an attached
screen, and a public hit test are required at activation.

## Activation contract

The request must contain exactly these two fields:

```json
{"path":"native/window/123/ax/0/ax/2/ax/1","label":"Add"}
```

The bridge retains only weak object references for the latest snapshot's
eligible buttons. Activation:

1. Requires the exact path and label from that snapshot.
2. Re-enumerates the public tree on the main thread.
3. Requires the same own window, same modal object/path/kind, and same target
   object at that exact path. A replacement button with the same label is not
   interchangeable.
4. Requires an enabled, visible, non-protected `NSAccessibilityButtonRole`
   element inside the modal, with public `accessibilityPerformPress` support.
5. Performs the own window's public `accessibilityHitTest:` at the center of
   the button's window-intersected frame. The result must be the exact button
   or one of its discovered descendants. This is an observation, not a
   synthesized mouse event.
6. Invalidates the snapshot before calling `accessibilityPerformPress` exactly
   once. Its actual Boolean return becomes `dispatched`.

Success is `{"dispatched":true}`. Failure is
`{"dispatched":false,"error":{"code":"...","message":"..."}}`.
A false press returns `press_unhandled`; an exception during the press returns
`press_outcome_unknown`. An unknown outcome requires inspecting the real UI
before considering a new action. No automatic retry is safe in that case.
There is no `performClick:`, target/action dispatch, private selector, handler
inspection, synthetic model mutation, or fallback route. A new explicit action
requires another snapshot after an attempted press.

Important diagnostic codes include `test_gate_required`,
`main_thread_required`, `active_window_unavailable`, `sheet_scope_unavailable`,
`modal_scope_ambiguous`, `traversal_limit`, `snapshot_target_required`,
`inactive_window`, `modal_not_exposed`, `modal_scope_changed`, `target_changed`,
`hit_test_unavailable`, `target_not_hittable`, `press_unhandled`, and
`press_outcome_unknown`. Missing public metadata can therefore leave a visible
button intentionally unavailable.

## Native acceptance still required

Native acceptance requires an authorized, correctly signed build. Do not bypass library validation or change signing/security settings to run this adapter.

Before treating this adapter as anything beyond diagnostic support:

1. Verify nested signing, successful bundle loading and the principal-class protocol cast using the isolated run gate.
2. Confirm a production build omits the bundle and does not load this adapter.
3. Verify every missing/malformed gate and off-main-thread call fails without
   AppKit observation or an accessibility permission request.
4. In the real synthetic alias alert, inspect Add/Cancel roles, labels, frames,
   enabled state, modal context, and public hit-test results. An absent node or
   modal marker is an unresolved native coverage gap.
5. Verify Add and Cancel separately, then assert the real UI and synthetic
   persisted package state. A true dispatch result alone is not an E2E pass.
6. Check disabled/hidden/off-window buttons, wrong/ambiguous modal scope,
   background duplicate labels, stale paths, changed labels, dismissed/replaced
   alerts, and repeated requests. No case may dispatch an unintended action.
7. Exercise secure fields and protected/text elements with sentinel content;
   neither snapshots nor sanitized errors may contain it.
8. Verify cycles and bounds fail closed, missing APIs do not trigger a fallback,
   and a false/throwing press is attempted once only.

Public API references:

- [AppKit accessibility](https://developer.apple.com/documentation/appkit/accessibility-for-appkit)
- [NSAccessibility protocol](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol)
- [Public modal metadata](https://developer.apple.com/documentation/appkit/nsaccessibility-c.protocol/accessibilitymodal)
- [Public protected-content metadata](https://developer.apple.com/documentation/appkit/nsaccessibility-c.protocol/accessibilityprotectedcontent)
- [Public accessibility press](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol/accessibilityperformpress%28%29)

## Current execution restriction

The direct scenario entrypoint is guarded too, and its AppKit fallback was removed. Portable Tracer checks verify those refusals only. This does not fix or retry Library Validation, and does not alter the native adapter, signing or security settings.
