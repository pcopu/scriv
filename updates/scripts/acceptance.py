#!/usr/bin/env python3
"""Read-only signed update acceptance checks. Never installs, launches or publishes.

Receipts contain local project paths/hashes: retain privately on the test Mac,
not in source control, Cloudflare, Library or a public diagnostic upload.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import urllib.request
import release


def file_hash(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''): value.update(block)
    return value.hexdigest()


def project_inventory(projects):
    result = {}
    for selected in projects:
        release.require(not selected.is_symlink() and selected.is_dir(), 'Choose an existing project directory, not a symlink.')
        root = selected.resolve()
        release.require(str(root) not in result, 'Duplicate selected project.')
        files = {}; directories = []
        def fail_walk(error): raise error
        for current, dirs, names in os.walk(root, followlinks=False, onerror=fail_walk):
            parent = Path(current)
            for name in dirs:
                path = parent / name
                release.require(not path.is_symlink(), 'Project contains a symlink; stop and review locally.')
                directories.append(str(path.relative_to(root)))
            for name in names:
                path = parent / name
                release.require(not path.is_symlink() and path.is_file(), 'Project contains a symlink or special file; stop and review locally.')
                before = path.stat(); digest = file_hash(path); after = path.stat()
                release.require((before.st_ino, before.st_size, before.st_mtime_ns) == (after.st_ino, after.st_size, after.st_mtime_ns), 'Project changed during capture; wait for Saved and retry to a new receipt.')
                files[str(path.relative_to(root))] = {'bytes': after.st_size, 'sha256': digest}
        result[str(root)] = {'files': files, 'directories': sorted(directories)}
    return result


def snapshot(app, projects, team, public_key, expected_build, channel):
    info, build = release.verify_app(app, team, public_key)
    release.require(build == expected_build and info['ScrivUpdateChannel'] == channel, 'The installed app does not match the expected acceptance build/channel.')
    inspector = Path(__file__).resolve().parents[2] / 'scripts/inspect-running-scriv.swift'
    running = json.loads(release.run(['/usr/bin/xcrun', 'swift', inspector, app]))
    return {'schema': 1, 'kind': 'installed-app-and-project-snapshot', 'app': str(app.resolve()),
            'bundleID': info['CFBundleIdentifier'], 'teamID': team, 'publicKey': public_key,
            'channel': channel, 'build': build, 'version': info['CFBundleShortVersionString'],
            'executableSHA256': file_hash(app / 'Contents/MacOS/Scriv'),
            'runningProcess': running, 'projects': project_inventory(projects)}


def compare(before, after, from_build, to_build):
    release.require(to_build > from_build and before['build'] == from_build and after['build'] == to_build, 'Expected a genuine increasing A-to-B build transition.')
    for key in ['schema', 'kind', 'app', 'bundleID', 'teamID', 'publicKey', 'channel']:
        release.require(before[key] == after[key], 'Installed identity or channel changed: ' + key)
    release.require(before['executableSHA256'] != after['executableSHA256'], 'Executable did not change.')
    old_process, new_process = before['runningProcess'], after['runningProcess']
    release.require(old_process['pid'] != new_process['pid'] and new_process['launchedAt'] > old_process['capturedAt'], 'A new process relaunch after the baseline was not established.')
    release.require(before['projects'] and before['projects'] == after['projects'], 'Selected unchanged projects differ. Preserve evidence and inspect; do not discard or overwrite anything.')
    return {'identityAndProtectedProjectBytesVerified': True, 'fromBuild': from_build, 'toBuild': to_build,
            'note': 'This comparison does not prove UI consent, app-initiated download provenance or pending-edit semantics. Complete the native checklist.'}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('Update service redirected; no alternate origin is trusted.')


def fetch_exact(url, maximum):
    release.require(url.startswith(release.ORIGIN + '/'), 'Unexpected download origin.')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(urllib.request.Request(url, headers={'User-Agent': 'Scriv-Acceptance/1', 'Accept-Encoding': 'identity'}), timeout=60) as response:
        release.require(response.status == 200 and response.geturl() == url, 'Unexpected update response.')
        data = response.read(maximum + 1)
        release.require(len(data) <= maximum, 'Update response exceeded its bound.')
        return data


def verify_download(manifest, team, public_key, expected_build, channel, output):
    release.require(release.platform.system() == 'Darwin', 'Complete download acceptance requires macOS signature/notarization validation.')
    release.require(manifest['channel'] == channel and manifest['build'] == expected_build, 'Wrong acceptance manifest.')
    release.require(manifest['publicKey'] == public_key and manifest['teamID'] == team and manifest['bundleID'] == release.BUNDLE_ID, 'Release pins differ from the trusted operator inputs.')
    release.require(manifest['feedURL'] == release.channel_url(channel), 'Wrong feed URL.')
    release.require(re.fullmatch(r'releases/[1-9][0-9]{0,14}/[a-f0-9]{64}\.zip', manifest['artifactKey']), 'Unexpected archive key.')
    feed = fetch_exact(manifest['feedURL'], 256 * 1024)
    release.require(release.digest(feed) == manifest['feedSHA256'], 'Live feed differs from retained signed release.')
    release.validate_feed_manifest(feed, manifest)
    archive = fetch_exact(release.ORIGIN + '/' + manifest['artifactKey'], release.MAX_ARCHIVE)
    release.require(len(archive) == manifest['artifactLength'] and release.digest(archive) == manifest['artifactSHA256'], 'Live archive differs from retained signed release.')
    release.verify_signature(archive, manifest['artifactSignature'], public_key)
    release.require(not output.exists(), 'Use a fresh private verification directory.')
    output.mkdir(parents=True, mode=0o700)
    archive_path = output / 'Scriv.zip'; archive_path.write_bytes(archive)
    (output / 'appcast.xml').write_bytes(feed)
    # No extraction before Ed25519 verification. No executable is launched.
    with tempfile.TemporaryDirectory(prefix='verified-app-', dir=output) as tmp:
        release.run(['/usr/bin/ditto', '-x', '-k', archive_path, tmp])
        info, build = release.verify_app(Path(tmp) / 'Scriv.app', team, public_key)
        release.require(build == expected_build and info['CFBundleShortVersionString'] == manifest['version'] and info['ScrivUpdateChannel'] == channel, 'Downloaded signed app identity differs from feed/manifest.')
    return {'verifiedCloudflareDownload': True, 'installed': False, 'channel': channel, 'build': expected_build,
            'feedSHA256': release.digest(feed), 'artifactSHA256': release.digest(archive), 'artifactLength': len(archive)}


def save_private(path, value):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as stream:
        json.dump(value, stream, sort_keys=True, indent=2); stream.write('\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ['snapshot', 'download']:
        p = commands.add_parser(name)
        p.add_argument('--team', required=True); p.add_argument('--public-key', required=True)
        p.add_argument('--build', type=int, required=True); p.add_argument('--channel', required=True)
        p.add_argument('--output', type=Path, required=True)
        if name == 'snapshot':
            p.add_argument('--app', type=Path, required=True)
            p.add_argument('--project', type=Path, action='append', required=True)
        else: p.add_argument('--manifest', type=Path, required=True)
    p = commands.add_parser('compare')
    p.add_argument('--before', type=Path, required=True); p.add_argument('--after', type=Path, required=True)
    p.add_argument('--from-build', type=int, required=True); p.add_argument('--to-build', type=int, required=True)
    args = parser.parse_args()
    if args.command == 'snapshot':
        save_private(args.output, snapshot(args.app, args.project, args.team, args.public_key, args.build, args.channel))
        print('Verified signed installed app and saved private selected-project snapshot. No files were modified.')
    elif args.command == 'download':
        value = verify_download(json.loads(args.manifest.read_text()), args.team, args.public_key, args.build, args.channel, args.output)
        save_private(args.output / 'verification.json', value)
        print('Verified actual Cloudflare feed/archive signatures and notarized app. Nothing was installed or launched.')
    else:
        result = compare(json.loads(args.before.read_text()), json.loads(args.after.read_text()), args.from_build, args.to_build)
        print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    try: main()
    except Exception as error:
        # Avoid echoing user paths, subprocess output, project text or credentials.
        print('BLOCKED: acceptance check failed (' + type(error).__name__ + '). Preserve local evidence and inspect before retrying.')
        raise SystemExit(1)
