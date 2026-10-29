# Image prompt storage follow-up — 2026-10-29

## Clarified requirement and audited gap

The owner confirmed that only hosted image **binary bytes** are paid-only. Scripts,
authored timing and image prompts are cloud data for all accounts. The prior
published implementation (`eabdc538`) already synced scripts, timing and image
metadata for free personal projects, but attached only the manual direction to
generated images. The full assembled source/profile brief stayed in the local
job journal. That was a concrete gap, not evidence of effective-prompt storage.

## Implementation

- Existing image `prompt` remains manual direction/import description. Optional
  `generationPrompt` captures the exact text submitted to the Codex turn,
  including the generic wrapper and cue-scoped brief. This does not claim access
  to an image provider's internal prompt rewriting.
- The request uses the same captured string that is journaled before submission.
  Attachment and recovery copy that captured value to the resulting image
  identity/version; they do not rebuild it from a changed script. Explicit retries
  retain the captured request when available and create a new job/image version.
- Legacy/imported images and jobs without a captured submission remain genuinely
  unknown (`nil`/absent/null). A legacy retry can capture its new request, but
  recovery does not fabricate old provenance. Existing versions cannot acquire,
  lose or replace a captured prompt through an ordinary update.
- The native projection copies the captured text, not the private job context.
  It never injects package/runtime/reference paths, portrait bytes, account
  credentials or Codex thread/turn identifiers. Authored text itself remains
  exact, not redacted.
- Preflight rejects oversized text/metadata before new generation. The complete
  submitted text is limited to 30,000 UTF-16 units and the complete image item to
  64 KiB of encoded JSON. No silent truncation is used. Final image metadata is
  checked again before acceptance.
- Free personal and paid project command/snapshot/history paths persist both
  prompt fields. The existing paid-Team R2 upload gate is unchanged; storing
  image metadata neither uploads a binary nor creates an entitlement.

## Verification boundary

The local Worker tests exercise free scripts, authored word timing and both image
prompt fields through commands, real Durable Object eviction, snapshot reload,
event replay and historical reads. They verify immutable distinct image versions,
truthful legacy absence, scalar/UTF-16/encoded-byte limits, unchanged private
generation-job field rejection, empty R2/D1 asset storage and HTTP 402 for a free
binary upload.

Final follow-up checks passed: **189 portable Swift tests** (including eight new
prompt tests), syntax parsing of **83 Swift source/test files plus the icon
script**, optimized `ScrivCore` build, **188 local cloud tests** (including six new
prompt tests; one opt-in load test skipped), strict TypeScript, **21 Node tests**,
and repository/design preservation checks. The aggregate cloud log retains
existing workerd teardown exception output despite exit zero. Final native
source/test hashes were unchanged across the portable run. A separate read-only
review found no remaining concrete blocker after correcting a legacy manual-
direction fallback regression.

The prompt-aware Worker was deployed as version
`83ac3161-1fd4-4e1d-9070-f8a309cf84a6`; its downloaded module exactly matches
SHA-256 `7f62e02d56baf1663262e8799c0139a96a5f0ffb8be56c6f9c36c243d204114b`.
Health plus six negative security checks passed, with existing resources,
bindings, migration records and verified account data preserved. No further OTP
was sent for this follow-up. The new prompt validation was tested in the local
Workers runtime, not by a new authenticated production image write.

Local integration evidence is retained outside the repository under
`/workspace/shared/scriv-prompt-followup-20261029/`: native verification/source
hashes, cloud tests/typecheck, Node tests and immutable publication manifest.
Private authentication scripts, codes, verifiers and tokens are excluded. The earlier 19 authenticated production checks in the
[deployment record](cloud-deployment-20261029.md) establish actual email login,
cloud persistence and paid-binary enforcement on the earlier deployed version;
they did not run the new native prompt capture path. No live Codex generation,
native Mac compilation/runtime, screenshot parity or new multiplayer acceptance
was performed for this follow-up. Stripe remains deferred.
