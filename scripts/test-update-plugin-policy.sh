#!/bin/bash
# Native unit boundary, not signed-release acceptance. Uses an existing pinned
# Sparkle framework; does not download packages, use keys, or touch applications.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'BLOCKED: this actual Objective-C plug-in harness requires macOS/Xcode.' >&2
  exit 2
fi
if [[ $# != 2 ]]; then
  echo 'Usage: bash scripts/test-update-plugin-policy.sh /existing/Sparkle.framework /fresh/private/output-directory' >&2
  exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORK="$1"
OUTPUT="$2"
[[ -d "$FRAMEWORK" && "$(basename "$FRAMEWORK")" == Sparkle.framework ]] || { echo 'Expected an existing Sparkle.framework.' >&2; exit 2; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$FRAMEWORK/Resources/Info.plist")"
[[ "$VERSION" == 2.10.1 ]] || { echo 'Expected the audited Sparkle 2.10.1 framework.' >&2; exit 2; }
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || { echo 'Use a fresh private output directory.' >&2; exit 2; }
FRAMEWORK_PARENT="$(cd "$(dirname "$FRAMEWORK")" && pwd)"
mkdir -m 700 "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
xcrun --sdk macosx clang -fobjc-arc -fblocks -mmacosx-version-min=14.0 \
  -framework AppKit -framework Security -F "$FRAMEWORK_PARENT" -framework Sparkle \
  -Wl,-rpath,"$FRAMEWORK_PARENT" \
  "$ROOT/apps/catalyst/UpdatePlugin/ScrivSparklePlugin.m" \
  "$ROOT/scripts/test-update-plugin-policy.m" -o "$OUTPUT/update-policy-tests"
"$OUTPUT/update-policy-tests"
