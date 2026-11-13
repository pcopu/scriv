# Discussion anchors and canonical image threads

Run through the existing public entrypoint:

```sh
tracer app -- test services discussions-assets
```

The `discussion-anchor-cases.mjs` continuation adds 67 real local HTTP checks
after the existing 107 checks. It uses the same production Worker bundle and
owned isolated service process, with a separate synthetic personal project.
It imports no production helper or validation implementation into its oracle.
No live accounts, provider login, hosted service or native app is exercised.

The fixture creates a scene, a two-word dialogue entry, a three-version image
family, an independent two-version family and an unused image. It deletes the
unused image with a real lease. Expected item graphs, command receipts, event
fields and metadata-only tombstones are independently authored. Only generated
IDs and timestamps are read from responses, and their format or time bounds are
checked before incorporating them into an expected thread/event.

Ten rejected thread creations check exact HTTP 400 `invalid_anchor` responses:

- Non-array and over-1,000-element word selections, including the exact
  size-specific error body so duplicate/unknown IDs cannot mask a missing bound.
- Word anchors without an entry or attached to an image.
- Duplicate and unknown word IDs.
- Missing, non-image, deleted and different-family image versions.

Every rejection is followed by an exact public document snapshot comparison
excluding `leases`, and an exact full event-stream comparison. Public lease
list stability, lease-table internals and expiry are not claimed.

Three accepted threads preserve an explicitly ordered word selection, record
the selected leaf as an automatic image anchor, or accept an explicit version
from the selected image family. Thread fields, creation event contents, actor,
sequence, epoch and timing version are checked. Discussion edits do not alter
the independently expected document items or timing.

Reading and reopening the first image family's root, middle and leaf return
the same canonical thread. Reopening deliberately supplies another family's
anchor: the existing-thread lookup precedes new-anchor validation, so the
original thread/anchor is returned unchanged and no new event is emitted.
This is not a claim that invalid anchors are accepted for new threads.

One-thread pages verify exact thread-ID ordering, `hasMore`, `nextCursor`, and
the empty page after the last thread. Fresh snapshot/history reads verify that
lookups and pagination did not mutate document or discussion state.
The generated IDs do not guarantee that item-ID order differs from thread-ID
order, so this does not independently discriminate those two sort keys.

The continuation permits at most 100 requests, each with a 16 KiB request and
64 KiB response bound and a five-second timeout. The existing parent retains
its 90-second process deadline, sanitized environment, private temporary state,
loopback-origin checks, denied Worker outbound access and owned cleanup.

The separate proposal and step catalog describe this ordered HTTP chapter for
semantic review. They are not automatically registered runtime callbacks or
measured coverage. Only independently accepted associations may become manual
links. Do not claim corruption/cycle/depth handling, legacy fork selection,
1,000-word acceptance, lease expiry, concurrency, native UI or line/branch
execution from this chapter. Raw local evidence and session tokens stay out of
the repository.
