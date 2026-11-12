#!/usr/bin/env bash
# Portable Swift checks are not a substitute for compiling/rendering Catalyst.
set -euo pipefail
scriv_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scriv_mode="${1:---portable}"
if [[ "$#" -gt 1 || ( "$scriv_mode" != --portable && "$scriv_mode" != --native ) ]]; then
  echo 'Usage: bash scripts/verify-native.sh [--portable|--native]' >&2
  exit 2
fi
if [[ "$scriv_mode" == --native && "$(uname -s)" != Darwin ]]; then
  echo 'BLOCKED: Native Catalyst compilation and packaging require macOS and the Xcode Catalyst SDK. Use --portable for Linux core builds and syntax checks; xtool iOS builds do not supply a macOS runtime.' >&2
  exit 2
fi
scriv_swift="${SCRIV_SWIFT:-swift}"
scriv_swiftc="${SCRIV_SWIFTC:-swiftc}"
for scriv_tool in "$scriv_swift" "$scriv_swiftc"; do
  if ! command -v "$scriv_tool" >/dev/null 2>&1; then
    echo "BLOCKED: Required Swift tool not found: $scriv_tool. Install an official Swift toolchain and add its usr/bin directory to PATH." >&2
    exit 127
  fi
done

# Keep every build/cache write inside the checkout by default. This also works
# in build containers with a read-only home directory, without sudo or changes
# to a developer's global SwiftPM configuration.
scriv_work="${SCRIV_SWIFT_VERIFY_DIR:-$scriv_root/build/swift-verification}"
mkdir -p "$scriv_work"/{build,cache,config,security,module-cache}
export CLANG_MODULE_CACHE_PATH="$scriv_work/module-cache"
export SWIFT_MODULECACHE_PATH="$scriv_work/module-cache"
scriv_package_options=(
  --package-path "$scriv_root/apps/mac"
  --scratch-path "$scriv_work/build"
  --cache-path "$scriv_work/cache"
  --config-path "$scriv_work/config"
  --security-path "$scriv_work/security"
  --manifest-cache local
)

"$scriv_swift" --version
scriv_sources=()
while IFS= read -r -d '' scriv_source; do
  scriv_sources+=("$scriv_source")
done < <(find "$scriv_root/apps/mac/Sources" -name '*.swift' -type f -print0)
"$scriv_swiftc" -frontend -parse -swift-version 5 -module-cache-path "$scriv_work/module-cache" "${scriv_sources[@]}"
echo "PASS: Swift syntax (${#scriv_sources[@]} shared source files). This is parsing, not native SDK type-checking."
"$scriv_swift" build "${scriv_package_options[@]}" --configuration release --target ScrivCore
echo 'PASS: Portable optimized Swift core build. No native behavioral journey ran.'
bash "$scriv_root/scripts/verify-catalyst.sh"

if [[ "$scriv_mode" == --native ]]; then
  bash "$scriv_root/scripts/build-catalyst.sh"
  echo 'PASS: Catalyst development app packaging. Native UI interaction, fresh screenshots, signed releases and live-account checks remain separate gates.'
else
  echo 'NOT RUN: Native Catalyst SDK type-check/build, app launch, WebKit smoke and new screenshots. Portable checks do not certify native visual parity.'
fi
