#!/usr/bin/env bash
set -euo pipefail
scriv_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Building the native interface requires macOS with Xcode 15.4 or newer.' >&2
  exit 1
fi
scriv_configuration="${SCRIV_CONFIGURATION:-release}"
scriv_build="$scriv_root/build"
scriv_app="$scriv_build/Scriv.app"
mkdir -p "$scriv_build"
if [[ "${SCRIV_RELEASE:-0}" == 1 ]]; then
  : "${SCRIV_CLOUD_URL:?A release build requires the deployed HTTPS API URL}"
  : "${SCRIV_SIGN_IDENTITY:?A release build requires a Developer ID Application identity}"
  if [[ "$SCRIV_CLOUD_URL" != https://* ]]; then echo 'Production API must use HTTPS.' >&2; exit 1; fi
fi
if [[ "${SCRIV_UNIVERSAL:-0}" == 1 ]]; then
  for scriv_arch in arm64 x86_64; do
    swift build --package-path "$scriv_root/apps/mac" --scratch-path "$scriv_build/swift-$scriv_arch" -c "$scriv_configuration" --arch "$scriv_arch"
  done
  scriv_binary_dir="$(swift build --package-path "$scriv_root/apps/mac" --scratch-path "$scriv_build/swift-arm64" -c "$scriv_configuration" --arch arm64 --show-bin-path)"
else
  swift build --package-path "$scriv_root/apps/mac" -c "$scriv_configuration"
  scriv_binary_dir="$(swift build --package-path "$scriv_root/apps/mac" -c "$scriv_configuration" --show-bin-path)"
fi
# This path is the generated bundle inside this checkout, never a user project.
rm -rf "$scriv_app"
mkdir -p "$scriv_app/Contents/MacOS" "$scriv_app/Contents/Resources"
if [[ "${SCRIV_UNIVERSAL:-0}" == 1 ]]; then
  scriv_intel_dir="$(swift build --package-path "$scriv_root/apps/mac" --scratch-path "$scriv_build/swift-x86_64" -c "$scriv_configuration" --arch x86_64 --show-bin-path)"
  lipo -create "$scriv_binary_dir/Scriv" "$scriv_intel_dir/Scriv" -output "$scriv_app/Contents/MacOS/Scriv"
else
  cp "$scriv_binary_dir/Scriv" "$scriv_app/Contents/MacOS/Scriv"
fi
ditto "$scriv_binary_dir/Scriv_ScrivApp.bundle" "$scriv_app/Contents/Resources/Scriv_ScrivApp.bundle"
cp "$scriv_root/apps/mac/Info.plist" "$scriv_app/Contents/Info.plist"
python3 - "$scriv_app/Contents/Info.plist" <<'PY'
import os,plistlib,sys
p=sys.argv[1]
with open(p,'rb') as f: data=plistlib.load(f)
for env,key in [('SCRIV_CLOUD_URL','ScrivCloudURL'),('SCRIV_BUNDLE_ID','CFBundleIdentifier'),('SCRIV_VERSION','CFBundleShortVersionString'),('SCRIV_BUILD_NUMBER','CFBundleVersion')]:
    if os.getenv(env): data[key]=os.environ[env]
with open(p,'wb') as f: plistlib.dump(data,f)
PY
swift "$scriv_root/scripts/make-icon.swift" "$scriv_build/AppIcon.iconset"
iconutil -c icns "$scriv_build/AppIcon.iconset" -o "$scriv_app/Contents/Resources/AppIcon.icns"
if [[ -n "${SCRIV_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SCRIV_SIGN_IDENTITY" --entitlements "$scriv_root/apps/mac/Scriv.entitlements" "$scriv_app"
else
  codesign --force --sign - "$scriv_app"
fi
codesign --verify --deep --strict "$scriv_app"
plutil -lint "$scriv_app/Contents/Info.plist"
ditto -c -k --sequesterRsrc --keepParent "$scriv_app" "$scriv_build/Scriv-macOS.zip"
echo "Built $scriv_app"
echo "Archive $scriv_build/Scriv-macOS.zip"
