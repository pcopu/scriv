#!/usr/bin/env python3
"""Verify Xcode actually compiled the primary icon, never patch a built bundle."""
from pathlib import Path
import plistlib
import sys

app = Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
resources = app / 'Contents/Resources'
primary = info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {})
icon_name = info.get('CFBundleIconName') or primary.get('CFBundleIconName')
icon_file = info.get('CFBundleIconFile', '')
compiled_icon = resources / (icon_file if icon_file.endswith('.icns') else icon_file + '.icns')
assert icon_name == 'AppIcon' or icon_file.startswith('AppIcon'), 'Primary AppIcon metadata is missing'
assert (resources / 'Assets.car').is_file(), 'Compiled asset catalog is missing'
assert compiled_icon.is_file() or primary.get('CFBundleIconFiles'), 'Compiled primary icon resource is missing'
print('Verified Xcode-compiled primary AppIcon metadata and resources.')
