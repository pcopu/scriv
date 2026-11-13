# Scriv Agent Guidance

## Work Status, November 13, 2026

The user asked to finish the current four-module measurement increment, test and
commit/push its changes, then stop Scriv work. This supersedes the earlier
open-ended coverage push below. Do not start another increment under that prior
request. The 100% goal remains historical context, not a completion claim or
permission to resume work without a new user request.

## Tracer

Use the Tracer skill and CLI for testing and source/action/journey mapping;
maintain the reviewed links as code and journeys change. Run real app journeys
through `tracer app -- test`; keep mapping, tooling checks and native results
distinct. Do not add new implementation-level test suites. Legacy implementation suites were removed at the user’s explicit request on
2026-11-09. Keep CLI journeys only, including black-box local service journeys
through the Scriv CLI. Preserve the frozen baseline ledger and unverified gaps;
removal is not evidence of behavioral parity. See docs/testing/cli-only-tests.md.

## Coverage Goal, History and Reporting

The user's goal is **100% overall Tracer coverage**. Continue implementing,
auditing and running meaningful CLI scenarios toward that goal; do not stop at
planning coverage or manufacture links, exclusions, passing results or runtime
evidence to reach a percentage. Report each metric with its source checkpoint,
numerator, denominator and scope. A missing execution measure is unknown, not
zero. Never replace a completed milestone with a differently scoped low number.

The November 10, 2026 Scriv planning pass reached **100% audited scenario
planning: 30,675 of 30,675 included lines, 551 associations audited, and 186 plans
corrected and independently rechecked**. This is a completed milestone. The
separate 9.62% figure at that checkpoint described existing witnessed manual
links, not the audit's completion. The corrected plan had 513 scenario plans
still requiring implementation or extension. Later changes marked nine
associations for renewed semantic audit. The preserved evidence is in
`docs/testing/proposed-scenario-map.json`: `provenance`, `correctionLayer` and
`integrationDelta`. Saved totals describe historical checkpoints; recompute
current reports instead of presenting those saved totals as current execution.

At public commit `5239091c47639eeecfaf67f26971bc3200f5fd70`, Tracer 0.3 reported:

- Current categorization and proposed associations: 30,748/30,748 included lines
  (100%), across 223 files. The current proposal contains 552 associations and
  513 plans; current integrity does not establish a fresh semantic audit.
- Witnessed manual links: 4,508/30,748 (14.66%); 26,240 lines below the one-trace
  minimum. All 1,897 links and 1,211 comment declarations passed integrity checks.
  These are source-to-assertion associations, not observed execution.
- Independent permitted retest: nine isolated service journeys and 17 tooling
  checks passed. Document integrity included 223 HTTP checks, 56 in its timeline
  continuation. Do not imply the four excluded auth/team journeys ran.
- Earlier selected native batch on `f68408d` passed 39/39 eligible journeys on a
  local ad-hoc automation build; character aliases remained blocked. This was
  not a new native run on `5239091` or proof of release signing.
- A real instrumented workspace interval on `e9819de` imported successfully:
  150 app/Core source files, 21,667 recorded instrumented lines and 1,736 lines
  whose counters increased. This 8.01% interval observation is **not an overall
  project coverage percentage**. Other app journeys and uninstrumented helpers,
  runtime/browser code, backend and other languages remain outside that capture.
  Build binding was producer-declared, not cryptographic attestation.

Keep the overall witnessed-mapping goal, real scenario assertions and measured
runtime evidence separate. Use `tracer report --json`, `tracer check
--require-minimum --json`, and `tracer proposal report --file
docs/testing/proposed-scenario-map.json --json` for current mapping/accounting.
Use `tracer --root EXTERNAL_ANALYSIS_ROOT measure report --json` and `measure
check --json` for captured intervals. Do not sum repeated interval denominators
or observed lines as unique project coverage. Uninstrumented code is unknown.
Keep private profiles, datasets, logs, user data and local evidence out of Git.

The existing update-service CLI journey also supports opt-in cumulative Worker
measurement. Read `docs/testing/update-counter-coverage.md` before using it. Its
denominator is selected statement-entry anchor lines in one JavaScript Worker,
not all Worker lines or the whole project. Preserve real before/after snapshots,
strict source/probe identities and external analysis storage. Keep its measured
interval separate from manual links, historical planning and native results.

The generation-service CLI journey also offers opt-in counters for selected
statement entries in four routing/access/HTTP/generation modules. Follow
`docs/testing/generation-counter-coverage.md`. Preserve its exact TypeScript
build graph, per-module generations, cumulative baselines and external evidence.
Collected module instances do not establish main-fetch-only attribution, Durable
Object-instance, other-isolate, entire-backend or overall project coverage.

