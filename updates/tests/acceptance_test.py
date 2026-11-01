import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

scripts = Path(__file__).parents[1] / 'scripts'
sys.path.insert(0, str(scripts))
import acceptance as a

class AcceptanceTests(unittest.TestCase):
    def test_project_inventory_is_read_only_and_detects_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'fixture.scriv'; root.mkdir(); (root / 'assets').mkdir()
            p = root / 'draft.txt'; p.write_text('SYNTHETIC ORIGINAL')
            before = a.project_inventory([root]); self.assertEqual(p.read_text(), 'SYNTHETIC ORIGINAL')
            p.write_text('SYNTHETIC EDIT'); self.assertNotEqual(a.project_inventory([root]), before)
            (root / 'alias').symlink_to(p)
            with self.assertRaisesRegex(ValueError, 'symlink'): a.project_inventory([root])
    def test_transition_requires_changed_binary_same_pins_and_exact_protected_bytes(self):
        before = {'schema':1,'kind':'installed-app-and-project-snapshot','app':'/fixture/Scriv.app','bundleID':'app.scriv.uikit','teamID':'TESTTEAM01','publicKey':'fixture','channel':'acceptance-test','build':1001,'executableSHA256':'a','runningProcess':{'pid':100,'capturedAt':1000,'launchedAt':900},'projects':{'fixture':{'files':{'draft':'hash'}}}}
        after = {**before, 'build':1002, 'executableSHA256':'b', 'runningProcess':{'pid':101,'capturedAt':1200,'launchedAt':1100}}
        self.assertTrue(a.compare(before, after, 1001, 1002)['identityAndProtectedProjectBytesVerified'])
        for changed in [{'build':1001},{'executableSHA256':'a'},{'channel':'stable'},{'teamID':'OTHERTEAM1'},{'projects':{}},{'runningProcess':before['runningProcess']}]:
            with self.subTest(changed=changed), self.assertRaises(ValueError): a.compare(before,{**after,**changed},1001,1002)
    def test_private_receipt_is_create_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'receipt.json';a.save_private(path, {'synthetic':True})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError): a.save_private(path, {})
    def test_redirects_and_other_origins_are_not_followed(self):
        with self.assertRaisesRegex(ValueError, 'redirected'): a.NoRedirect().redirect_request(None,None,302,None,None,'https://other.invalid')
        with self.assertRaisesRegex(ValueError, 'origin'): a.fetch_exact('https://other.invalid/file', 10)

if __name__ == '__main__': unittest.main()
