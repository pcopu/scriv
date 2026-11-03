# Scriv Agent Guidance

## CLI-Only Apple Builds

The user wants to keep Xcode.app and simulator runtimes uninstalled on this
Mac. Reuse the standalone Command Line Tools and separately retained Apple
SDKs. Do not reinstall Xcode or simulators as an automatic response to a build
failure. Running `xcodebuild` from a terminal still requires Xcode.

Scriv's current application is UIKit with Mac Catalyst. Preserve that target;
the legacy AppKit/SwiftUI app under `apps/mac` is not a replacement for it.
`scripts/build-catalyst.sh` currently calls `xcodebuild`, so it does not yet
provide a complete Xcode-free build.

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
