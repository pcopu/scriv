# Current Scriv source handoff — 2026-10-29

## Included implementation

The prior completed workspace integration is published at [6a846898](https://github.com/pcopu/scriv/commit/6a846898a13dddf8e2d7b75b48b1ef14a387c1ed): native editing and team controls, collaboration/access fencing, real package-local imported audio and measured waveform playback, project-member mentions, retained image conversations, historical preview/restore, and durable local generation journals with shared metadata. Audio remains local; cloud/P2P media transport remains image-specific.

The subsequent user-approved intent corrections are assembled on top:

- **Source-owned pictures:** a stable script-entry anchor and authored forward extent move with their source rather than becoming fragments owned by covered entries. Overlap, scene-tail clipping, zero-owned sources and historical restoration are explicit. See [source-owned timing](source-owned-timing-20261029.md).
- **Authored word timing:** exact word endpoints and contiguous-phrase shifts change speech timing independently from image-cut drags. Authored pins survive compatible text edits; impossible changes fail without mutation. Imported audio is not silently aligned or stretched.
- **Stable inline identities:** persisted character annotations retain identity through profile/alias changes. Legacy guesses require review; corrections and explicit unlinks preserve exact script text. See [character links](../character-links.md).
- **Script-aware generation:** the selected cue's actual word interval, active forward directions, relevant confirmed identities and available relevant portraits form the disclosed local brief. Only an explicit visual override enters shared image metadata; the full prompt/reference snapshots stay in the local generation journal. See [Codex integration](../codex-integration.md).
- **Larger atomic edits:** bounded staged commands retain a durable operation identity and commit the complete validated edit once, rather than splitting it into partial visible mutations. Role, lease, version and timing fences remain enforced. See [cloud API](../cloud-api.md).
- **Live editing and presence:** native text-change events feed coalesced leased updates and actual cursor/selection positions, while pending local edit intent survives acknowledgements and remote snapshots. Presence delivery separates changed peers from periodic recovery state. Multiplayer acceptance is explicitly deferred for the current single-user delivery.
- **Durable editor recovery:** invalid text is journaled before native acceptance, outside project/cloud packages. Failed validation stays open; navigation/restart retains exact drafts; source/epoch drift requires explicit review. Only successful canonical disk save or confirmed discard clears recovery. See [editor recovery](editor-draft-recovery-20261029.md).
- **Email-first accounts:** the native account, Settings, project and team surfaces use PKCE-bound single-use email codes with expiry, resend, attempt/rate limits and owner-scoped cancellation. Existing GitHub identities remain supported separately, never auto-linked by contact email.
- **Final recovery safeguards:** known transactional validation/budget rejects archive the exact outbox payload without blocking corrected drafts forever; stale snapshots cannot regress newer receipt/history state.

## Evidence and release boundary

The final frozen source passed **181 portable Swift core tests**, parsing of **81 Swift files plus the icon script**, an optimized `ScrivCore` build, **182 local cloud tests** (one opt-in load skip), strict TypeScript checking, a Worker dry-run bundle/preflight, **21 Node tests**, and repository/design preservation checks. All 107 guarded native/script/test source files were unchanged across the final portable run. These are Linux/source checks, not native Mac verification. See the [final integration record](final-integration-20261029.md) for logs, qualifications and the actual failed peer run.

The real Chromium peer run passed one of nine tests; eight timed out with ICE/channel setup incomplete. That is not a peer pass. Multiplayer is outside the current acceptance scope and was not retried or used to block the single-user deployment. The passing cloud suite retained workerd request-stream/teardown exception output.

The backend is deployed with D1, private R2, SQLite Durable Objects and the restricted login-email sender. The [deployment verification](cloud-deployment-20261029.md) distinguishes service checks, code-send acceptance, actual delivery and completed user-code/session acceptance. Stripe remains explicitly deferred; existing paid-access gates are unchanged.

Historical native CI, universal app binaries and committed screenshots belong to runtime `0eb779b`; they do not certify this newer source. Native AppKit/SwiftUI compilation, actual app interaction/rendering, live Codex generation, multi-Mac recovery, signing/notarization and current screenshot parity remain unrun. No hosted workflow was edited or dispatched and no user Mac was used. Publication commits use `[skip ci]`.

All 25 original concepts, three sample frames, historical evidence and the exact root `transcript.MD` are retained. The [deployment handoff](../deployment.md) records the actual configured service and remaining acceptance gates rather than claiming a fully accepted native release.
