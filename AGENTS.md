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
   `<locally retained SDK producer archive>`.
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

# Scriv development

## Mac Catalyst with Apple Command Line Tools

The normal Xcode project and `scripts/build-catalyst.sh` remain the release
and full-Xcode path. On a Mac with Command Line Tools but without Xcode, the
isolated development build is:

```sh
scriv_clt_root="/private/tmp/scriv-clt-builds-$(id -u)"
# Only initialize a new root; never replace an existing directory or marker.
mkdir -m 700 "$scriv_clt_root" && printf 'Scriv CLT isolated build root v1\n' > "$scriv_clt_root/.scriv-clt-root"
python3 scripts/build-catalyst-clt.py \
  --development-icns \
  --output "$scriv_clt_root/run-001" \
  --sparkle-framework /absolute/path/to/verified/Sparkle.framework \
  --sparkle-tree-sha256 VERIFIED_FRAMEWORK_TREE_SHA256
```

The output must be a fresh direct child of that marked private scratch root.
The root must already exist, be owned by the current user, have mode 0700,
and have no symlinked ancestor or marker. Reuse an existing root only after
verifying its ownership, mode and marker; choose a new child for each run.
Temporary directories may be cleared by the OS: preserve evidence separately.
The script requires at least 2.5 GiB free before starting. Add
`--preflight-only` to validate inputs and space without creating the output.
The path policy rejects ordinary output paths in checkouts, signed apps and
evidence directories. It is not a security boundary against another process
running as the same user: after descriptor-relative creation, compilers,
signing tools and other build steps still write by pathname. A same-user
process that replaces the root or output during a build could redirect those
later writes. Run only while no other process will alter the scratch root or
its contents; do not use this workflow against an adversarial same-user actor.
The framework must be an existing Sparkle 2.10.1 dependency with
independently established provenance. The tree fingerprint uses the
`framework_tree_sha256` function in the script and covers names, modes,
symlinks and regular-file bytes. Obtain the expected fingerprint from a
trusted, independently verified artifact record. A digest calculated only
from an unknown input proves consistency, not provenance. The script verifies
the full tree fingerprint and code-signature integrity; an ad-hoc signature
does not identify the publisher. It does not download dependencies.

The script builds canonical ScrivCore, the Catalyst UIKit app, the native
Sparkle plug-in and Swift adapter, and the native runtime XPC helper. It copies
the PeerTransfer and SampleImages resources, generates `AppIcon.icns` by
embedding the checked-in PNGs, expands app metadata, and signs nested
components inside-out with an ad-hoc identity. The app keeps the sandbox,
network and user-selected-file entitlements and scoped Sparkle Mach names.
The extra adapter dylib is a development-build linkage detail. Inspect the
output and do not weaken sandbox, library validation or code-identity checks.

The development verifier checks every ICNS chunk against its corresponding
approved PNG byte-for-byte, dimensions, metadata, duplicates and truncation;
`iconutil` must also decode the file. This does not prove Finder rendering.
CLT lacks `actool`, so this route does **not** create `Assets.car`. It
fails if the catalog contains more than the handled app icon. The generated
`.icns` and Finder presentation still require visual validation. This
development command reports its own icon result and does not run the release
gate. The unchanged Xcode release icon verifier still requires `Assets.car`;
passing the development check is not release acceptance. No old app's catalog
or icon is silently reused.

This is an ad-hoc, current-architecture development candidate only. It does not
establish Developer ID, notarization, signed update/relaunch, runtime-companion
identity, package reproducibility, or user-interface acceptance. The update
public key and team pin are empty in this development candidate, so update
trust must fail closed. Do not install over `/Applications/Scriv.app`,
connect real accounts or services, or run a live update from this workflow.
Each build generates a distinct test bundle identifier, removes document and
URL registrations, and requires `--screenshots` and a matching sandbox home
before UIKit starts. Synthetic project data is confined to that sandbox. If
the system cannot establish that container, the fixture exits before startup;
do not override this guard. The helper identity and live update remain untested.
Full XCTest and Xcode asset/archive tools are not supplied by CLT alone.
