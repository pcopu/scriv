# Storyboard merge: semantic CLI scope

`menu-action` with scope `storyboard-merge` accepts only `Merge with next placement` from the original mounted Storyboard ellipsis UIButton menu. The generic driver first requires a unique, interactive, enabled, hittable target. The scope then checks exact request keys, the local synthetic run, current workspace/store/navigation, idle state, original menu identity, current card/rebuild signature and adjacent-placement eligibility. It validates again before sending the original UIAction once through public UIButton dispatch.

This tests semantic dispatch from an actual stored menu action. It does not open or select a native menu physically. It neither reconstructs a handler nor directly mutates the model. Unknown actions and extra request fields fail closed. Remove and confirmation dialogs are unsupported.

The authored journey imports synthetic audio and distinct image bytes, merges neighboring anchored cues, checks the complete expected transaction and retained assets/text/words/audio, rejects wrong or disabled requests, and checks Undo/Redo and browser reopen. It does not yet establish unrelated-scene behavior, complex version ancestry or the full legacy add/delete/merge sequence.

Independent source and dispatcher review passed. Native compilation and execution are pending; no legacy test retirement follows from this document.
