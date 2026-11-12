#!/usr/bin/env bash
# Local build checks and public CLI journeys; native acceptance is separate.
set -euo pipefail
scriv_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$scriv_root"
npm --prefix cloud ci
npm run check
npm test
npm run test:services
npm --prefix cloud run build
bash scripts/verify-native.sh --portable
echo 'Portable builds and CLI/service journeys complete. Native Catalyst scenarios require an explicitly selected automation app and were not run.'
