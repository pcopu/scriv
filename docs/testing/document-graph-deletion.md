# Connected document deletion and replay

Run `tracer app -- test services document-integrity`. Original lines 1–195,
22 named callbacks and 68 HTTP checks remain unchanged. The appended chapter
adds 12 real local HTTP checks for 80 total within the original request cap.
Production handlers, live lease checks and the owned-process bounds are unchanged.

After the original valid metadata edit, acquire the missing scene lease and
observe five live public edit leases. Attempting to delete the referenced
character alone returns exact 409/item_in_use and preserves the nonlease snapshot
and entire event response. Multiple character-reference types coexist here;
this does not independently isolate every reference-source branch.

Reuse the refused command ID with a corrected five-item delete. The submitted
order places the scene, character and image before dependent entry/cue items.
The completed command is validated as a whole and succeeds. Its receipt has all
five incremented tombstones in operation order. Snapshot has no live items,
five exact tombstone identities/versions with empty data, and canImport false.
Only one sequence and timing-version increment occur, with unchanged epoch.

The event journal retains its two original events plus one exact command event
containing all five complete before/after changes in item-ID order. Actor,
command ID, label, counters and request-bounded timestamp are checked. An exact
same-user replay returns the original receipt; snapshot/history are unchanged.
R2 remains empty and all unexpected outbound is denied.

These are sequential public-state observations. Snapshot equality excludes the
time-sensitive leases field. Receipt rows, word-owner indexes, other internal
stores, failure-injected atomicity, concurrent races, expiry, restart/crash
persistence and native behavior are not tested. Current snapshot redacts deleted
content, but authorized event history and receipts intentionally retain it;
this is not permanent erasure or a global privacy claim. No physical image,
provider, payment, real account or private user data is involved.

Original runtime instrumentation reports its 22 callbacks. The separate
document-graph-deletion-evidence entry reports the additional 12 HTTP checks.
Semantic review, manual mapping, service execution and native acceptance remain
separate. Original catalog/proposal/documentation and production source are
preserved; the new contract documents only this added chapter.
