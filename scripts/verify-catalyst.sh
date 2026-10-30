#!/usr/bin/env bash
# Portable integrity gates only; UIKit SDK compilation remains an Xcode gate.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
swiftc="${SCRIV_SWIFTC:-swiftc}"
work="${SCRIV_SWIFT_VERIFY_DIR:-$root/build/swift-verification}"
mkdir -p "$work/module-cache"
python3 scripts/generate-catalyst-project.py
python3 - <<'PY'
from pathlib import Path
import plistlib, re, xml.etree.ElementTree as ET
p=Path('apps/catalyst'); source=p/'ScrivUIKit'
files=list(source.rglob('*.swift'))+list((p/'MacRuntimeBridge').rglob('*.swift'))
for f in files:
    text="\n".join(line.split("//",1)[0] for line in f.read_text().splitlines())
    assert not re.search(r'^\s*import\s+(SwiftUI|AppKit)\b',text,re.M), f
    assert not re.search(r'\b(UIHostingController|NSHostingView|NSViewRepresentable|UIViewRepresentable)\b',text),f
project=(p/'ScrivUIKit.xcodeproj/project.pbxproj').read_text()
# The local package must not fall back to SwiftPM's older iOS/Catalyst defaults.
package = Path('apps/mac/Package.swift').read_text()
assert '.macOS(.v14)' in package
assert '.iOS(.v17)' in package
assert '.macCatalyst(.v17)' in package
assert set(re.findall(r'"IPHONEOS_DEPLOYMENT_TARGET" = "([^";]+)";', project)) == {'17.0'}
assert set(re.findall(r'"MACOSX_DEPLOYMENT_TARGET" = "([^";]+)";', project)) == {'14.0'}
# Project, app and tests must agree with SwiftPM's Debug architecture policy.
configs = re.findall(r'"isa" = "XCBuildConfiguration";\s*"name" = "(Debug|Release)";\s*"buildSettings" = \{(.*?)\n\t\t\t\};', project, re.S)
assert len(configs) == 6
for mode, settings in configs:
    expected = 'YES' if mode == 'Debug' else 'NO'
    assert f'"ONLY_ACTIVE_ARCH" = "{expected}";' in settings
assert not re.search(r'"(?:ARCHS|EXCLUDED_ARCHS)"\s*=', project)
assert 'PBXFileSystemSynchronizedRootGroup' in project
assert '../mac/Sources/ScrivApp/App.swift' not in project
assert 'Views/WorkspaceView.swift' not in project
assert 'Views/ProjectHistoryPresentation.swift' in project
for f in ['Info.plist','ScrivUIKit.entitlements']:
    with (p/f).open('rb') as stream: plistlib.load(stream)
ET.parse(p/'ScrivUIKit.xcodeproj/xcshareddata/xcschemes/ScrivUIKit.xcscheme')
print(f'PASS: {len(files)} UIKit/client sources exclude SwiftUI/AppKit hosting; target/plists/scheme parse.')
PY
sources=()
while IFS= read -r -d '' source; do sources+=("$source"); done < <(find apps/catalyst -name '*.swift' -type f -print0)
"$swiftc" -frontend -parse -swift-version 5 -module-cache-path "$work/module-cache" "${sources[@]}"
bash -n scripts/build-catalyst.sh apps/runtime-bridge/build-companion.sh
echo "PASS: ${#sources[@]} Catalyst source/test files syntax-parse and build scripts parse."
echo 'NOT RUN: UIKit SDK type-check/build, native interaction, bridge launch/pairing, generation or visual parity.'
