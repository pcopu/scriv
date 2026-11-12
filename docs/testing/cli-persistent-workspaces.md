# Owned synthetic workspace relaunch

Status: implementation candidate. Portable CLI checks run on Linux; native
compilation, Darwin descriptor inheritance/locking, UIKit cold reload and the
two-session LLVM capture still need verification on an authorized Mac build.
No passing native or crash-durability claim is made.

## Opt in without changing the default

```js
let session = await ScrivSession.launch(app, { persistent: true });
try {
  // Perform real app work, Save, and verify its persisted outcome first.
  session = await session.relaunch();
  // Reopen the existing project through its normal Projects UI before Save.
} finally {
  await session.close();
}
```

Ordinary `ScrivSession.launch(app)` remains fresh-only. The public control route
also supports `tracer app -- /path/to/ScrivAutomation.app --persistent-workspace`.
Its host JSON command `{"command":"relaunch"}` accepts no other fields.
There is no root/path/token argument for resume and no reset/delete command.
The ownership lease lives only in the calling process; closing the final session
releases its descriptor but leaves all workspace data intact.

Relaunch rejects overlapping/closed sessions, pending commands and timed-out
operations with uncertain outcomes. It captures the current coverage interval,
terminates and waits for the old app's confirmed exit, verifies the same app
executable hash and retained root identity, then starts the next process. A
failure is not retried and never falls back to a fresh replacement project.

## Containment and ownership

The app initially creates its UUID root exclusively under its own temporary
directory. For opt-in persistence, the host retains an O_NOFOLLOW directory
descriptor only after the real app confirms the root and mode. It verifies
canonical path, euid ownership, exact 0700, device/inode, the private single-link
0600 ownership marker, and the original lock/marker identities.

Resume passes the retained root as FD3, never as an arbitrary path. Before
UIApplicationMain, the app checks that descriptor against the exact derived
temporary-root inode, checks the immutable marker and existing Outbox, and
opens the existing session lock independently with O_NOFOLLOW. A nonblocking
exclusive flock is held for the app lifetime. Locking the inherited root itself
would not provide this protection because forked descriptors can share an open
file description.

The app then walks the retained tree using descriptor-relative opens, bounded
to 4,096 entries and 32 levels. Symlinks, hardlinked files, foreign ownership,
different devices, special files, special permission bits and group/world-write
permissions are rejected before repositories or generation journals start.
Nothing is repaired, chmodded, reset or removed by resume. Existing Outbox scope
creation still rejects EEXIST. Credentials remain process-memory only; network,
OAuth and peer transport remain disabled.

Canonical CLI roots are excluded from automatic stale-scratch pruning,
including roots with missing or broken markers. Invalid ownership must cause
rejection, not deletion. This may retain more temporary test data; there is no
automatic cleanup or newly authorized destructive reset.

This is a private same-user test-workspace boundary, not protection against an
actively malicious same-UID process that can rewrite files while the app runs.
Arbitrary externally supplied journals or filesystem roots are not authorized
by a matching filename or marker. No caller can supply them to the resume API.

## What the cold-film chapter proves if it runs

Verification startup intentionally keeps fresh preferences and skips automatic
startup recovery. Each new process initially displays a new **unsaved** sample.
The film scenario checks that disk still contains exactly its old sentinel and
film, opens the film through the actual Projects UI, then compares full models,
Date witnesses, picture bytes/decoding and available audio controls before Save.
This is cold package reload after an observed save, not crash recovery or a
claim about power-loss durability, automatic last-project restoration or audible
output.

## Separate measured process intervals

Workspace `runID` remains stable for existing path guards. `sessionID` changes
with each app process. Coverage records, slots and snapshots use the process ID
as their interval `runID` and retain `workspaceID` separately. Counter snapshots
are never subtracted or merged across processes; the first interval finishes
before termination and the next starts after its own handshake. Initial launch
and handshake remain outside each interval. Historical evidence is retained,
not rewritten to match current source.

## Portable diagnostic, not resume authority

```sh
tracer app -- workspace inspect /absolute/owned/root
tracer app -- test tooling
```

The read-only inspection checks host root/marker/lock metadata and returns no
lease. Its result explicitly says `resumeAuthorized: false` and native lock/tree
validation was not performed. Portable journeys use newly created synthetic
filesystem fixtures to check acceptance, symlink/hardlink/permission/marker
rejection, absence of path-based resume/reset/delete, and unchanged sentinel
bytes. They do not mock a native app or establish Darwin/native behavior.
