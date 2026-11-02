import base64
from io import BytesIO
import json
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import release as r
import verify_staged as v


class StagedTests(unittest.TestCase):
    def setUp(self):
        # Ephemeral synthetic fixture only; never a real app or persistent key.
        self.key = Ed25519PrivateKey.generate()
        self.public = base64.b64encode(self.key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
        self.info = {'CFBundleIdentifier': r.BUNDLE_ID, 'CFBundleName': 'Scriv', 'CFBundleDisplayName': 'Scriv', 'CFBundleVersion': '1004', 'CFBundleShortVersionString': '1.1', 'SUPublicEDKey': self.public, 'ScrivUpdateTeamIdentifier': 'TESTTEAM01', 'ScrivUpdateChannel': 'stable', 'SUFeedURL': r.channel_url('stable'), 'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True, 'SUEnableInstallerLauncherService': True, 'SUSignedFeedFailureExpirationInterval': 0, 'SUEnableAutomaticChecks': False, 'SUAutomaticallyUpdate': False, 'SUAllowsAutomaticUpdates': False, 'SUEnableSystemProfiling': False, 'SUEnableDownloaderService': False}

    def fixture(self, folder, info=None, feed_version=None, duplicate=False, symlink=False):
        info = info or self.info
        buf = BytesIO()
        entry = zipfile.ZipInfo('Scriv.app/Contents/Info.plist')
        entry.create_system = 3
        entry.external_attr = ((stat.S_IFLNK if symlink else stat.S_IFREG) | 0o644) << 16
        with warnings.catch_warnings(), zipfile.ZipFile(buf, 'w') as z:
            warnings.simplefilter('ignore', UserWarning)
            z.writestr(entry, plistlib.dumps(info))
            if duplicate: z.writestr(entry, plistlib.dumps(info))
        archive = buf.getvalue()
        signature = base64.b64encode(self.key.sign(archive)).decode()
        key = f'releases/1004/{r.digest(archive)}.zip'
        feed = r.make_feed({**self.info, **({'CFBundleShortVersionString': feed_version} if feed_version else {})}, key, archive, signature, 'Synthetic verification fixture; not executable.')
        feed += f'<!-- sparkle-signatures:\nedSignature: {base64.b64encode(self.key.sign(feed)).decode()}\nlength: {len(feed)}\n-->\n'.encode()
        manifest = {'schema': 1, 'channel': 'stable', 'feedURL': r.channel_url('stable'), 'build': 1004, 'version': '1.1', 'bundleID': r.BUNDLE_ID, 'teamID': 'TESTTEAM01', 'publicKey': self.public, 'artifactKey': key, 'artifactSHA256': r.digest(archive), 'artifactLength': len(archive), 'artifactSignature': signature, 'feedKey': f'feeds/{r.digest(feed)}.xml', 'feedSHA256': r.digest(feed)}
        (folder / 'Scriv.zip').write_bytes(archive)
        (folder / 'appcast.xml').write_bytes(feed)
        (folder / 'manifest.json').write_bytes(r.canonical(manifest))
        (folder / 'channel.json').write_bytes(r.canonical({k: manifest[k] for k in v.POINTER_FIELDS}))
        return manifest

    def verify(self, folder, **kwargs):
        return v.verify_staged(folder, kwargs.get('team', 'TESTTEAM01'), kwargs.get('public_key', self.public), kwargs.get('build', 1004), kwargs.get('channel', 'stable'))

    def test_integrity_result_is_read_only_and_never_claims_native_acceptance(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp); self.fixture(folder)
            before = {p.name: p.read_bytes() for p in folder.iterdir()}
            with patch.object(r, 'run', side_effect=AssertionError('No subprocess allowed')) as run, patch.object(r, 'publish', side_effect=AssertionError('No publication allowed')) as publish:
                result = self.verify(folder)
                run.assert_not_called()
                publish.assert_not_called()
            self.assertTrue(result['cryptographicArtifactIntegrityVerified'])
            for k in ['nativeSigningNotarizationVerified', 'sourceProvenanceVerified', 'installed', 'published']:
                self.assertIs(result[k], False)
            self.assertEqual(before, {p.name: p.read_bytes() for p in folder.iterdir()})

    def test_explicit_trusted_operator_pins_build_channel_are_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp); self.fixture(folder)
            for kwargs in [{'team': 'OTHERTEAM1'}, {'public_key': base64.b64encode(b'x' * 32).decode()}, {'build': 1005}, {'build': True}, {'channel': 'acceptance-test'}, {'channel': '../stable'}]:
                with self.subTest(kwargs=kwargs), self.assertRaises(ValueError): self.verify(folder, **kwargs)

    def test_tampered_signed_bytes_fail(self):
        for name in ['Scriv.zip', 'appcast.xml']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                folder = Path(tmp); self.fixture(folder)
                path = folder / name; path.write_bytes(path.read_bytes() + b'tamper')
                with self.assertRaises(ValueError): self.verify(folder)

    def test_relabelled_digests_do_not_bypass_signature_verification(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp); m = self.fixture(folder)
            archive = (folder / 'Scriv.zip').read_bytes() + b'tamper'
            (folder / 'Scriv.zip').write_bytes(archive)
            m.update(artifactSHA256=r.digest(archive), artifactLength=len(archive), artifactKey=f'releases/1004/{r.digest(archive)}.zip')
            (folder / 'manifest.json').write_bytes(r.canonical(m))
            with self.assertRaises(Exception): self.verify(folder)

    def test_pointer_mismatch_unknown_fields_and_duplicate_json_fail(self):
        for mode in ['pointer', 'manifest-extra', 'duplicate', 'schema-bool', 'build-bool']:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                folder = Path(tmp); m = self.fixture(folder)
                if mode == 'pointer':
                    p = json.loads((folder / 'channel.json').read_text()); p['build'] = 1005
                    (folder / 'channel.json').write_bytes(r.canonical(p))
                elif mode == 'duplicate':
                    p = folder / 'manifest.json'; p.write_text(p.read_text().replace('{', '{"schema":1,', 1))
                else:
                    m[{'manifest-extra': 'unexpected', 'schema-bool': 'schema', 'build-bool': 'build'}[mode]] = True
                    (folder / 'manifest.json').write_bytes(r.canonical(m))
                with self.assertRaises(ValueError): self.verify(folder)

    def test_content_addresses_must_match_build_and_digest(self):
        for changed in [{'artifactKey': 'releases/1003/' + 'a' * 64 + '.zip'}, {'feedKey': 'feeds/' + 'b' * 64 + '.xml'}, {'artifactLength': True}]:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as tmp:
                folder = Path(tmp); m = self.fixture(folder);m.update(changed)
                (folder / 'manifest.json').write_bytes(r.canonical(m))
                with self.assertRaises(ValueError): self.verify(folder)

    def test_signed_archive_metadata_and_security_policy_are_checked(self):
        for changed in [{'CFBundleVersion': '1003'}, {'CFBundleShortVersionString': '0.1'}, {'SURequireSignedFeed': False}, {'SUAllowsAutomaticUpdates': True}, {'ScrivUpdateTeamIdentifier': 'OTHERTEAM1'}]:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as tmp:
                folder = Path(tmp); self.fixture(folder, info={**self.info, **changed})
                with self.assertRaises(ValueError): self.verify(folder)

    def test_signed_feed_display_version_must_match_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp); self.fixture(folder, feed_version='9.9')
            with self.assertRaisesRegex(ValueError, 'display version'): self.verify(folder)

    def test_duplicate_or_symlinked_app_metadata_is_not_read(self):
        for kwargs in [{'duplicate': True}, {'symlink': True}]:
            with self.subTest(kwargs=kwargs), tempfile.TemporaryDirectory() as tmp:
                folder = Path(tmp); self.fixture(folder, **kwargs)
                with self.assertRaises(ValueError): self.verify(folder)

    def test_symlinked_or_oversized_staged_control_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp); self.fixture(folder)
            p = folder / 'manifest.json'; data = p.read_bytes();p.unlink()
            other = folder / 'other.json';other.write_bytes(data);p.symlink_to(other)
            with self.assertRaises(ValueError): self.verify(folder)
            p.unlink();p.write_bytes(b'x' * 8193)
            with self.assertRaises(ValueError): self.verify(folder)


if __name__ == '__main__': unittest.main()
