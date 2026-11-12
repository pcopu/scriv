#!/usr/bin/env bash
# Compile/syntax checks only. Behavioral tests enter through Tracer.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
swiftc="${SCRIV_SWIFTC:-swiftc}"
work="${SCRIV_SWIFT_VERIFY_DIR:-$root/build/swift-verification}"
mkdir -p "$work/module-cache"
python3 scripts/generate-catalyst-project.py
sources=()
while IFS= read -r -d '' source; do sources+=("$source"); done < <(find apps/catalyst -name '*.swift' -type f -print0)
"$swiftc" -frontend -parse -swift-version 5 -module-cache-path "$work/module-cache" "${sources[@]}"
bash -n scripts/build-catalyst.sh apps/runtime-bridge/build-companion.sh
echo "PASS: ${#sources[@]} Catalyst source files syntax-parse and build scripts parse."
echo 'NOT RUN: UIKit SDK type-check/build, native interaction, bridge launch/pairing, generation or visual parity.'
