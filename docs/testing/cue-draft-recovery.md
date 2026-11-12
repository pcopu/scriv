# Cue draft recovery journey

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

The journey uses the existing public optional-direction text field, real local
journal, owned persistent relaunch and normal Projects browser. Its independent
input is 29,999 ASCII characters plus one two-unit emoji: 30,001 UTF-16 units,
but only 30,003 UTF-8 bytes. It fits the private draft journal and fails the
canonical direction's 30,000-unit bound deterministically. There is no timing
race against the 300 ms autosave delay: wait for the actual rejection first.

The five stages are retention after rejection; cold recovery; repeated cold
recovery; correction and one canonical revision; and a final clean cold reopen.
Assertions compare the entire saved sentinel and target projects, actual loaded
model including exact Date witnesses, complete retained draft bytes across two
new native processes, exact Unicode field text and refusal message, and final
journal removal after a successful save. The third reopen proves the correction
loads without resurrection. No Generate or clipboard action is invoked.

Host filesystem reads are explicitly separate evidence: they observe only the
app-created CuePromptDrafts under the session-confirmed owned synthetic root.
They never inject a journal, calculate a production hash, create a model through
Swift, alter ownership markers, or modify app data. Inputs and expected canonical
changes are fixture-owned JavaScript values; native outcomes come from the public
CLI and existing saved/loaded observers. Every session closes in finally; the
public persistence API deliberately preserves temporary data rather than deleting
an arbitrary tree. No external services or installed-app replacement occurred.

## Integration

Copy only the new journey and this document into the parent's tree. Supporting
CLI/helper copies under this worker's source directory are unchanged context,
not replacements. The runner dynamically discovers regular .mjs entrypoints in
`tests/e2e` and `tests/e2e/journeys` (scripts/run-cli-e2e.mjs:109-115). No fixed
registration is needed. Verify `tracer app -- test --list --scenario
journeys/cue-draft-recovery` returns the matching ID and path. After integration,
use `tracer app -- test --scenario journeys/cue-draft-recovery --app BUNDLE` with
a matching verified automation build on macOS. Do not run the test directly for
native evidence. Dynamic paths/buttons are covered by whole-journey identity.
The evidence proposal is semantic-review input, not an importable reviewed map.

V2 waits on the public snapshot until the initial optional-direction field is
mounted and editable before reveal; the text mutation is still issued once.
Cold-open prompt visibility/editability, Unicode text and owned relaunches were
checked on the isolated real build. The corrected open helper waits for the
matching workspace header to be enabled and hittable before loaded-project: the
model title can change before the Projects browser dismissal has completed. A missing/hittability/disabled control causes failure; no
fallback private handler, alert dispatcher, alternate provider, or widened guard.
The host returns an error on an uncertain mutation and never retries it.

## Remaining save/script recovery gaps

PendingProjectSaveJournal is still an explicit gap. WorkspaceStore normal
`open` calls `recoverPendingSaves` (1796), and queueSave may replay records (893),
but verification bootstrap returns before automatic startup inventory (711-725).
ScrivSession.relaunch (cli/scriv.mjs:136-148) finishes coverage, terminates and
confirms exit before restarting its retained descriptor; it is not a controlled
crash between journal acceptance and canonical save. There is no public owned
pause/stage-journal boundary or crash checkpoint. stage-package-fixture accepts
only its two finite image/character packages (ScrivCLIPackageFixture.swift:38-41),
not recovery records. Do not inject arbitrary journals and claim existing resume
ownership authorizes them. A future separately reviewed finite recovery fixture
stager would need canonical-before + pinned journal records, descriptor-relative
ownership checks, idle scope, explicit package identity, no supplied paths, no
network, and independent before/after/history/acknowledgement oracles. That is a
new public control proposal, not implemented here; no production fault hooks.

EditorDraftJournal likewise has no prepared claim here. ScriptDraftSession
synchronously journals accepted edits (56-63) then schedules apply after 200 ms
(127-134). Review draft is shown only for a pending session
(ScriptScreenController.swift:386-391), and `script-insert` readiness excludes
requiresReview/issues (555-568). Race-to-review or race-to-relaunch is not a
reliable recovery fixture. A separately reviewed bounded UI "keep current edit
for later" operation, or finite owned prelaunch fixture control, could provide a
deterministic state without changing autosave timing. Whether another valid
production refusal can reliably create that state requires further research.
Existing generic type must not become a fallback around a denied insertion.

Neither this cue journey nor those options establish journal CAS contention,
malformed-record rejection, cross-account replay, symlink rejection, disk-full
behavior, initial-save loss, history acknowledgement or physical crash durability.

The scenario requires an empty journal after a successful save and clean reopen. It does not provide fault-injected proof that deletion can never occur prematurely.