## Test and Fix Batches

Finish the available authorized testing first and collect all findings. Fix the
surfaced defects as one coherent batch, run applicable checks and review it,
then publish that batch and have the independent tester rerun the exact tree.
Only then resume the next coverage expansion and repeat. Do not return to
per-issue commits. Preserve unrelated work and existing evidence; never
force-push or change GitHub Actions as part of this workflow.

Keep explicit exclusions and blockers visible: login/auth/team work remains
excluded unless the user changes that scope; the character-alias AppKit fallback
must not be retried after its Library Validation denial without a permitted new
route. Do not bypass signing, network or sandbox restrictions. Ad-hoc testing
does not establish Developer ID/helper trust, notarization or release readiness.
Keep strict build-source manifest checks. Measurement output must be separate
from pinned source so a successful import cannot invalidate the next run. Never
delete evidence, regenerate build-source hashes or add blanket exclusions to
make an identity mismatch disappear.

## CLI-Only Apple Builds

The user wants to keep Xcode.app and simulator runtimes uninstalled on this
Mac. Reuse the standalone Command Line Tools and separately retained Apple
SDKs. Do not reinstall Xcode or simulators as an automatic response to a build
failure. Running `xcodebuild` from a terminal still requires Xcode.

Scriv's application is UIKit with Mac Catalyst. The old AppKit/SwiftUI target
and its packaging path were retired on 2026-11-09. `apps/mac` still contains
live ScrivCore, shared services and resources required by Catalyst; do not
delete that directory. Preserve the cloud server, updater and runtime helper.
See docs/verification/appkit-retirement-20261109.md for scope and recovery.
`scripts/build-catalyst.sh` currently calls `xcodebuild`, so it does not yet
provide a complete Xcode-free build.

## Existing Catalyst Signing Workflow

The November 11, 2026 Apple Silicon automation build used standalone Apple
Command Line Tools and the existing Developer ID Application identity in the
Mac keychain. The retained build's signature verified on November 13 and has an
Apple timestamp. It is a non-distributable automation candidate, not proof
that a later source tree was signed, notarized, or tested.

For this incremental build, use `scripts/rebuild-catalyst-cli.py` with a
verified existing Scriv app template and the matching Sparkle development
framework. It requires a new output bundle, a separate work directory, a
signing identity, version, and build number:

```bash
python3 scripts/rebuild-catalyst-cli.py \
  --sparkle-framework "$SPARKLE_FRAMEWORK" --template "$SCRIV_TEMPLATE" \
  --output "$NEW_APP" --work "$NEW_WORK_DIR" --identity "$SIGNING_IDENTITY" \
  --version "$VERSION" --build "$BUILD"
```

The script checks the template and Sparkle identity, compiles the app, Core,
native update adapter and runtime XPC, and signs nested Sparkle components,
plugin and XPC before the outer app. It checks the complete signature, icon and
Catalyst platform. Add `--automation` only for isolated automation testing;
never distribute an automation build. For local-only automation, `--identity -`
uses an ad-hoc signature with no team identity; it does not prove Developer ID,
Keychain or trusted-helper behavior, notarization, or release readiness. On
2026-11-13 that route built the verified f68408d source, passed the script's
signature and icon checks, and passed the native project-roundtrip journey.
Confirm the exact source tree and all
build inputs before attributing a build to a commit. Keep keys, credentials,
local evidence and generated bundles out of the repository. An `asc` login
does not replace the local signing identity or the Apple timestamp service.

On November 13, 2026, a fresh component signing attempt and a separate minimal
Developer ID signing probe failed with “A timestamp was expected but was not
found.” The cause was not established. Do not disable timestamps, weaken
security, or present a partially signed bundle as verified to bypass the
failure. Report compilation, signing, native behavior, notarization, and
distribution as separate outcomes.

## What Has Been Verified

The 2026-11-03 investigation compiled and linked these temporary programs with
Xcode removed and `/Library/Developer/CommandLineTools` selected:

- Swift/UIKit and Objective-C Mac Catalyst programs using the CLI macOS SDK's
  `System/iOSSupport`, targeting `arm64-apple-ios17.0-macabi`.
- SwiftUI, Swift/UIKit, and Objective-C physical-iPhone programs using a saved
  iPhoneOS 26.2 SDK, targeting `arm64-apple-ios17.0`.

These were compiler/linker checks. A complete Scriv app, resource compilation,
device installation, and App Store/TestFlight distribution were not verified.
No xtool installation or build-pipeline migration was performed.

## xtool Route

`xtool` builds SwiftPM-based iOS apps and provides packaging, signing, and
device-installation commands. It is the CLI route to investigate, with these
setup and acceptance steps:

