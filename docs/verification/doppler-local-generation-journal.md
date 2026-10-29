# Native generation journal and recovery

## Implemented scope

- `GenerationJournal.swift` records intent atomically before a new usage-producing
  request. Journals live outside each runtime job's writable output directory;
  directory/file permissions are 0700/0600. Corrupt records are preserved and
  reported rather than hiding other recoverable jobs.
- Local records retain the initiating installation, original project/package,
  target-cue snapshot, source revision, prompt, selected model, reference file
  snapshots/checksums, actual runtime/thread/turn identities, progress, and output.
  These local records are **not** serialized as cloud requests.
- Restart, sleep and disconnect retain unfinished work as **Waiting for this Mac**.
  No reconnect, inspection or metadata recovery submits a model turn.
- **Inspect existing turn** uses `thread/read` against the recorded original
  runtime. A validated local file remains accessible as an explicitly labelled
  candidate even if that runtime's history is unavailable. A candidate's presence
  does not falsely mark the original turn complete. Artifact eligibility, image
  decoding and checksum are checked again before import.
- **Use in original project / Use local candidate** goes through the Store's
  original package/project, target and revision fences. **Finish shared status**
  reconciles an already imported output without duplicating its immutable image.
- **Retry** is an explicit, confirmation-protected *new job*, with a warning that
  the original turn may still run and additional Codex usage may occur. Original
  reference snapshots are checksum-checked before reuse.
- The job sheet has local and shared-project views. Shared metadata is limited to
  IDs, bounded safe progress/status, timestamps, source revision and accepted
  output identity. It contains no prompt, reference files, local paths, provider
  output, thread IDs or credentials. Other collaborators have no remote-run button.
- `CloudClient+Generation.swift` implements the backend's paginated, versioned
  create/read/claim/update contract. Store integration serializes metadata updates,
  rechecks ownership before attachment, retains outputs when the claim is uncertain,
  and reports cloud completion only after canonical image-manifest acceptance.
  Local engine completion, local import, cloud-manifest acceptance and hosted-image
  backup remain distinct events.

The backend contract and its focused evidence are documented separately in
[doppler-generation-jobs.md](doppler-generation-jobs.md).

## Checks actually performed

- Six focused `GenerationJournalTests` passed: round-trip/permissions, restart
  state, corrupt/identity-mismatched record isolation, unsafe reference/artifact
  paths, symlink refusal, and cloud-model separation from private local fields.
- The existing six `CodexGenerationTests` also passed during integration.
- Changed native sources passed Swift frontend parsing.
- Controller and generation-client extension passed supplementary Linux Swift
  typechecking against tiny compile-only framework/client facades and the actual
  portable ScrivCore module. This catches ordinary Swift type errors but is **not**
  Apple-framework typechecking or a macOS executable test.
- Whitespace validation passed. No live model turn, ChatGPT login, credential
  transfer, account mutation, paid generation, deployment or publication occurred
  while implementing this slice.

Actual macOS windows, authenticated Codex generation/cancellation, and multi-Mac
recovery have **not** been executed for these changes in this Linux workspace.
Those facts limit runtime evidence; they do not mean the journal/recovery controls
are placeholders or that another generation request should be made automatically.
