# Public alert presentation observation

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

`presented-alerts` is a parameterless, read-only diagnostic in the isolated,
compile-gated automation app. It walks only the already-owned UIKit controller
hierarchies and reports presented `UIAlertController` title, message, style,
action titles/enabled state, transition flags and whether its loaded view has a
window. It does not force a view to load.

This is public controller presentation state, **not rendered pixels, native
accessibility reachability or proof that a user can activate an action**. It
neither loads the AppKit helper nor invokes action handlers, dismisses alerts,
changes permissions, queries other applications or reads store error variables.

## Current route audit

The current implementation does not add an alert-dispatch command, modify
UIKit alert presentation, retry the native helper or weaken signing/security.

- Alias Add/Cancel are `UIAlertAction` objects in `CharacterEditorController`.
  The current `activate` and
  `accessibility-activate` commands can only use real observed qualifying views.
- The Script menu contains Rename/Delete scene actions, but the guarded
  `script-scenes` CLI scope accepts only New scene and existing-scene selection.
  These actions therefore stop before presentation; widening that scope would
  not by itself create a confirmation route.
- The real history Restore revision button can present its confirmation.
  Its Cancel/Restore actions have the same unverified alert-action route.
  Selecting arbitrary history table rows is also not implemented by the
  collection-cell-only activation branch.
- The unsupported AppKit fallback is not available. The CLI marks the alias candidate blocked, never spawns it in mixed
  runs, and refuses alias-only requests before app inspection/launch. Its direct
  entrypoint is also guarded, and the AppKit fallback has been removed.
  This restriction has no command-line or environment bypass option.
- `keys` only lists registered, enabled responder-chain `UIKeyCommand`s; no
  app-defined alert confirmation/cancellation command was found. Do not infer
  Return or Escape support. Public metadata and container accessibility objects
  do not automatically provide a dispatchable UIView control.

`UIButton.sendAction(UIAction)` on an existing menu is not an invocation API for `UIAlertAction`. Extracting closures, inventing selectors, invoking private handlers or substituting store changes would not constitute UI coverage. No such workaround is used.

The continuous film instead edits a linked character through the existing
ordinary editor, restores a draft before clean Cancel, commits the rename, and
checks stable source/media identities plus reopened UI labels. That is a
native-unverified candidate on existing routes, not alias, scene-rename,
history-restore or alert-cancellation parity.
