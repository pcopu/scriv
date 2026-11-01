import base64
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

spec = importlib.util.spec_from_file_location('release', Path(__file__).parents[1] / 'scripts/release.py')
r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)


class FakeS3:
    class exceptions:
        class NoSuchKey(Exception): pass
    def __init__(self): self.objects = {}; self.calls = []; self.conflict = False
    def get_object(self, Bucket, Key):
        if Key not in self.objects: raise self.exceptions.NoSuchKey()
        body = self.objects[Key]
        return {'Body': io.BytesIO(body), 'ETag': r.digest(body)}
    def put_object(self, **kwargs):
        key = kwargs['Key']; self.calls.append(kwargs)
        if kwargs.get('IfNoneMatch') == '*' and key in self.objects: raise ValueError('412')
        if 'IfMatch' in kwargs and (self.conflict or r.digest(self.objects.get(key, b'')) != kwargs['IfMatch']): raise ValueError('412')
        self.objects[key] = kwargs['Body']


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        # Test fixture only: never written or installed as a persistent key.
        self.key = Ed25519PrivateKey.generate()
        self.public = base64.b64encode(self.key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
        self.info = {'CFBundleIdentifier': r.BUNDLE_ID, 'CFBundleName': 'Scriv', 'CFBundleDisplayName': 'Scriv', 'CFBundleVersion': '2', 'CFBundleShortVersionString': '1.1', 'SUPublicEDKey': self.public, 'ScrivUpdateTeamIdentifier': 'TESTTEAM01', 'ScrivUpdateChannel': 'stable', 'SUFeedURL': r.ORIGIN + '/appcast.xml', 'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True, 'SUEnableInstallerLauncherService': True, 'SUSignedFeedFailureExpirationInterval': 0, 'SUEnableAutomaticChecks': False, 'SUAutomaticallyUpdate': False, 'SUAllowsAutomaticUpdates': False, 'SUEnableSystemProfiling': False, 'SUEnableDownloaderService': False}

    def signed(self, content):
        sig = base64.b64encode(self.key.sign(content)).decode()
        return content + f'<!-- sparkle-signatures:\nedSignature: {sig}\nlength: {len(content)}\n-->\n'.encode()

    def fixture(self, folder):
        archive = b'INERT TEST BYTES; NOT A MAC APPLICATION'
        signature = base64.b64encode(self.key.sign(archive)).decode()
        artifact_key = f'releases/2/{r.digest(archive)}.zip'
        feed = self.signed(r.make_feed(self.info, artifact_key, archive, signature, 'Plain <safe> notes'))
        manifest = {'schema': 1, 'channel': self.info['ScrivUpdateChannel'], 'feedURL': self.info['SUFeedURL'], 'build': 2, 'artifactKey': artifact_key, 'artifactSHA256': r.digest(archive), 'artifactLength': len(archive), 'artifactSignature': signature, 'feedKey': f'feeds/{r.digest(feed)}.xml', 'feedSHA256': r.digest(feed), 'publicKey': self.public}
        (folder / 'Scriv.zip').write_bytes(archive); (folder / 'appcast.xml').write_bytes(feed)
        return manifest

    def test_key_account_is_explicit_before_local_or_signing_work(self):
        # Parser failures must precede app inspection, note reads and Keychain use.
        args = ['release.py', '--app', '/nonexistent/Scriv.app', '--output', '/nonexistent/out',
                '--team', 'QF9687U3H9', '--public-key', '/32UNmbO5PdePvyUoZQnDzrpnC1c4PCayL0akOaDalU=',
                '--sign-update', '/nonexistent/sign_update', '--notes', '/nonexistent/notes']
        for extra in [[], ['--key-account', ''], ['--key-account', 'bad\naccount']]:
            with self.subTest(extra=extra), patch.object(sys, 'argv', args + extra), patch.object(r, 'prepare_release') as prepare, contextlib.redirect_stderr(io.StringIO()) as errors:
                with self.assertRaises(SystemExit) as result: r.main()
                self.assertEqual(result.exception.code, 2)
                self.assertIn('--key-account', errors.getvalue())
                prepare.assert_not_called()

    def test_supplied_public_pin_is_metadata_not_a_fixture_signing_key(self):
        public = '/32UNmbO5PdePvyUoZQnDzrpnC1c4PCayL0akOaDalU='
        info = {**self.info, 'SUPublicEDKey': public, 'ScrivUpdateTeamIdentifier': 'QF9687U3H9',
                'CFBundleVersion': '1001', 'ScrivUpdateChannel': 'acceptance-20261031',
                'SUFeedURL': r.channel_url('acceptance-20261031')}
        self.assertEqual(len(base64.b64decode(public, validate=True)), 32)
        self.assertEqual(r.validate_info(info, 'QF9687U3H9', public), 1001)
        for team, pin in [('TESTTEAM01', public), ('QF9687U3H9', self.public)]:
            with self.assertRaisesRegex(ValueError, 'pins differ'): r.validate_info(info, team, pin)
        # Only a synthetic ephemeral key is available here: it cannot sign as the real pin.
        with self.assertRaises(Exception): r.verify_signature(b'inert fixture', base64.b64encode(self.key.sign(b'inert fixture')), public)

    def test_staging_passes_exact_account_and_rejects_a_wrong_signer_before_feed(self):
        # Portable unit boundary: no native verification, real app, Keychain or publication.
        for wrong_signer in [False, True]:
            with self.subTest(wrong_signer=wrong_signer), tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / 'staged'; calls = []
                def fake_run(args):
                    if str(args[0]) == '/usr/bin/ditto':
                        if '-c' in args: Path(args[-1]).write_bytes(b'INERT UNIT FIXTURE; NOT A MAC APP')
                        return ''
                    calls.append(args)
                    self.assertEqual(args[1:3], ['--account', 'app.scriv.updates'])
                    path = Path(args[-1])
                    if '-p' in args:
                        key = Ed25519PrivateKey.generate() if wrong_signer else self.key
                        return base64.b64encode(key.sign(path.read_bytes())).decode()
                    path.write_bytes(self.signed(path.read_bytes()))
                    return ''
                with patch.object(r, 'verify_app', return_value=(self.info, 2)), patch.object(r, 'run', side_effect=fake_run):
                    if wrong_signer:
                        with self.assertRaises(Exception): r.prepare_release(Path('/fixture/Scriv.app'), output, 'TESTTEAM01', self.public, Path('/fixture/sign_update'), 'app.scriv.updates', 'Synthetic notes')
                        self.assertEqual(len(calls), 1)
                        self.assertFalse((output / 'manifest.json').exists())
                    else:
                        result = r.prepare_release(Path('/fixture/Scriv.app'), output, 'TESTTEAM01', self.public, Path('/fixture/sign_update'), 'app.scriv.updates', 'Synthetic notes')
                        self.assertEqual(len(calls), 2)
                        self.assertEqual(result['publicKey'], self.public)
                        r.validate_feed_manifest((output / 'appcast.xml').read_bytes(), result)

    def test_signed_feed_warning_and_multibyte_content_use_byte_length(self):
        # Sparkle 2.10.1 common_cli/Signing.swift signs the XML after adding its warning.
        content = '<?xml version="1.0"?><!-- sparkle-sign-warning: Synthetic warning --><rss>Scriv café → B</rss>'.encode()
        feed = self.signed(content)
        self.assertEqual(r.verify_feed(feed, self.public), content)
        bad = feed.replace(f'length: {len(content)}'.encode(), f'length: {len(content.decode())}'.encode())
        with self.assertRaisesRegex(ValueError, 'length mismatch'): r.verify_feed(bad, self.public)

    def test_valid_pins_and_fail_closed_configuration(self):
        self.assertEqual(r.validate_info(self.info, 'TESTTEAM01', self.public), 2)
        for mutation in [{'CFBundleIdentifier': 'another.app'}, {'CFBundleVersion': '1.2'}, {'CFBundleVersion': '-1'}, {'SUPublicEDKey': ''}, {'SUFeedURL': 'http://evil'}, {'SURequireSignedFeed': False}, {'SUSignedFeedFailureExpirationInterval': 1728000}, {'SUAllowsAutomaticUpdates': True}, {'CFBundleName': 'Scriv UIKit'}]:
            with self.subTest(mutation=mutation), self.assertRaises((ValueError, TypeError)):
                r.validate_info({**self.info, **mutation}, 'TESTTEAM01', self.public)

    def test_channel_is_signed_app_configuration_and_cannot_be_overridden(self):
        self.assertEqual(r.channel_url('stable'), r.ORIGIN + '/appcast.xml')
        self.assertEqual(r.channel_url('acceptance-20261031'), r.ORIGIN + '/channels/acceptance-20261031/appcast.xml')
        for channel in ['', '../stable', 'beta', 'acceptance-', 'acceptance-X', None]:
            with self.subTest(channel=channel), self.assertRaises(ValueError): r.channel_url(channel)
        with self.assertRaisesRegex(ValueError, 'channel/feed mismatch'):
            r.validate_info({**self.info, 'ScrivUpdateChannel': 'acceptance-20261031'}, 'TESTTEAM01', self.public)

    def test_acceptance_publication_cannot_touch_stable_or_wrong_channel(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.info['ScrivUpdateChannel'] = 'acceptance-20261031'
            self.info['SUFeedURL'] = r.channel_url(self.info['ScrivUpdateChannel'])
            folder = Path(tmp); manifest = self.fixture(folder); client = FakeS3()
            stable = b'unchanged stable sentinel'; client.objects['channels/stable.json'] = stable
            with self.assertRaisesRegex(ValueError, 'confirmation'):
                r.publish(client, folder, manifest, 'stable')
            self.assertEqual(client.calls, [])
            r.publish(client, folder, manifest, 'acceptance-20261031')
            self.assertEqual(client.objects['channels/stable.json'], stable)
            self.assertEqual(client.calls[-1]['Key'], 'channels/acceptance-20261031.json')

    def test_signature_metadata_tampering_truncation_wrong_key(self):
        feed = self.signed(b'<rss>build 2</rss>\n')
        self.assertEqual(r.verify_feed(feed, self.public), b'<rss>build 2</rss>\n')
        for bad in [feed.replace(b'build 2', b'build 1'), feed[:-5], feed + b'trailing', feed.replace(b'length: 19', b'length: 99')]:
            if bad != feed:
                with self.assertRaises(Exception): r.verify_feed(bad, self.public)
        other = Ed25519PrivateKey.generate().public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        with self.assertRaises(Exception): r.verify_feed(feed, base64.b64encode(other).decode())

    def test_macos_license_gate_has_no_portable_bypass_or_output(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(r.platform, 'system', return_value='Linux'):
            output = Path(tmp) / 'output'
            with self.assertRaisesRegex(ValueError, 'requires macOS'):
                r.prepare_release(Path(tmp) / 'Scriv.app', output, 'TESTTEAM01', self.public, Path('/fake'), 'test', 'notes')
            self.assertFalse(output.exists())

    def test_publish_commits_pointer_last_and_readback(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp); manifest = self.fixture(folder); client = FakeS3()
            r.publish(client, folder, manifest, manifest['channel'])
            self.assertEqual([x['Key'] for x in client.calls], [manifest['artifactKey'], manifest['feedKey'], 'manifests/stable/2.json', 'channels/stable.json'])
            self.assertTrue(all(x.get('IfNoneMatch') == '*' for x in client.calls))
            self.assertEqual(json.loads(client.objects['channels/stable.json'])['build'], 2)
            with self.assertRaisesRegex(ValueError, 'duplicate or lower'): r.publish(client, folder, manifest, manifest['channel'])

    def test_concurrent_publish_does_not_overwrite_pointer(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp); manifest = self.fixture(folder); client = FakeS3()
            old = r.canonical({'schema': 1, 'channel': 'stable', 'build': 1}); client.objects['channels/stable.json'] = old; client.conflict = True
            with self.assertRaisesRegex(ValueError, '412'): r.publish(client, folder, manifest, manifest['channel'])
            self.assertEqual(client.objects['channels/stable.json'], old)
            self.assertEqual(client.calls[-1]['IfMatch'], r.digest(old))

    def test_signed_feed_metadata_cannot_be_relabelled_or_rechannelled(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp); manifest = self.fixture(folder); client = FakeS3()
            # A signed feed cannot be relabelled into another signed app channel.
            wrong = {**manifest, 'channel':'acceptance-20261031', 'feedURL':r.channel_url('acceptance-20261031')}
            with self.assertRaisesRegex(ValueError, 'Signed feed channel'):
                r.publish(client, folder, wrong, 'acceptance-20261031')
            self.assertEqual(client.calls, [])
            with self.assertRaisesRegex(ValueError, 'immutable archive key'):
                r.publish(client, folder, {**manifest, 'build':1002}, 'stable')
            self.assertEqual(client.calls, [])

    def test_staging_tamper_stops_before_cloud_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp); manifest = self.fixture(folder); client = FakeS3()
            (folder / 'Scriv.zip').write_bytes(b'tamper')
            with self.assertRaisesRegex(ValueError, 'archive changed'): r.publish(client, folder, manifest, manifest['channel'])
            self.assertEqual(client.calls, [])

    def test_immutable_artifact_collision_stops_before_discovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp); manifest = self.fixture(folder); client = FakeS3()
            client.objects[manifest['artifactKey']] = b'preexisting'
            with self.assertRaisesRegex(ValueError, '412'): r.publish(client, folder, manifest, manifest['channel'])
            self.assertNotIn('channels/stable.json', client.objects)


if __name__ == '__main__': unittest.main()
