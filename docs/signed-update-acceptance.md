# Signed update acceptance

This is an operator procedure, not a report of completed installation or UI acceptance. Use only synthetic/copied projects. Keep local paths, process snapshots, project hashes, logs, notarization receipts and signing credentials outside the public repository.

## Prerequisites

- macOS and Xcode, an existing authorized Developer ID Application signing identity, and an existing working `notarytool` Keychain profile.
- The existing Sparkle private key retained locally. `updates/acceptance-20261031.env` contains only public team/key/channel metadata and the existing Keychain account name. It does not read Keychain, sign, upload, install, or change ordinary stable defaults.
- Explicit authorization for Apple notarization submission, public release publication and application installation. Preparing source or running portable tests does not authorize those actions.
- Sparkle tools matching the pinned 2.10.1 package, plus `updates/requirements.txt` in an isolated Python environment.

Do not export credentials, generate replacement signing keys, change Gatekeeper/quarantine/SIP/library validation, or lower version checks to make acceptance pass.

## Build and stage

Source the opt-in public metadata only when intentionally testing that isolated channel:

```sh
source updates/acceptance-20261031.env
# Set SCRIV_NOTARY_PROFILE to an existing authorized local profile.
# Set SCRIV_BUILD_NUMBER to a fresh increasing integer and SCRIV_MARKETING_VERSION.
# Optionally set SCRIV_RELEASE_DIR to a fresh private directory.
bash scripts/archive-catalyst-release.sh
```

The archive command submits the signed archive to Apple, requires accepted notarization, staples, and verifies the exported app. It does not publish. On uncertain notarization, inspect the retained submission ID before resubmitting.

Stage the verified app using public metadata and local paths:

```sh
python3 updates/scripts/release.py \
  --app "$SIGNED_EXPORTED_SCRIV_APP" --output "$NEW_RELEASE_STAGING_DIRECTORY" \
  --team "$SCRIV_TEAM_ID" --public-key "$SCRIV_UPDATE_PUBLIC_KEY" \
  --sign-update "$SPARKLE_TOOLS/bin/sign_update" \
  --key-account "$SCRIV_SPARKLE_KEY_ACCOUNT" --notes "$PLAIN_TEXT_RELEASE_NOTES"
```

Publication is a separate authorized action: add `--publish --confirm-channel "$SCRIV_UPDATE_CHANNEL"` only with existing bucket-scoped S3 authentication. The publisher verifies signatures before immutable object writes, commits the channel pointer last with a conditional write, and reads it back. On timeout, collision or conditional-write failure, inspect exact remote objects/pointer before retrying. Never delete old evidence to make a retry succeed. The channel is public distribution, not confidentiality; stable must remain unchanged.

### Cloud-side integrity check of returned staging

The four public release-staging files (`Scriv.zip`, `appcast.xml`,
`manifest.json`, and `channel.json`) can be checked on Linux without accessing
Apple credentials, extracting the app, invoking native tools, or publishing:

```sh
python3 updates/scripts/verify_staged.py \
  --staged "$RELEASE_STAGING_DIRECTORY" \
  --team "$SCRIV_TEAM_ID" --public-key "$SCRIV_UPDATE_PUBLIC_KEY" \
  --build "$SCRIV_BUILD_NUMBER" --channel "$SCRIV_UPDATE_CHANNEL"
```

Supply the team, public key, expected build, and channel from independently
trusted release instructions, not by copying untrusted manifest values. The
checker reads bounded files, verifies archive/feed Ed25519 signatures and
content addresses, compares the channel pointer, and checks the signed ZIP's
app metadata and update policy. It never extracts or launches executable code.
It does not inspect the full ZIP path graph or establish that extraction is safe.

A successful JSON result deliberately reports native signing/notarization,
source provenance, installation, and publication as **not verified/performed**.
An authentic archive can still contain an unsigned, unnotarized, wrong-source,
or broken app. This is an integrity check for artifact transfer, not a portable
substitute for the native release and acceptance gates below. Keep notarization
receipts, local diagnostic paths, project snapshots and credentials private; the
checker neither needs nor accepts them.

## Actual native acceptance

1. Verify/download the exact signed app using `updates/scripts/acceptance.py download`; it never installs or launches anything.
2. Preserve any installed app and user data. Install the verified baseline through the normal OS flow; do not bypass security warnings. Launch the exact intended app path.
3. Open a synthetic active project and retain a separate closed copied/synthetic project for byte-preservation checks. Capture private baseline evidence with `acceptance.py snapshot`.
4. Publish a higher-build candidate in the same explicitly authorized channel. Exercise Settings → Check for Scriv updates, download, prepared-update Later/cancel, and Update & Relaunch. Do not substitute manual replacement for app-driven update acceptance.
5. Confirm the actual process changed, installed bundle identity/build/signatures match, the active project is saved/reopened, and protected closed-project bytes are unchanged. Use `acceptance.py compare` for the private snapshots, plus real interaction checks.
6. Cover offline/tampered/wrong-key/older-build failures, save failure, repeated/late clicks, modal dismissal, Close/Cancel, and interrupted/repeated flows. A compiled test bundle or portable suite does not establish these outcomes.

Publish only source and aggregate test outcomes. Never publish the snapshot JSON, original receipts, backup contents, local diagnostic paths or project contents.
