#!/usr/bin/env python3
"""Verify sealed release staging on any platform; never sign, extract or publish.

This verifies integrity against explicitly supplied public trust pins, not Apple
code signing, notarization, installation, UI consent or release-source provenance.
Native acceptance remains mandatory. No network, Keychain or subprocess is used.
"""
import argparse
import json
import re
import stat
import sys
from pathlib import Path
from io import BytesIO
import plistlib
import zipfile

import release


MANIFEST_FIELDS = {
    'schema', 'channel', 'feedURL', 'build', 'version', 'bundleID', 'teamID',
    'publicKey', 'artifactKey', 'artifactSHA256', 'artifactLength',
    'artifactSignature', 'feedKey', 'feedSHA256',
}
POINTER_FIELDS = {'schema', 'channel', 'build', 'feedKey', 'feedSHA256'}


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        release.require(key not in value, 'Duplicate JSON field.')
        value[key] = item
    return value


def bounded_file(folder, name, maximum):
    path = folder / name
    release.require(not path.is_symlink() and path.is_file(), 'Missing or non-regular staged file: ' + name)
    release.require(0 < path.stat().st_size <= maximum, 'Invalid staged file size: ' + name)
    with path.open('rb') as stream:
        data = stream.read(maximum + 1)
    release.require(0 < len(data) <= maximum, 'Staged file exceeded its bound: ' + name)
    return data


def verify_staged(folder, team, public_key, expected_build, channel):
    release.require(not folder.is_symlink() and folder.is_dir(), 'Choose an existing staging directory, not a symlink.')
    release.require(type(expected_build) is int and 0 < expected_build <= 999999999999999, 'Invalid expected build.')
    feed_url = release.channel_url(channel)
    manifest = json.loads(bounded_file(folder, 'manifest.json', 8192), object_pairs_hook=unique_object)
    pointer = json.loads(bounded_file(folder, 'channel.json', 2048), object_pairs_hook=unique_object)
    release.require(isinstance(manifest, dict) and set(manifest) == MANIFEST_FIELDS, 'Unexpected manifest fields.')
    release.require(isinstance(pointer, dict) and set(pointer) == POINTER_FIELDS, 'Unexpected channel fields.')
    release.require(type(manifest['schema']) is int and manifest['schema'] == 1, 'Unsupported manifest schema.')
    release.require(type(manifest['build']) is int and manifest['build'] == expected_build, 'Unexpected release build.')
    release.require(manifest['channel'] == channel and manifest['feedURL'] == feed_url, 'Unexpected release channel.')
    release.require(manifest['teamID'] == team and manifest['publicKey'] == public_key and manifest['bundleID'] == release.BUNDLE_ID, 'Release pins differ from trusted operator inputs.')
    release.require(all(isinstance(manifest[k], str) and re.fullmatch(r'[a-f0-9]{64}', manifest[k]) for k in ['artifactSHA256', 'feedSHA256']), 'Invalid content digest.')
    release.require(type(manifest['artifactLength']) is int and 0 < manifest['artifactLength'] <= release.MAX_ARCHIVE, 'Invalid archive length.')
    release.require(manifest['artifactKey'] == f"releases/{expected_build}/{manifest['artifactSHA256']}.zip", 'Archive key does not match build/digest.')
    release.require(manifest['feedKey'] == f"feeds/{manifest['feedSHA256']}.xml", 'Feed key does not match digest.')
    release.require(pointer == {key: manifest[key] for key in POINTER_FIELDS} and type(pointer['schema']) is int and type(pointer['build']) is int, 'Channel pointer differs from manifest.')
    feed = bounded_file(folder, 'appcast.xml', 256 * 1024)
    archive = bounded_file(folder, 'Scriv.zip', release.MAX_ARCHIVE)
    release.require(release.digest(feed) == manifest['feedSHA256'], 'Staged feed changed.')
    release.require(len(archive) == manifest['artifactLength'] and release.digest(archive) == manifest['artifactSHA256'], 'Staged archive changed.')
    # Authenticate opaque bytes before inspecting any ZIP entry. Never extract.
    release.verify_signature(archive, manifest['artifactSignature'], public_key)
    release.validate_feed_manifest(feed, manifest)
    with zipfile.ZipFile(BytesIO(archive)) as package:
        entries = [entry for entry in package.infolist() if entry.filename == 'Scriv.app/Contents/Info.plist']
        release.require(len(entries) == 1, 'Expected one app Info.plist.')
        entry = entries[0]
        release.require(not stat.S_ISLNK(entry.external_attr >> 16) and 0 < entry.file_size <= 1024 * 1024, 'Invalid app Info.plist entry.')
        info = plistlib.loads(package.read(entry))
    build = release.validate_info(info, team, public_key)
    release.require(build == expected_build and info['ScrivUpdateChannel'] == channel and info['CFBundleShortVersionString'] == manifest['version'], 'Signed archive metadata differs from manifest.')
    # validate_feed_manifest authenticates the feed; also compare display version.
    import xml.etree.ElementTree as ET
    xml = ET.fromstring(release.verify_feed(feed, public_key))
    version = xml.findtext('./channel/item/{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString')
    release.require(version == manifest['version'], 'Signed feed display version differs from archive.')
    return {'schema': 1, 'cryptographicArtifactIntegrityVerified': True,
            'nativeSigningNotarizationVerified': False, 'sourceProvenanceVerified': False,
            'installed': False, 'published': False, 'channel': channel, 'build': build,
            'version': manifest['version'], 'artifactSHA256': manifest['artifactSHA256'],
            'artifactLength': len(archive), 'feedSHA256': manifest['feedSHA256']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--staged', type=Path, required=True)
    parser.add_argument('--team', required=True)
    parser.add_argument('--public-key', required=True)
    parser.add_argument('--build', type=int, required=True)
    parser.add_argument('--channel', required=True)
    args = parser.parse_args()
    print(json.dumps(verify_staged(args.staged, args.team, args.public_key, args.build, args.channel), sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Do not echo operator paths, ZIP contents, parser input or credentials.
        print('BLOCKED: staged integrity verification failed (' + type(error).__name__ + '). No native trust, install or publication is claimed.', file=sys.stderr)
        raise SystemExit(1)
