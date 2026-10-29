# Doppler Linux Swift verification and native boundary

Investigated on **2026-10-29**, in Doppler's own Debian 13 x86_64 workspace. No user Mac, Apple account, cloud deployment, workflow dispatch, or signing identity was used. The existing `native-ci.json` and screenshots describe the earlier runtime commit; they are not proof that later Doppler UI edits compile or match the concepts.

## Reproduce the supported checks

Install an [official Swift Linux toolchain](https://www.swift.org/install/linux/tarball/) and put its `usr/bin` directory on `PATH`, then run:

```sh
bash scripts/verify-native.sh --portable
node --test tests/native-verification.test.mjs
```

The portable command genuinely parses every app/core/test Swift source and the icon-generation script, compiles and executes the Foundation core tests, and compiles an optimized `ScrivCore` target. It **does not type-check AppKit/SwiftUI**. It prints the native checks that were not run rather than reporting native success. `scripts/verify.sh` now includes these Swift checks on Linux instead of silently skipping them.

All SwiftPM configuration, compiler module caches and build products default to `build/swift-verification`, so a read-only home directory does not require elevated permissions. `SCRIV_SWIFT_VERIFY_DIR` may select another absolute working directory. `SCRIV_SWIFT` and `SCRIV_SWIFTC` may select explicit tool executables. The verification script does not download tools, change a shell profile, or change global SwiftPM configuration.

Four Node regression tests verify local-cache arguments, the missing-tool error, test-failure propagation, and rejection of native verification on Linux. Those use compiler test doubles only to test orchestration; they do not count as Swift/app verification.

### Latest verified checkpoint: `0c5727d`

The hash-guarded run from **2026-10-29 21:12:26.487750 to 21:12:54.289470 UTC** verified source commit `0c5727d19834304773d70b20100ff62d24f534a3`. The commit and hashes of all **78** files under `apps/mac`, `scripts`, and `tests` (excluding generated `.build` and `__pycache__` paths) were unchanged before and after the run. The source-manifest SHA-256, calculated over the sorted, compact JSON path-to-hash map, was:

```text
ab50a180e255b114f45f94c664078a71ac5b44fbe9ff1e7c001f9984045cf340
```

| Check | Observed result |
| --- | --- |
| Normal portable Swift core tests | **86 passed, zero failures** |
| Parallel Swift tests with LLVM coverage | **86 passed** |
| Optimized release `ScrivCore` build | Passed |
| Swift parser | **52** app/core/test sources plus icon script passed; not native type-checking |
| Root Node tests (`tests/*.test.mjs`) | **21 passed, zero failures** |
| Portable core line coverage | **1,312 / 1,381 = 95.00%** |
| Preservation check | 25 original concepts and three sample frames verified |
| `git diff --check` | Passed |

This is a **checkpoint**, not a final claim about later edits: a separate R2-upload/edit-preservation fix was authorized after this verification began and must be verified after it freezes. Neither this run nor the earlier checkpoint below compiled, launched or rendered the macOS app. No backend tests or Wrangler commands were included in this run.

Local evidence is preserved under `/workspace/scratch/74e1e2ebe624/scriv-native-evidence/`:

- `lease-final-native-summary.json`
- `lease-final-source-before.json` and `lease-final-source-after.json`
- `lease-final-portable.log`, `lease-final-node-tests.log`, `lease-final-parallel-coverage.log`, `lease-final-preservation.log`, and `lease-final-whitespace.log`

Raw LLVM coverage is at `build/native-lease-final-coverage/build/out/Products/Debug-linux-x86_64/codecov/Scriv.json`. These files are local build evidence, not committed app binaries or native screenshots.

### Earlier evidence and failure-to-fix history

- The initial successful portable checkpoint ran **51 Swift tests**, zero failures. It was not final integrated-branch evidence.
- A first aggregate attempt at approximately **21:02 UTC** passed 79 Swift tests and the optimized core build, but the Node suite passed only **20 of 21** tests. `retired checksum cannot consume a new request for the same peer and hash` exhausted a loop-count polling limit before WebCrypto completed; the run stopped rather than treating a retry as success.
- The peer test harness was corrected to await actual emitted events and deferred checksum completion, without changing production transport behavior or timeouts. A deterministic reproduction delayed the second checksum by 50 ms: the original harness failed after 10.7 ms, while the corrected harness passed after 63.9 ms. The original production bridge still failed the stale-asset assertion under the corrected harness. The reproduction logs remain at `build/peer-test-sync-repro-before.log` and `build/peer-test-sync-repro-after.log`.
- A later **stable historical checkpoint**, commit `669beb1ccb202ea2fc3fd0ead465f14f019aa0c0`, ran from **21:06:53.484369 to 21:07:24.298501 UTC**: **84 normal Swift tests, 84 parallel coverage tests, 21 Node tests**, optimized core build, 50 Swift source/test parses plus icon, preservation and whitespace checks all passed. Core line coverage was **1,285 / 1,352 = 95.04%**. All 76 source-manifest files and the commit were unchanged across that run; manifest SHA-256 was `4307a479dde5071678b361a89c39e8fa6bcf931126c276bf7e0404862acfea20`. Its original `final-native-summary.json`, `final-source-before.json`, `final-source-after.json`, and `final-*.log` evidence files remain unchanged in the same local evidence directory. Their historical “final” filenames do not establish verification of later lease-lifecycle or R2-upload edits.

Use the main [verification report](../verification.md) for integration status; subsequent source edits require a new guarded run, not relabeling these checkpoints.

On an independently authorized macOS executor, `bash scripts/verify-native.sh --native` additionally calls the existing app-packaging script. Packaging is still separate from app interaction, fresh screenshot comparison, native WebKit transfer, and live-account acceptance checks. No Mac executor was used for this investigation.

### Fresh native runtime evidence (implemented; not executed here)

On an **independently authorized Mac with a logged-in graphical session**, Node.js and the build prerequisites, run:

```sh
node scripts/verify-native-runtime.mjs
```

This command refuses Linux before building or launching anything. On macOS it rebuilds a universal, ad-hoc-signed development app; it refuses release/private-signing configuration. It then launches only the resulting executable, with bounded native-smoke/capture deadlines and a unique `build/native-runtime/run-*` evidence directory. App verification modes use that run's isolated project root, do not read Keychain tokens, and do not replace the normal last-project preference. It does not start Codex or sign into a cloud account.

The verifier checks native process exits, explicit success/error markers, artifact freshness, real received-byte equality against the repository's sample frame, SHA-256 and chunk-spanning transfer metadata. Capture validation requires these five unmodified PNGs and consistent window/state metadata:

- `01-script.png`
- `02-characters.png`
- `03-storyboard.png`
- `04-collaboration-local.png`
- `04-codex-popover.png`

The fourth concept is represented by two raw captures because an AppKit popover is a separate window. The verifier does **not** composite them or claim a single reference-matching screenshot. It records screen-coordinate window frames, content bounds, pixel dimensions and actual stopped/local UI state. PNG checks cover signatures, chunk checksums/completeness and dimensions; matching these structural checks is not human visual-parity acceptance.

Only a successful native run writes its final `verification.json`, including the executable hash, native transport result and per-capture hashes. Failure leaves diagnostic logs but no final success report. A successful run still would not establish live-account flows, notarization, cross-network TURN, or execution on the other CPU architecture.

`node --test tests/native-runtime.test.mjs` passes **six local verifier regressions** using synthetic test fixtures and child-process test doubles. They cover missing/stale/failed markers, missing popover capture, corrupt PNGs, inconsistent metadata, changed transfer bytes, failed child exits and timeout cleanup. These are tests of the verifier, **not a native app run**.

## Actual native probes on this host

| Probe | Observed result |
| --- | --- |
| `bash scripts/verify-native.sh --native` | Exit 2, explicit macOS/SDK requirement. |
| `bash scripts/build-mac.sh` | Exit 1, native-interface build requires macOS. |
| `swift build ... --target ScrivApp` | Exit 1, target not found: `Package.swift` includes it only on macOS. |
| `swiftc -typecheck ... apps/mac/Sources/ScrivApp/App.swift` | Exit 1, `no such module 'SwiftUI'`. |
| Fresh native app launch, native WebKit smoke, screenshot rendering/comparison | **Not run**: no macOS runtime or Apple UI SDK in this Linux executor. |

These are environment/target limits, not passing tests and not evidence that the app's native types are correct. Parser checks can catch malformed Swift syntax but cannot replace native compilation.

## xtool: installed and attempted, not a macOS runtime

The official [xtool 1.24.0](https://github.com/xtool-org/xtool/releases/tag/1.24.0) Linux AppImage was downloaded and extracted in the writable build workspace. Its `--version`, `--help`, `sdk status`, and `dev build --help` commands executed successfully. `sdk status` reported **Not installed**. The build help describes an **iOS** SwiftPM application and defaults to `arm64-apple-ios`.

An actual `xtool dev build` was attempted from `apps/mac`:

1. Without a PTY, its SwiftNIO input handler failed with `epoll_ctl` `Operation not permitted` (exit 132).
2. Retrying with a PTY progressed to SDK generation and prompted for the downloaded **Xcode.xip** path.
3. The command was canceled at that prompt; no Xcode archive was available, no Apple login or license acceptance was attempted, and no SDK was manufactured or obtained from an unofficial source.

The [official Linux installation guide](https://github.com/xtool-org/xtool/blob/1.24.0/Documentation/xtool.docc/Installation-Linux.md) requires the Apple Xcode download and generates an iOS Swift SDK. The [official project overview](https://github.com/xtool-org/xtool) scopes the supported app workflow to iOS. Even providing that SDK would not establish a Linux runtime for Scriv's AppKit/SwiftUI macOS interface. Installing xtool therefore does not close the native screenshot-parity gate.

## Tool provenance

- **Swift 6.4.1, Debian 13 x86_64**, official `download.swift.org` release. The detached PGP signature verified against the Swift 6.x release key, fingerprint `52BB 7E3D E28A 71BE 22EC 05FF EF80 A866 B47A 981F`. Archive SHA-256: `3273c647a4e29231e1d0962a170f4ba14eca06675591dfe384e7c22b0e476a47`.
- **xtool 1.24.0 x86_64 AppImage**, official GitHub release asset. SHA-256 `dbfd9d7216f077c84c171b688c4173c37c23ca76bf7fd185d1a9ae8a53dab59f` matched the GitHub release API's asset digest; asset size was 54,135,288 bytes.
- Tool archives/executables and local logs are workspace-only build aids, not repository deliverables. No credentials, account tokens, SDK archives, or signing material are included in this report.
