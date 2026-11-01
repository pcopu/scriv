#!/usr/bin/env python3
"""Build and optionally publish a verified release. Never creates signing keys.

Requires a previously Developer ID-signed, stapled, notarized Scriv.app and
Sparkle 2.10.1 sign_update using an existing Keychain account. --publish is the
only network-writing mode. No credentials or user projects enter the bundle.
"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape, quoteattr

ORIGIN = 'https://scriv-updates.why-not.work'
ACCOUNT = '607b7c9e36c45e8c51e003923d1d0913'
BUCKET = 'scriv-updates'
BUNDLE_ID = 'app.scriv.uikit'
SPARKLE_VERSION = '2.10.1'
MAX_ARCHIVE = 512 * 1024 * 1024
SIGNATURE_BLOCK = re.compile(rb'<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]{86}==)\nlength: ([0-9]+)\n-->\n\Z')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


def verify_signature(data, signature, public_key):
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    raw = base64.b64decode(public_key, validate=True)
    require(len(raw) == 32, 'The pinned public Ed25519 key must contain 32 bytes.')
    Ed25519PublicKey.from_public_bytes(raw).verify(base64.b64decode(signature, validate=True), data)


def verify_feed(data, public_key):
    require(len(data) <= 256 * 1024, 'Feed is too large.')
    match = SIGNATURE_BLOCK.search(data)
    require(match is not None, 'Missing Sparkle signed-feed block.')
    content = data[:match.start()]
    require(len(content) == int(match[2]), 'Signed feed length mismatch.')
    verify_signature(content, match[1], public_key)
    return content


def channel_url(channel):
    require(isinstance(channel, str) and (channel == 'stable' or re.fullmatch(r'acceptance-[a-z0-9][a-z0-9-]{0,47}', channel)), 'Invalid update channel.')
    return ORIGIN + ('/appcast.xml' if channel == 'stable' else f'/channels/{channel}/appcast.xml')


def validate_info(info, team, public_key):
    require(re.fullmatch(r'[A-Z0-9]{10}', team), 'Provide the real Apple Developer Team ID.')
    require(len(base64.b64decode(public_key, validate=True)) == 32, 'Provide the real public Ed25519 key.')
    require(info.get('CFBundleIdentifier') == BUNDLE_ID, 'Do not change the bundle ID or data container.')
    require(info.get('CFBundleName') == 'Scriv' and info.get('CFBundleDisplayName') == 'Scriv', 'The app display name must be Scriv.')
    require(re.fullmatch(r'[1-9][0-9]{0,14}', str(info.get('CFBundleVersion', ''))), 'Build must be a positive monotonic integer.')
    require(re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', str(info.get('CFBundleShortVersionString', ''))), 'Invalid marketing version.')
    require(info.get('SUPublicEDKey') == public_key and info.get('ScrivUpdateTeamIdentifier') == team, 'App signing pins differ from requested release pins.')
    require(info.get('SUFeedURL') == channel_url(info.get('ScrivUpdateChannel')), 'Signed channel/feed mismatch.')
    require(all(info.get(k) is True for k in ['SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction', 'SUEnableInstallerLauncherService']), 'Required update security policy missing.')
    require(info.get('SUSignedFeedFailureExpirationInterval') == 0, 'Signed-feed fallback must be disabled.')
    require(all(info.get(k) is False for k in ['SUEnableAutomaticChecks', 'SUAutomaticallyUpdate', 'SUAllowsAutomaticUpdates', 'SUEnableSystemProfiling', 'SUEnableDownloaderService']), 'Silent updates or profiling must not be enabled.')
    return int(info['CFBundleVersion'])


def run(args):
    result = subprocess.run([str(x) for x in args], check=True, capture_output=True, text=True)
    return result.stdout.strip()


def verify_app(app, team, public_key):
    require(platform.system() == 'Darwin', 'Release verification requires macOS, Developer ID signing, and notarization. No portable bypass exists.')
    require(app.name == 'Scriv.app' and app.is_dir() and not app.is_symlink(), 'Choose the actual exported Scriv.app, not a symlink or renamed development artifact.')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    build = validate_info(info, team, public_key)
    framework = app / 'Contents/PlugIns/ScrivUpdatePlugin.bundle/Contents/Frameworks/Sparkle.framework'
    sparkle_info = plistlib.loads((framework / 'Resources/Info.plist').read_bytes())
    require(sparkle_info.get('CFBundleShortVersionString') == SPARKLE_VERSION, 'Unexpected Sparkle version; audit and update the pin first.')
    rule = f'=anchor apple generic and identifier "{BUNDLE_ID}" and certificate leaf[subject.OU] = "{team}" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', '--test-requirement', rule, app])
    # A complete release includes the native adapter and same-team private XPC.
    # Deep verification alone does not assert their intended exact identities.
    for relative, identifier in [
        ('Contents/PlugIns/ScrivUpdatePlugin.bundle', 'app.scriv.uikit.updates'),
        ('Contents/XPCServices/com.scriv.runtime-companion.bootstrap.xpc', 'com.scriv.runtime-companion.bootstrap'),
    ]:
        nested = app / relative
        require(nested.is_dir() and not nested.is_symlink(), 'Missing native connection component: ' + relative)
        nested_rule = rule.replace(f'identifier "{BUNDLE_ID}"', f'identifier "{identifier}"')
        run(['/usr/bin/codesign', '--verify', '--strict', '--all-architectures', '--test-requirement', nested_rule, nested])
    run(['/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=4', app])
    run(['/usr/bin/xcrun', 'stapler', 'validate', app])
    return info, build


def make_feed(info, artifact_key, archive, signature, notes):
    require(len(notes.encode()) <= 16000 and not any(ord(c) < 32 and c not in '\n\t' for c in notes), 'Release notes must be short plain text.')
    # Metadata comes from the code-signed application, never caller-supplied build/version strings.
    minimum = info.get('LSMinimumSystemVersion', '14.0')
    require(re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', minimum), 'Invalid minimum macOS version.')
    return f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>Scriv updates</title><link>{escape(info['SUFeedURL'])}</link><description>Signed Scriv releases</description>
<item><title>Scriv {escape(info['CFBundleShortVersionString'])}</title>
<sparkle:version>{info['CFBundleVersion']}</sparkle:version>
<sparkle:channel>{escape(info['ScrivUpdateChannel'])}</sparkle:channel>
<sparkle:shortVersionString>{escape(info['CFBundleShortVersionString'])}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>
<description sparkle:format="plain-text">{escape(notes)}</description>
<enclosure url={quoteattr(ORIGIN + '/' + artifact_key)} sparkle:edSignature={quoteattr(signature)} length="{len(archive)}" type="application/octet-stream" />
</item></channel></rss>
'''.encode()


def prepare_release(app, output, team, public_key, sign_update, key_account, notes):
    # Verify before creating output; a missing license is a hard stop, not a warning.
    info, build = verify_app(app, team, public_key)
    require(not output.exists(), 'Output directory already exists; use a new release staging directory.')
    output.mkdir(parents=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix='scriv-release-', dir=output) as tmp:
        archive_path = Path(tmp) / 'Scriv.zip'
        run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive_path])
        require(0 < archive_path.stat().st_size <= MAX_ARCHIVE, 'Archive exceeds the 512 MiB release limit.')
        archive = archive_path.read_bytes()
        # Verify again after packaging so concurrent app changes are not silently published.
        verify_app(app, team, public_key)
        unpacked = Path(tmp) / 'verified'
        run(['/usr/bin/ditto', '-x', '-k', archive_path, unpacked])
        archived_info, archived_build = verify_app(unpacked / 'Scriv.app', team, public_key)
        require(archived_info == info and archived_build == build, 'App changed during packaging.')
        signature = run([sign_update, '--account', key_account, '-p', archive_path])
        verify_signature(archive, signature, public_key)
        artifact_key = f'releases/{build}/{digest(archive)}.zip'
        feed_path = Path(tmp) / 'appcast.xml'
        feed_path.write_bytes(make_feed(info, artifact_key, archive, signature, notes))
        run([sign_update, '--account', key_account, feed_path])
        feed = feed_path.read_bytes()
        verify_feed(feed, public_key)
        manifest = {'schema': 1, 'channel': info['ScrivUpdateChannel'], 'feedURL': info['SUFeedURL'], 'build': build, 'version': info['CFBundleShortVersionString'], 'bundleID': BUNDLE_ID, 'teamID': team, 'publicKey': public_key, 'artifactKey': artifact_key, 'artifactSHA256': digest(archive), 'artifactLength': len(archive), 'artifactSignature': signature, 'feedKey': f'feeds/{digest(feed)}.xml', 'feedSHA256': digest(feed)}
        (output / 'Scriv.zip').write_bytes(archive)
        (output / 'appcast.xml').write_bytes(feed)
        (output / 'manifest.json').write_bytes(canonical(manifest))
        (output / 'channel.json').write_bytes(canonical({k: manifest[k] for k in ['schema', 'channel', 'build', 'feedKey', 'feedSHA256']}))
    return manifest


def validate_feed_manifest(feed, manifest):
    content = verify_feed(feed, manifest['publicKey'])
    require(b'<!DOCTYPE' not in content and b'<!ENTITY' not in content, 'Unexpected XML declarations.')
    xml = ET.fromstring(content)
    items = xml.findall('./channel/item')
    require(len(items) == 1, 'Expected one exact signed release item.')
    item = items[0]; ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
    enclosure = item.find('enclosure')
    require(item.findtext(ns + 'version') == str(manifest['build']), 'Signed feed build differs from manifest.')
    require(item.findtext(ns + 'channel') == manifest['channel'], 'Signed feed channel differs from manifest.')
    require(xml.findtext('./channel/link') == manifest['feedURL'], 'Signed feed URL differs from manifest.')
    require(enclosure is not None and enclosure.get('url') == ORIGIN + '/' + manifest['artifactKey'], 'Signed archive URL differs from manifest.')
    require(enclosure.get(ns + 'edSignature') == manifest['artifactSignature'] and enclosure.get('length') == str(manifest['artifactLength']), 'Signed archive metadata differs from manifest.')


def publish(client, output, manifest, confirmed_channel):
    channel = manifest.get('channel')
    require(channel_url(channel) == manifest.get('feedURL'), 'Invalid manifest channel.')
    require(confirmed_channel == channel, 'Publication requires confirmation of the exact signed channel.')
    require(isinstance(manifest.get('build'), int) and 0 < manifest['build'] <= 999999999999999, 'Invalid manifest build.')
    require(manifest['artifactKey'] == f"releases/{manifest['build']}/{manifest['artifactSHA256']}.zip" and re.fullmatch(r'[a-f0-9]{64}', manifest['artifactSHA256']), 'Invalid immutable archive key.')
    require(manifest['feedKey'] == f"feeds/{manifest['feedSHA256']}.xml" and re.fullmatch(r'[a-f0-9]{64}', manifest['feedSHA256']), 'Invalid immutable feed key.')
    pointer_key = f'channels/{channel}.json'
    archive = (output / 'Scriv.zip').read_bytes(); feed = (output / 'appcast.xml').read_bytes()
    require(digest(archive) == manifest['artifactSHA256'] and len(archive) == manifest['artifactLength'], 'Staged archive changed.')
    require(digest(feed) == manifest['feedSHA256'], 'Staged feed changed.')
    verify_signature(archive, manifest['artifactSignature'], manifest['publicKey']); validate_feed_manifest(feed, manifest)
    try:
        previous = client.get_object(Bucket=BUCKET, Key=pointer_key)
        old = json.loads(previous['Body'].read())
        require(old.get('channel') == channel and isinstance(old.get('build'), int) and old['build'] < manifest['build'], 'Refusing a duplicate or lower release build. Recovery releases need a higher build number.')
        condition = {'IfMatch': previous['ETag']}
    except client.exceptions.NoSuchKey:
        condition = {'IfNoneMatch': '*'}
    # Create-once writes. On a network timeout do not blindly retry: inspect
    # exact content/hash and current pointer; an in-flight write may commit.
    client.put_object(Bucket=BUCKET, Key=manifest['artifactKey'], Body=archive, ContentType='application/zip', Metadata={'sha256': manifest['artifactSHA256']}, IfNoneMatch='*')
    client.put_object(Bucket=BUCKET, Key=manifest['feedKey'], Body=feed, ContentType='application/xml', IfNoneMatch='*')
    client.put_object(Bucket=BUCKET, Key=f"manifests/{channel}/{manifest['build']}.json", Body=canonical(manifest), ContentType='application/json', IfNoneMatch='*')
    # Compare-and-swap commits discovery last, never before the bytes exist.
    pointer = canonical({k: manifest[k] for k in ['schema', 'channel', 'build', 'feedKey', 'feedSHA256']})
    client.put_object(Bucket=BUCKET, Key=pointer_key, Body=pointer, ContentType='application/json', CacheControl='no-store', **condition)
    readback = client.get_object(Bucket=BUCKET, Key=pointer_key)['Body'].read()
    require(readback == pointer, 'Pointer changed after publication. Inspect release state; do not retry automatically.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True); parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--team', required=True); parser.add_argument('--public-key', required=True)
    parser.add_argument('--sign-update', type=Path, required=True); parser.add_argument('--key-account', required=True, help='Explicit existing Sparkle Keychain account; never creates or exports a key')
    parser.add_argument('--notes', type=Path, required=True); parser.add_argument('--publish', action='store_true')
    parser.add_argument('--confirm-channel', help='Required with --publish; must exactly match the channel sealed into the app')
    args = parser.parse_args()
    if not args.key_account.strip() or any(ord(c) < 32 for c in args.key_account): parser.error('--key-account must name an explicit existing account')
    if args.publish and not args.confirm_channel: parser.error('--publish requires --confirm-channel with the exact signed channel')
    manifest = prepare_release(args.app.resolve(), args.output, args.team, args.public_key, args.sign_update.resolve(), args.key_account, args.notes.read_text())
    if args.publish:
        import boto3
        from botocore.config import Config
        # Existing bucket-scoped S3 credentials through environment/SDK chain.
        # No secret arguments, secret output, new keys or configuration writes.
        client = boto3.client('s3', endpoint_url=f'https://{ACCOUNT}.r2.cloudflarestorage.com', region_name='auto', config=Config(retries={'max_attempts': 0}))
        publish(client, args.output, manifest, args.confirm_channel)
        print(f"Published and read back Scriv build {manifest['build']} to {manifest['channel']}.")
    else:
        print(f"Verified release staged at {args.output}. No cloud writes were made.")


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Never print subprocess output or SDK request details, which may contain
        # account information. Keep exact local checks available to the operator.
        if isinstance(error, subprocess.CalledProcessError):
            print(f'BLOCKED: {Path(error.cmd[0]).name} failed with exit {error.returncode}. No success is claimed; inspect retained staging and any attempted publication before retrying.', file=sys.stderr)
        else:
            print(f'BLOCKED: {type(error).__name__}: {error}', file=sys.stderr)
        sys.exit(1)
