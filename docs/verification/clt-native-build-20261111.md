# Incremental Catalyst build with standalone CLI tools

The CLI rebuild now compiles the app, canonical Core, native update adapter and
runtime XPC from current source. Previously it copied the native adapter from
the template even though that adapter embeds Core. A fresh host executable
therefore could coexist with older app-owned native code.

The adapter now includes the same canonical Core sources, bootstrap client,
bootstrap adapter and Objective-C Sparkle plugin as the generated macOS target.
It is linked as a native macOS 14 bundle, separate from the Catalyst host, with
the existing Foundation-only protocol and both loader-relative search paths.
Consent, helper identity, updater policy and entitlements are unchanged.

## Inputs and command

This is an incremental build, not a clean asset build. It needs an approved,
strictly signed Catalyst template, the standalone macOS SDK with UIKit support,
an already authorized signing identity and matching Sparkle 2.10.1 development
headers. It does not install Xcode, simulators or asset tooling.

```sh
python3 scripts/rebuild-catalyst-cli.py \
  --template /verified/template/Scriv.app \
  --sparkle-framework /verified/development/Sparkle.framework \
  --output /new/output/Scriv.app --work /separate/owned/build-work \
  --identity EXISTING_SIGNING_IDENTITY --version NUMERIC_VERSION --build NUMERIC_BUILD
```

Add `--automation` only for an isolated test app, never a distribution build.
The development and retained Sparkle frameworks must have valid signatures,
version 2.10.1 and identical nonempty architecture/UUID sets. These compatibility
checks do not independently authenticate an arbitrary header supplier. Use the
approved matching framework, not an untrusted substitute.

All intended app-owned executables are rebuilt. Approved compiled icon/assets,
third-party Sparkle and remaining bundle metadata/resources come from the
template. Runtime PeerTransfer and SampleImages resources are refreshed from
source. The host version/build fields are updated. Sparkle is re-signed, so its
complete bundle bytes are not expected to remain identical.

Use only approved templates with safe, self-contained paths. The newly written
plugin executable and its directory ancestry reject symlinks, but this is not
a general sanitizer for arbitrary untrusted app bundles. An unsuccessful build
may leave partial output/work. Do not launch or distribute it; a successful
compiler exit alone is insufficient without the final signature/icon/platform
checks.

## Verification requirements

Verify the native plugin as an MH_BUNDLE for the intended macOS deployment
minimum, with the required class metadata and loader paths. Check the host's
Mac Catalyst platform and deployment minimum, nested signatures, compiled
assets and icon resources. Run only the completed, verified output.

Compiler success does not establish native workflow acceptance. Run the CLI
journeys against the matching automation build and retain their results
separately from source mappings. Do not infer whole-catalog acceptance,
measured coverage or source-to-binary attestation from a selected suite.

Plugin loading/protocol casting, real Keychain consent, helper bootstrap,
live provider behavior, signed-update installation and release notarization
remain separate gates. A successful incremental build does not establish a
clean asset build or Intel support.
