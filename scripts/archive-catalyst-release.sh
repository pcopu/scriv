#!/usr/bin/env bash
# Opt-in release operator workflow. Does not create keys, profiles or credentials.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'BLOCKED: Apple release signing and notarization require macOS/Xcode.' >&2; exit 2; }
: "${SCRIV_TEAM_ID:?Set the existing Apple Developer Team ID}"
: "${SCRIV_UPDATE_PUBLIC_KEY:?Set the pinned public Ed25519 release key, not the private key}"
: "${SCRIV_BUILD_NUMBER:?Set a new monotonically increasing integer build}"
: "${SCRIV_MARKETING_VERSION:?Set the display version}"
: "${SCRIV_NOTARY_PROFILE:?Set an already configured notarytool Keychain profile}"
export SCRIV_UPDATE_CHANNEL="${SCRIV_UPDATE_CHANNEL:-stable}"
export SCRIV_UPDATE_FEED_URL="$(python3 - "$SCRIV_UPDATE_CHANNEL" <<'PYCHANNEL'
import re,sys
channel=sys.argv[1]
if channel != 'stable' and not re.fullmatch(r'acceptance-[a-z0-9][a-z0-9-]{0,47}',channel):raise SystemExit('Invalid update channel')
print('https://scriv-updates.why-not.work'+('/appcast.xml' if channel=='stable' else f'/channels/{channel}/appcast.xml'))
PYCHANNEL
)"
python3 - <<'PY'
import os,re,base64
assert re.fullmatch(r'[A-Z0-9]{10}',os.environ['SCRIV_TEAM_ID'])
assert re.fullmatch(r'[1-9][0-9]{0,14}',os.environ['SCRIV_BUILD_NUMBER'])
assert re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}',os.environ['SCRIV_MARKETING_VERSION'])
assert len(base64.b64decode(os.environ['SCRIV_UPDATE_PUBLIC_KEY'],validate=True)) == 32
PY
work="${SCRIV_RELEASE_DIR:-$root/build/releases/$SCRIV_BUILD_NUMBER}"
[[ ! -e "$work" ]] || { echo 'BLOCKED: Release directory exists; inspect it rather than overwriting evidence.' >&2; exit 1; }
mkdir -p "$work"
python3 "$root/scripts/generate-catalyst-project.py"
xcodebuild -project "$root/apps/catalyst/ScrivUIKit.xcodeproj" -scheme ScrivUIKit \
  -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -archivePath "$work/Scriv.xcarchive" -derivedDataPath "$work/DerivedData" \
  -clonedSourcePackagesDirPath "$work/SourcePackages" \
  DEVELOPMENT_TEAM="$SCRIV_TEAM_ID" SCRIV_UPDATE_PUBLIC_KEY="$SCRIV_UPDATE_PUBLIC_KEY" \
  SCRIV_UPDATE_CHANNEL="$SCRIV_UPDATE_CHANNEL" SCRIV_UPDATE_FEED_URL="$SCRIV_UPDATE_FEED_URL" \
  CURRENT_PROJECT_VERSION="$SCRIV_BUILD_NUMBER" MARKETING_VERSION="$SCRIV_MARKETING_VERSION" archive
python3 - "$work/ExportOptions.plist" <<'PY'
import os,plistlib,sys
with open(sys.argv[1],'wb') as f:
 plistlib.dump({'method':'developer-id','teamID':os.environ['SCRIV_TEAM_ID'],'signingStyle':'automatic','manageAppVersionAndBuildNumber':False,'uploadSymbols':False},f)
PY
# Xcode export re-signs nested Sparkle helpers. No --deep signing or security exceptions.
xcodebuild -exportArchive -archivePath "$work/Scriv.xcarchive" -exportPath "$work/export" -exportOptionsPlist "$work/ExportOptions.plist"
app="$work/export/Scriv.app"
[[ -d "$app" ]] || { echo 'BLOCKED: Exported Scriv.app is missing.' >&2; exit 1; }
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/notarization.zip"
xcrun notarytool submit "$work/notarization.zip" --keychain-profile "$SCRIV_NOTARY_PROFILE" --wait --output-format json > "$work/notarization-result.json"
python3 - "$work/notarization-result.json" <<'PY'
import json,sys
with open(sys.argv[1]) as f: result=json.load(f)
if result.get('status') != 'Accepted': raise SystemExit('BLOCKED: Apple did not accept this notarization submission.')
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict --all-architectures "$app"
spctl --assess --type execute --verbose=4 "$app"
echo "Signed, notarized candidate: $app"
echo 'Nothing was published. Next: run updates/scripts/release.py for pinned-key artifact/feed signing and optional authenticated publication.'
