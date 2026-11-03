import importlib.util
import plistlib
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('clt_build', ROOT / 'scripts/build-catalyst-clt.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class DevelopmentPolicyTests(unittest.TestCase):
    def test_identity_and_registration_are_separate(self):
        source = plistlib.loads((ROOT / 'apps/catalyst/Info.plist').read_bytes())
        info = module.development_info(source, 'app.scriv.cltfixture.a123')
        self.assertEqual(info['CFBundleIdentifier'], 'app.scriv.cltfixture.a123')
        for key in ('CFBundleURLTypes', 'CFBundleDocumentTypes', 'UTExportedTypeDeclarations', 'LSApplicationQueriesSchemes'):
            self.assertNotIn(key, info)
        self.assertFalse(info['SUEnableAutomaticChecks'])

    def test_production_or_invalid_identifiers_rejected(self):
        for identity in ('app.scriv.uikit', 'app.scriv.cltfixture.', 'app.scriv.cltfixture.foo/bar'):
            with self.subTest(identity=identity), self.assertRaises(ValueError):
                module.validate_development_identity(identity)

    def test_entitlements_keep_sandbox_and_scope_names(self):
        source = plistlib.loads((ROOT / 'apps/catalyst/ScrivUIKit.entitlements').read_bytes())
        result = module.development_entitlements(source, 'app.scriv.cltfixture.a123')
        self.assertTrue(result['com.apple.security.app-sandbox'])
        names = result.pop('com.apple.security.temporary-exception.mach-lookup.global-name')
        self.assertEqual(names, ['app.scriv.cltfixture.a123-spks', 'app.scriv.cltfixture.a123-spki'])
        source.pop('com.apple.security.temporary-exception.mach-lookup.global-name', None)
        self.assertEqual(result, source)
        source['com.apple.security.app-sandbox'] = False
        with self.assertRaises(ValueError): module.development_entitlements(source, 'app.scriv.cltfixture.a123')

    def test_nondevelopment_route_never_selects_icns(self):
        self.assertEqual(module.icon_verifier('release'), 'verify-catalyst-icon.py')
        self.assertEqual(module.icon_verifier('development-icns'), 'clt_icon.py')
        with self.assertRaises(ValueError): module.icon_verifier('other')
        release_script = (ROOT / 'scripts/build-catalyst.sh').read_text()
        self.assertIn('scripts/verify-catalyst-icon.py', release_script)

    def test_guard_requires_unique_sandbox_and_synthetic_argument(self):
        guard = module.development_main('app.scriv.cltfixture.a123')
        self.assertIn('--screenshots', guard)
        self.assertIn('app.scriv.cltfixture.a123', guard)
        self.assertIn('Library/Containers/', guard)
        self.assertIn('SCRIV_VERIFICATION_ROOT', guard)
        self.assertIn('exit(78)', guard)

if __name__ == '__main__': unittest.main()
