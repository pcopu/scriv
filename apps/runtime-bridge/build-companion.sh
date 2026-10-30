#!/usr/bin/env bash
# Build locally only. Does not install, launch, notarize, publish, or register a daemon.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'Native macOS SDK required for the runtime companion.' >&2; exit 2; }
root="$(cd "$(dirname "$0")/../.." && pwd)"
output="${SCRIV_COMPANION_OUTPUT:-$root/build/runtime-companion}"
mkdir -p "$output"
swift build --package-path "$root/apps/runtime-bridge" --scratch-path "$output/swift" --configuration release --product ScrivRuntimeCompanion
binary_dir="$(swift build --package-path "$root/apps/runtime-bridge" --scratch-path "$output/swift" --configuration release --show-bin-path)"
app="$output/Scriv Runtime Companion.app"
mkdir -p "$app/Contents/MacOS"
cp "$binary_dir/ScrivRuntimeCompanion" "$app/Contents/MacOS/ScrivRuntimeCompanion"
cp "$root/apps/runtime-bridge/Info.plist" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
if [[ -n "${SCRIV_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SCRIV_SIGNING_IDENTITY" "$app"
  codesign --verify --strict --verbose=2 "$app"
else
  codesign --force --sign - "$app"
  echo 'DEVELOPMENT ONLY: ad-hoc signed. Distribution requires an authorized Developer ID, notarization and fresh native verification.'
fi
printf 'Built, not installed or launched: %s\n' "$app"
