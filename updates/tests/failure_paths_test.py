"""Previously uncovered acceptance-download failure boundaries.

All payloads are inert bytes and all private Ed25519 keys are ephemeral fixtures.
Native verification/extraction and network I/O are mocked only inside tests; these
checks do not prove macOS trust, Gatekeeper, installation, or app relaunch.
"""
import base64
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import acceptance as a
import release_test as fixtures

r = a.release


class DownloadFailureTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.ReleaseTests()
        self.fixture.setUp()
        self.fixture.info['ScrivUpdateChannel'] = 'acceptance-fixture'
        self.fixture.info['SUFeedURL'] = r.channel_url('acceptance-fixture')
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.manifest = {**self.fixture.fixture(self.root), 'teamID': 'TESTTEAM01',
                         'bundleID': r.BUNDLE_ID, 'version': '1.1'}
        self.feed = (self.root / 'appcast.xml').read_bytes()
        self.archive = (self.root / 'Scriv.zip').read_bytes()
        self.output = self.root / 'verified'

    def verify(self, manifest=None, **overrides):
        arguments = {'manifest': self.manifest if manifest is None else manifest,
                     'team': 'TESTTEAM01', 'public_key': self.fixture.public,
                     'expected_build': 2, 'channel': 'acceptance-fixture', 'output': self.output}
        arguments.update(overrides)
        return a.verify_download(**arguments)

    def test_wrong_operator_pins_channel_and_build_stop_before_network(self):
        for changed in [{'team': 'OTHERTEAM1'}, {'public_key': 'not-the-pin'},
                        {'expected_build': 1}, {'expected_build': 3}, {'channel': 'stable'}]:
            with self.subTest(changed=changed), patch.object(r.platform, 'system', return_value='Darwin'), patch.object(a, 'fetch_exact') as fetch, patch.object(r, 'run') as extract, patch.object(r, 'verify_app') as native:
                with self.assertRaises(ValueError): self.verify(**changed)
                fetch.assert_not_called(); extract.assert_not_called(); native.assert_not_called()
                self.assertFalse(self.output.exists())

    def test_unsigned_tampered_truncated_and_wrong_key_feeds_stop_before_archive(self):
        content = r.verify_feed(self.feed, self.fixture.public)
        wrong_signature = base64.b64encode(Ed25519PrivateKey.generate().sign(content)).decode()
        wrong_key_feed = content + f'<!-- sparkle-signatures:\nedSignature: {wrong_signature}\nlength: {len(content)}\n-->\n'.encode()
        cases = [content, self.feed.replace(b'Scriv updates', b'Scriv updXtes'), self.feed[:-4], wrong_key_feed]
        for feed in cases:
            # Even an attacker-updated hash in unsigned metadata cannot substitute
            # for the independently pinned cryptographic feed signature.
            manifest = {**self.manifest, 'feedSHA256': r.digest(feed)}
            with self.subTest(feed_bytes=len(feed)), patch.object(r.platform, 'system', return_value='Darwin'), patch.object(a, 'fetch_exact', return_value=feed) as fetch, patch.object(r, 'run') as extract, patch.object(r, 'verify_app') as native:
                with self.assertRaises(Exception): self.verify(manifest)
                self.assertEqual(fetch.call_count, 1)
                extract.assert_not_called(); native.assert_not_called()
                self.assertFalse(self.output.exists())

    def test_valid_signature_cannot_relabel_replayed_feed_as_new_build(self):
        with patch.object(r.platform, 'system', return_value='Darwin'), patch.object(a, 'fetch_exact', return_value=self.feed) as fetch, patch.object(r, 'run') as extract:
            with self.assertRaisesRegex(ValueError, 'Signed feed build differs'):
                self.verify({**self.manifest, 'build': 3}, expected_build=3)
            self.assertEqual(fetch.call_count, 1); extract.assert_not_called()
            self.assertFalse(self.output.exists())

    def test_interrupted_truncated_and_tampered_download_never_extract_or_create_output(self):
        cases = [TimeoutError('synthetic interrupted download'), self.archive[:-1], b'X' + self.archive[1:]]
        for archive in cases:
            with self.subTest(kind=type(archive).__name__), patch.object(r.platform, 'system', return_value='Darwin'), patch.object(a, 'fetch_exact', side_effect=[self.feed, archive]) as fetch, patch.object(r, 'run') as extract, patch.object(r, 'verify_app') as native:
                with self.assertRaises((ValueError, TimeoutError)): self.verify()
                self.assertEqual(fetch.call_count, 2)
                extract.assert_not_called(); native.assert_not_called()
                self.assertFalse(self.output.exists())

    def test_self_consistent_archive_hash_and_signed_feed_do_not_replace_archive_signature(self):
        archive = b'ANOTHER INERT FIXTURE; STILL NOT A MAC APP'
        manifest = {**self.manifest, 'artifactSHA256': r.digest(archive), 'artifactLength': len(archive),
                    'artifactKey': f'releases/2/{r.digest(archive)}.zip'}
        # This correctly signed feed intentionally carries the old archive's
        # signature. Verification must reject before extraction, not trust SHA.
        feed = self.fixture.signed(r.make_feed(self.fixture.info, manifest['artifactKey'], archive,
                                              manifest['artifactSignature'], 'Synthetic mismatched signature'))
        manifest['feedSHA256'] = r.digest(feed)
        with patch.object(r.platform, 'system', return_value='Darwin'), patch.object(a, 'fetch_exact', side_effect=[feed, archive]), patch.object(r, 'run') as extract, patch.object(r, 'verify_app') as native:
            with self.assertRaises(Exception): self.verify(manifest)
            extract.assert_not_called(); native.assert_not_called()
            self.assertFalse(self.output.exists())

    def test_native_trust_failure_cannot_return_success_after_valid_transport_signatures(self):
        with patch.object(r.platform, 'system', return_value='Darwin'), patch.object(a, 'fetch_exact', side_effect=[self.feed, self.archive]), patch.object(r, 'run') as extract, patch.object(r, 'verify_app', side_effect=ValueError('synthetic native trust rejection')) as native:
            with self.assertRaisesRegex(ValueError, 'native trust rejection'): self.verify()
            extract.assert_called_once(); native.assert_called_once()
            self.assertFalse((self.output / 'verification.json').exists())
            # Verified transport bytes remain for private diagnosis, not an install.
            self.assertEqual((self.output / 'Scriv.zip').read_bytes(), self.archive)

    def test_bounded_download_reads_only_limit_plus_one_and_rejects_oversize(self):
        class Response(io.BytesIO):
            status = 200
            def geturl(self): return r.ORIGIN + '/appcast.xml'
            def read(self, size=-1):
                self.requested = size
                return super().read(size)
        response = Response(b'0123456789EXCESS')
        with patch.object(a.urllib.request, 'build_opener') as opener:
            opener.return_value.open.return_value = response
            with self.assertRaisesRegex(ValueError, 'exceeded its bound'):
                a.fetch_exact(r.ORIGIN + '/appcast.xml', 10)
            self.assertEqual(response.requested, 11)

    def test_replayed_and_downgraded_publication_leave_channel_and_objects_unchanged(self):
        for prior_build in [2, 3]:
            client = fixtures.FakeS3()
            pointer = r.canonical({'schema': 1, 'channel': 'acceptance-fixture', 'build': prior_build})
            client.objects['channels/acceptance-fixture.json'] = pointer
            original = dict(client.objects)
            with self.subTest(prior_build=prior_build), self.assertRaisesRegex(ValueError, 'duplicate or lower'):
                r.publish(client, self.root, self.manifest, 'acceptance-fixture')
            self.assertEqual(client.calls, [])
            self.assertEqual(client.objects, original)


if __name__ == '__main__': unittest.main()
