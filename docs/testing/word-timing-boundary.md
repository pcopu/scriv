# Word timing editor journey

Status: source only; native build and interaction assertions pending.

AUT-J15 uses the real embedded Layers word UIButton and its stored secondary
menu action. The test-only dispatcher accepts the exact single enabled action
and verifies owning controller/store/window, unique dialogue word text, local
idle state and isolated package identity. It dispatches that original UIAction
once through its original button. It does not open a native menu, invoke a
private handler, call a store setter or emulate hardware input.

Draft observations permit only the exact directly presented WordTimingEditorController
form sheet, with the same store/navigation/current scene, no child or nested
presentation, and linked windows in the same owned UIWindowScene. A compile-gated
read-only scene witness exposes no mutable draft data. The ordinary private-root
and package checks remain mandatory. Pending draft values are not compared to
the model as an access condition, so unintended model changes remain observable.

The literal WordTimingEditingTests.swift::0001 fixture edits w2 from 1000–1600 ms
to 1700–2100 ms through real numeric controls. Its eight visible outcomes, full
saved/loaded model, nil links, exact Date witnesses and reopen are checked.
Cancel and invalid overlap are strengthened UI coverage. UI Save uses the plural
production setter; this is a candidate behavioral witness, not proof of the old
singular setter's implementation branches. The populated audio and singular
rejection prerequisites of ::0002 are not replaced. No legacy removal is allowed
before native evidence and independent assertion acceptance.
