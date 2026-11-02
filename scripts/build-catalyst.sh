#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'BLOCKED: Mac Catalyst requires macOS and the Xcode Mac Catalyst SDK. Linux parsing is not UIKit type-checking.' >&2
  exit 2
fi
command -v xcodebuild >/dev/null
python3 "$root/scripts/generate-catalyst-project.py"
# Optimized by default: an unoptimized (-Onone) Debug build is several times
# slower at runtime. Use SCRIV_CONFIGURATION=Debug only when attaching a debugger.
configuration="${SCRIV_CONFIGURATION:-Release}"
# Local builds target this Mac's architecture; set SCRIV_UNIVERSAL=1 for both.
arch_args=(); [[ "${SCRIV_UNIVERSAL:-0}" == 1 ]] || arch_args=(ONLY_ACTIVE_ARCH=YES)
derived="${SCRIV_CATALYST_BUILD_DIR:-$root/build/catalyst}"
# No global cache cleanup, simulator installation, account mutation or deployment.
xcodebuild -project "$root/apps/catalyst/ScrivUIKit.xcodeproj" -scheme ScrivUIKit \
  -configuration "$configuration" -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$derived" -clonedSourcePackagesDirPath "$derived/SourcePackages" \
  CODE_SIGNING_ALLOWED=NO "${arch_args[@]}" build
app="$derived/Build/Products/$configuration-maccatalyst/Scriv.app"
if [[ ! -d "$app" ]]; then echo "Expected Catalyst app is missing: $app" >&2; exit 1; fi
# The checked-in approved mark is compiled by Xcode, including direct IDE builds.
# Do not patch a built bundle to hide missing source assets.
python3 "$root/scripts/verify-catalyst-icon.py" "$app"
# A plain `build` never strips (only install/archive do), leaving ~5 MB of local
# symbol tables in the executables. dSYMs keep crash symbolication; -x keeps the
# global symbols bundles export. Everything stripped here is re-signed below.
if [[ "$configuration" == Release ]]; then
  for binary in "$app/Contents/MacOS/Scriv" "$app/Contents/PlugIns/ScrivUpdatePlugin.bundle/Contents/MacOS/ScrivUpdatePlugin" "$app/Contents/XPCServices/com.scriv.runtime-companion.bootstrap.xpc/Contents/MacOS/ScrivRuntimeCompanion"; do
    strip -x "$binary" 2>/dev/null
  done
fi
identity="${SCRIV_SIGN_IDENTITY:--}"
# Sign nested update components inside-out. Never use --deep for signing.
plugin="$app/Contents/PlugIns/ScrivUpdatePlugin.bundle"
framework="$plugin/Contents/Frameworks/Sparkle.framework"
if [[ ! -d "$framework" ]]; then echo 'Missing embedded Sparkle framework' >&2; exit 1; fi
for component in "$framework/Versions/B/XPCServices/Installer.xpc" "$framework/Versions/B/XPCServices/Downloader.xpc" "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" "$framework" "$plugin"; do
  [[ -e "$component" ]] || { echo "Missing updater component: $component" >&2; exit 1; }
  if [[ "$component" == */Downloader.xpc ]]; then
    codesign --force --sign "$identity" --options runtime --preserve-metadata=entitlements "$component"
  else
    codesign --force --sign "$identity" --options runtime "$component"
  fi
done
# The bundled helper is on-demand and mutually signature-constrained. An ad-hoc
# candidate may build, but cannot bootstrap; never weaken identity checks.
helper="$app/Contents/XPCServices/com.scriv.runtime-companion.bootstrap.xpc"
[[ -x "$helper/Contents/MacOS/ScrivRuntimeCompanion" ]] || { echo 'Missing bundled runtime XPC' >&2; exit 1; }
codesign --force --sign "$identity" --options runtime "$helper"
# Xcode expands build variables when signing; this development packaging path
# must likewise use concrete, app-scoped Mach names, never a wildcard exception.
entitlements="$derived/Scriv-development.entitlements"
python3 - "$root/apps/catalyst/ScrivUIKit.entitlements" "$entitlements" <<'PYENT'
import plistlib,sys
with open(sys.argv[1],'rb') as f: value=plistlib.load(f)
value['com.apple.security.temporary-exception.mach-lookup.global-name']=['app.scriv.uikit-spks','app.scriv.uikit-spki']
with open(sys.argv[2],'wb') as f: plistlib.dump(value,f)
PYENT
codesign --force --sign "$identity" --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"
plutil -lint "$app/Contents/Info.plist"
echo "Built UIKit Mac Catalyst app: $app"
echo 'Development candidate only: production update releases require Developer ID export, notarization/stapling, and updates/scripts/release.py verification. Native interaction and update installation remain acceptance gates.'
