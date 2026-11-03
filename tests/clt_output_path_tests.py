import importlib.util
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('clt_build', ROOT / 'scripts/build-catalyst-clt.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)

class OutputIsolationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='scriv-path-test-', dir='/private/tmp')
        self.base = Path(self.temp.name)
        self.root = self.base / 'scratch'
        self.root.mkdir(mode=0o700)
        (self.root / '.scriv-clt-root').write_text('Scriv CLT isolated build root v1\n')

    def tearDown(self): self.temp.cleanup()

    def test_fresh_direct_child_in_private_owned_root_is_allowed(self):
        self.assertEqual(build.validate_output(self.root / 'fresh', self.root), self.root / 'fresh')
        self.assertFalse((self.root / 'fresh').exists())
        build.create_output(self.root / 'fresh', self.root)
        self.assertTrue((self.root / 'fresh').is_dir())
        with self.assertRaises(ValueError): build.create_output(self.root / 'fresh', self.root)

    def test_cli_rejects_checkout_before_accessing_dependency(self):
        target = ROOT / 'never-created-protected-output'
        result = subprocess.run([sys.executable, str(ROOT/'scripts/build-catalyst-clt.py'),
            '--development-icns', '--output', str(target), '--sparkle-framework', '/not/a/framework',
            '--sparkle-tree-sha256', '0'*64], capture_output=True, text=True,
            env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('fresh direct child', result.stderr)
        self.assertNotIn('framework directory', result.stderr)
        self.assertFalse(target.exists())

    def test_checkout_app_evidence_and_nested_paths_reject_without_writes(self):
        for path in (self.base/'checkout'/'build', self.base/'Signed.app'/'Contents'/'new',
                     self.base/'evidence'/'new', self.root/'nested'/'new', self.root/'..'/'outside'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                build.validate_output(path, self.root)
            self.assertFalse(path.exists())

    def test_existing_output_and_symlink_output_are_rejected(self):
        (self.root/'existing').mkdir()
        (self.root/'link').symlink_to(self.base/'missing')
        for name in ('existing', 'link'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                build.validate_output(self.root/name, self.root)

    def test_symlinked_root_or_ancestor_is_rejected(self):
        alias = self.base/'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError): build.validate_output(alias/'new', alias)
        self.assertFalse((self.root/'new').exists())

    def test_unmarked_or_world_accessible_root_is_rejected(self):
        marker = self.root/'.scriv-clt-root'
        marker.unlink()
        with self.assertRaises(ValueError): build.validate_output(self.root/'new', self.root)
        marker.write_text('Scriv CLT isolated build root v1\n')
        self.root.chmod(0o755)
        with self.assertRaises(ValueError): build.validate_output(self.root/'new', self.root)
        self.assertFalse((self.root/'new').exists())

    def test_marker_symlink_or_wrong_content_is_rejected(self):
        marker = self.root/'.scriv-clt-root'
        marker.unlink()
        marker.symlink_to(self.base/'target')
        with self.assertRaises(ValueError): build.validate_output(self.root/'new', self.root)
        marker.unlink()
        marker.write_text('wrong')
        with self.assertRaises(ValueError): build.validate_output(self.root/'new', self.root)
        self.assertFalse((self.root/'new').exists())

    def test_replaced_root_after_validation_rejects_before_creation(self):
        target = self.root / 'new'
        with build.acquire_output(target, self.root) as lease:
            original = self.base / 'original'
            self.root.rename(original)
            self.root.mkdir(mode=0o700)
            (self.root / '.scriv-clt-root').write_text('Scriv CLT isolated build root v1\n')
            with self.assertRaises(ValueError): lease.create()
            self.assertFalse((self.root / 'new').exists())
            self.assertFalse((original / 'new').exists())

    def test_replaced_marker_after_validation_rejects_before_creation(self):
        target = self.root / 'new'
        with build.acquire_output(target, self.root) as lease:
            marker = self.root / '.scriv-clt-root'
            marker.unlink()
            marker.write_text('invalid')
            with self.assertRaises(ValueError): lease.create()
            self.assertFalse(target.exists())

    def test_swap_during_mkdir_still_creates_in_open_directory(self):
        target = self.root / 'new'
        original = self.base / 'original'
        real_mkdir = os.mkdir
        with build.acquire_output(target, self.root) as lease:
            def swap_then_mkdir(name, mode=0o777, *, dir_fd=None):
                self.root.rename(original)
                real_mkdir(self.root, 0o700)
                (self.root / '.scriv-clt-root').write_text('Scriv CLT isolated build root v1\n')
                return real_mkdir(name, mode, dir_fd=dir_fd)
            with mock.patch.object(build.os, 'mkdir', side_effect=swap_then_mkdir):
                lease.create()
        self.assertTrue((original / 'new').is_dir())
        self.assertFalse(target.exists())

if __name__ == '__main__': unittest.main()
