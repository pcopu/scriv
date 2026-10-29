#!/usr/bin/env bash
set -euo pipefail
scriv_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$scriv_root"
npm --prefix cloud ci
npm --prefix cloud run typecheck
npm --prefix cloud test
npm --prefix cloud run build
node scripts/check-repo.mjs
node --test tests/*.test.mjs
if [[ "$(uname -s)" == Darwin ]]; then
  bash scripts/verify-native.sh --native
else
  bash scripts/verify-native.sh --portable
  echo 'Cloud and portable checks complete. macOS UI build remains a separate required gate; it was not run.'
fi
