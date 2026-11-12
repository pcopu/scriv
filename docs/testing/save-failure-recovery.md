# Public save refusal and recovery

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

This candidate saves the sample sentinel and imports a synthetic fixture through
the public CLI, then edits Mara's biography through Characters and Save character.
Before Save, it removes only owner-write from that verified synthetic package's
existing history directory. Read/search remain; the root, ownership markers,
Outbox, lock identities, project file and private journals are never modified by
the host. A retained no-follow directory descriptor restores the exact original
mode in finally. It refuses root execution, writable ACL outcomes, unsafe types,
symlinks, special permission bits and foreign ownership. There is no user path
parameter or permission escalation. The synthetic workspace is preserved.

## Static feasibility and limits

WorkspaceStore.change (843-876) validates, synchronously journals, publishes the
accepted model, then queues save. persistAcceptedChange (799-803) writes outside
the package into PendingProjectSaves. queueSave (877-911) plans/replays the exact
record and reports a failure without acknowledging it. ProjectRepository's lock
(63-77) remains accessible because only history lacks write permission;
DurableDirectory.create does not chmod existing directories. saveLocked writes
history atomically before project.json (111-112). Making project.json read-only
alone would be ineffective: atomic replacement depends on the directory.

The candidate dispatches Save character once, without the helper's usual wait
for a hittable catalog behind a modal error. It waits for the actual Scriv save-error
alert for the synthetic project title, with exactly one enabled OK action, a
window-attached view and completed presentation. It rejects unexpected alerts.
It then observes the failure-status text and absence of the character Name field
through the read-only snapshot. This is controller/view-state evidence, not pixel
visibility or proof of an available alert-input route. It never dismisses the
alert, invokes a private handler, or calls a native-accessibility fallback.

The candidate requires
complete package-file nonmutation, exactly one naturally authored pending record,
and the entire accepted model equal the independent biography-only expectation.
Only the observed finite nondecreasing modifiedAt is allowed as variable input.
No production hash algorithm is duplicated: hash shapes are inspected, while
exact record.after, source revision, scope and subsequent replay are asserted.

ScrivCLIRunCapability.validate (229-249) validates the root/control descriptors,
not every package descendant. Resume's validateDescendants (176-214) does require
owner rwx on directories, so exact permission repair must happen before relaunch.
This is not a bypass: the resumed tree must satisfy the unchanged native guards.
The character editor must have closed before repair, with no script/cue draft to
retry. WorkspaceStore forwards the failure's errorMessage to
WorkspaceErrorPresenter, which queues the real alert. After exact permission
repair the journey verifies the same alert is still presented and uses the
existing owned-process relaunch without interacting with that alert.

Relaunch sends SIGTERM and can fall back to SIGKILL after five seconds. The current
session API confirms process exit but does not expose its mode. This scenario
therefore makes no graceful-exit, UIKit lifecycle-callback, crash or power-loss
claim. After that owned-process relaunch and BEFORE clicking normal Open project,
the test requires byte-identical original packages and pending records. Any
prior retry that changes them makes this test FAIL; it cannot receive normal-open
recovery credit. Verification startup skips
auto-recovery. Normal WorkspaceStore.open (1794-1800) awaits prior tasks, calls
recoverPendingSaves, then loads. The journey checks the exact accepted model/date
witnesses, pending removal, one new history snapshot, preserved prior history,
all sentinel bytes, and a second cold reopen with no additional writes.

Unexpected failure alerts cause an explicit stop. The expected alert is observed
and retained until the old owned process exits. Public status-label exposure, editor readiness, alert transitions, atomic-save failure behavior, Date serialization and resumed app behavior need matching native acceptance.
Normal opening waits for the matching workspace header to be enabled and
hittable before loaded-project, preserving the browser presentation guard.

## Integration and validation

Integrate only the new journey, this document, and prepared save-failure-recovery
catalog/proposal.
The named-step catalog uses whole-journey actions and bounded assertions; proposals
are unreviewed and must not be imported into the reviewed sidecar automatically.

Run via `tracer app -- test --scenario journeys/save-failure-recovery --app BUNDLE`
only on an authorized matching automation build. Syntax, case discovery, Tracer
catalog/proposal checks and front-door list discovery are portable authoring
checks, not app execution. No live-service or distribution acceptance is implied.

Excluded: power-loss/crash durability, physical disk full, fsync failure,
malformed or over-capacity journals, competing processes/CAS, cross-account replay,
initial-project loss and already-saved journal acknowledgement. The prepared
single-record continuation is not a claim about every recovery branch.
