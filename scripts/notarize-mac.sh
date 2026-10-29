#!/usr/bin/env bash
set -euo pipefail
scriv_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${SCRIV_NOTARY_PROFILE:?Store an App Store Connect credential with xcrun notarytool store-credentials first}"
scriv_app="$scriv_root/build/Scriv.app"
test -d "$scriv_app"
codesign --verify --deep --strict "$scriv_app"
if codesign -dv "$scriv_app" 2>&1 | grep -q 'Signature=adhoc'; then echo 'Developer ID signing is required before notarization.' >&2; exit 1; fi
xcrun notarytool submit "$scriv_root/build/Scriv-macOS.zip" --keychain-profile "$SCRIV_NOTARY_PROFILE" --wait
xcrun stapler staple "$scriv_app"
xcrun stapler validate "$scriv_app"
spctl --assess --type execute --verbose "$scriv_app"
ditto -c -k --sequesterRsrc --keepParent "$scriv_app" "$scriv_root/build/Scriv-macOS.zip"
echo 'Signed, notarized and stapled archive is ready.'
