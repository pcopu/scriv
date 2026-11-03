import importlib.util
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("clt_icon", ROOT / "scripts/clt_icon.py")
icon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icon)
APPROVED = ROOT / "apps/catalyst/ScrivUIKit/Assets.xcassets/AppIcon.appiconset"

class DevelopmentIconContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="scriv-icon-test-")
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        shutil.copytree(APPROVED, self.source)
        self.output = self.root / "AppIcon.icns"
        self.info = {"CFBundleIconFile": "AppIcon.icns"}
        icon.build(self.source, self.output)

    def tearDown(self):
        self.temp.cleanup()

    def test_complete_source_backed_icon_passes(self):
        icon.verify(self.source, self.output, self.info)
        self.assertFalse((self.root / "Assets.car").exists())

    def test_changed_icon_bytes_are_rejected(self):
        data = bytearray(self.output.read_bytes())
        data[40] ^= 1
        self.output.write_bytes(data)
        with self.assertRaises(ValueError): icon.verify(self.source, self.output, self.info)

    def test_missing_chunk_is_rejected(self):
        data = self.output.read_bytes()
        length = struct.unpack(">I", data[12:16])[0]
        body = data[8 + length:]
        self.output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
        with self.assertRaises(ValueError): icon.verify(self.source, self.output, self.info)

    def test_duplicate_chunk_is_rejected(self):
        data = self.output.read_bytes()
        length = struct.unpack(">I", data[12:16])[0]
        body = data[8:] + data[8:8 + length]
        self.output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
        with self.assertRaises(ValueError): icon.verify(self.source, self.output, self.info)

    def test_wrong_bundle_icon_metadata_is_rejected(self):
        with self.assertRaises(ValueError): icon.verify(self.source, self.output, {"CFBundleIconFile": "Other.icns"})

    def test_wrong_source_dimensions_are_rejected(self):
        shutil.copyfile(self.source / "icon_32x32.png", self.source / "icon_16x16.png")
        with self.assertRaises(ValueError): icon.verify(self.source, self.output, self.info)

    def test_existing_icon_is_not_overwritten(self):
        before = self.output.read_bytes()
        with self.assertRaises(ValueError): icon.build(self.source, self.output)
        self.assertEqual(self.output.read_bytes(), before)

    def test_development_icon_does_not_satisfy_catalog_gate(self):
        contents = self.root / "Scriv.app/Contents"
        resources = contents / "Resources"
        resources.mkdir(parents=True)
        shutil.copyfile(self.output, resources / "AppIcon.icns")
        (contents / "Info.plist").write_bytes(plistlib.dumps(self.info))
        result = subprocess.run([sys.executable, str(ROOT / "scripts/verify-catalyst-icon.py"),
                                 str(contents.parent)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Compiled asset catalog is missing", result.stderr)

if __name__ == "__main__":
    unittest.main()
