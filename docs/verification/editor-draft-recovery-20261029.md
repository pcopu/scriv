# Durable local editor draft recovery — 2026-10-29

## Behavior

The native editor journals each accepted text edit before applying it to the text view. Invalid authored timing leaves the editor open with the actual validation error; it never replaces the valid project or enters a cloud command. Switching projects, accounts, server origins or editor lifecycle retains the captured draft instead of redirecting it to the new context. Lease loss requires reacquisition before applying the draft.

Recovery lives in the app's `EditorDrafts` directory beside `Projects`, **not inside a `.scriv` package**. Each record is scoped to the canonical local package path, local project ID, cloud project ID, server origin, account ID and entry ID. Opening that same context and editing the line restores the text, source revision/entry/epoch and exact UTF-16 edit history. A recovered draft requires an explicit **Retry / apply draft**; blur alone does not apply it.

If the saved source entry or epoch changed, application is blocked. The editor shows the current saved line and an explicit **Use current line as base for this draft** action. Rebasing preserves current timing and conservatively re-proposes character links in replaced text rather than guessing which repeated name retained its identity. It does not apply the text. A missing/deleted source is never recreated or retargeted; its journal remains retained.

Recovery is removed only after the valid canonical snapshot has successfully saved to disk, or after the user confirms **Discard local draft**. A revision token prevents an older save callback or editor from clearing/replacing newer typing within the serialized app actor. This is not a cross-process locking guarantee. Disk-save failure retains recovery even when the valid edit already appears in memory.

## Bounds and failure behavior

- At most 2 MiB per record, 64 MiB total and 128 records; full storage refuses a new edit without evicting other drafts.
- At most 1,024 exact edit events; longer histories compact into a conservative whole-text replacement so ambiguous character identities require review.
- Atomic file replacement; directory/file modes 0700/0600. Symlink, corrupt, mismatched and oversized records are refused and retained, not silently overwritten.
- Draft snapshots contain local authored text and context only. No draft journal is included in CloudCodec, cloud outboxes or project export. Renaming/moving a package changes its recovery scope; return to its original location to recover that scope.

## Evidence

`build/swift-editor-drafts/focused.log` records **37 passing portable tests**, zero failures, at 23:08 UTC: 11 EditorDraftJournal tests plus 15 CharacterMention, 8 WordTimingEditing and 3 LocalEditIntent tests. Cases cover relaunch round-trip, Unicode/native edits, account/origin/package/project/entry separation, invalid authored timing without canonical mutation, source/epoch drift, repeated-name identity, conservative rebase/compaction, deleted source, stale completion, quota/corrupt/symlink preservation, and canonical disk-save failure.

`build/swift-editor-drafts/syntax.log` records Swift syntax parsing for the changed core/test/native files. Parsing and Linux core tests do **not** establish AppKit/SwiftUI type-checking, rendered controls, IME/native focus behavior or actual Mac interaction. Those native acceptance checks remain separate. No Mac execution, publication, Actions change, deployment or live account call was performed by this implementation owner.
