#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'BLOCKED: Mac Catalyst requires macOS and the Xcode Mac Catalyst SDK. Linux parsing is not UIKit type-checking.' >&2
  exit 2
fi
command -v xcodebuild >/dev/null
python3 "$root/scripts/generate-catalyst-project.py"
configuration="${SCRIV_CONFIGURATION:-Debug}"
derived="${SCRIV_CATALYST_BUILD_DIR:-$root/build/catalyst}"
# No global cache cleanup, simulator installation, account mutation or deployment.
xcodebuild -project "$root/apps/catalyst/ScrivUIKit.xcodeproj" -scheme ScrivUIKit \
  -configuration "$configuration" -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$derived" -clonedSourcePackagesDirPath "$derived/SourcePackages" \
  CODE_SIGNING_ALLOWED=NO build
app="$derived/Build/Products/$configuration-maccatalyst/ScrivUIKit.app"
if [[ ! -d "$app" ]]; then echo "Expected Catalyst app is missing: $app" >&2; exit 1; fi
# Preserve the existing Scriv mark; this AppKit script is a build-time icon tool,
# not code linked into the UIKit application.
swift "$root/scripts/make-icon.swift" "$derived/AppIcon.iconset"
iconutil -c icns "$derived/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon' "$app/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$app/Contents/Info.plist"
identity="${SCRIV_SIGN_IDENTITY:--}"
codesign --force --sign "$identity" --entitlements "$root/apps/catalyst/ScrivUIKit.entitlements" "$app"
codesign --verify --deep --strict "$app"
plutil -lint "$app/Contents/Info.plist"
echo "Built UIKit Mac Catalyst app: $app"
echo 'Native interaction, saved-project migration, bridge pairing/launch, real generation and screenshot parity are separate acceptance gates.'