1. When setting up the tool, install the upstream Homebrew package and discover
   the actual executable path rather than assuming it is already installed:

   ```bash
   brew install xtool-org/tap/xtool
   command -v xtool
   xtool --help
   xtool dev build --help
   ```

2. Configure and verify an Apple SDK/toolchain compatible with the build host.
   Apple's iPhone SDK still comes from an Xcode distribution, but the necessary
   files can be retained separately. The standard xtool macOS setup assumes
   Xcode is installed and skips standalone SDK installation; installing xtool
   alone does not configure this Mac for Xcode-free builds. Its Linux/WSL SDK
   extraction workflow is documented upstream. A standalone macOS SDK
   configuration still needs implementation and verification.

   A saved producer archive is available at
   `~/Documents/Codex/2026-10-22/task-4/sdk-transfer/xcode26.2-xtool1.22.2-input.tar.xz`.
   Its SHA-256 is
   `2b4c9c504e5e70ea3b0996b160f662594a4b08d3cb9517613c0430107c30e4ff`;
   the adjacent `manifest.json` describes its contents. Verify that checksum
   before extraction. This is pruned Xcode producer input, not a ready-built
   Darwin Swift SDK: do not pass the tarball directly to `xtool sdk install`.
   Keep SDKs, compiler caches, and generated apps outside tracked source.

3. After SDK configuration works, first prove the released iOS workflow in a
   separate scratch SwiftPM project, outside this repository:

   ```bash
   xtool new XtoolProbe
   cd XtoolProbe
   xtool dev build --ipa
   ```

   This checks packaging; the default build is not distribution-signed.
   `xtool dev build --sign --ipa` requires authentication and signing setup.
   Use `xtool auth` for interactive setup, keep credentials out of chat/source,
   and reuse existing signing identities where possible. With pairing,
   provisioning, and iPhone Developer Mode configured, `xtool dev` builds and
   installs the scratch app on a physical device. Verify that it launches.

4. Treat Catalyst support as a separate gate. As checked on 2026-11-03,
   [upstream PR #362](https://github.com/xtool-org/xtool/pull/362) is open and
   unmerged. It proposes Mac Catalyst support; it does not add an Xcode project
   importer, asset compiler, or App Store distribution workflow. Recheck its
   merge/release status and limitations before choosing a tool version. Do not
   describe the released iOS recipe above as an established Scriv Catalyst build.

## Scriv Migration Requirements

- Replace the existing Xcode build steps only after tracing the generated
  targets and dependency graph in `scripts/generate-catalyst-project.py`.
  Preserve UIKit, shared `ScrivCore`, copied resources, and package dependencies.
- Build and bundle the native update plugin, Sparkle components, and runtime
  bootstrap XPC service with their correct macOS/Catalyst boundaries.
- Supply asset/resource tooling. `actool` and `ibtool` are absent from the
  standalone CLI tool directory. Preserve the approved icon and the checks in
  `scripts/verify-catalyst-icon.py`; do not bypass them to make packaging pass.
- Preserve entitlements, mutual helper identity checks, concrete app-scoped
  Mach service names, and signing of nested components from the inside out.
  Do not weaken identity checks or use `--deep` to sign the app.
- When using `swiftc` directly for iOS, pass the SDK to the linker with
  `-Xclang-linker -isysroot -Xclang-linker "$ios_sdk"` as well as `-sdk`.
  Inspect `xcrun vtool -show-build` output: the probe without an explicit linker
  sysroot incorrectly recorded SDK 17.0 instead of the actual 26.2 SDK.
  Preserve each real target's deployment minimum rather than copying the probe's.
- The successful Swift iOS probes emitted a missing
  `CommandLineTools/usr/lib/swift/iphoneos` search-path warning. Matching Swift
  back-deployment libraries and runtime packaging remain separate checks.
- Report compiler success, complete bundle creation, signature verification,
  native launch/helper/update behavior, and release notarization or App Store
  processing as separate results. A successful compiler probe proves only the
  compilation stage.

## Upstream References

- [xtool](https://github.com/xtool-org/xtool)
- [macOS installation and SDK assumptions](https://github.com/xtool-org/xtool/blob/main/Documentation/xtool.docc/Installation-macOS.md)
- [Linux/WSL SDK extraction](https://github.com/xtool-org/xtool/blob/main/Documentation/xtool.docc/Installation-Linux.md)
- [SwiftPM iOS tutorial](https://github.com/xtool-org/xtool/blob/main/Documentation/xtool.docc/First-app.tutorial)
- [Catalyst support proposal](https://github.com/xtool-org/xtool/pull/362)
