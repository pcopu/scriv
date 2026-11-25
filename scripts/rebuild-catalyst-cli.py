#!/usr/bin/env python3
"""Recompile Catalyst Swift with CLT, preserving verified compiled assets and third-party Sparkle.

This is an incremental source rebuild, not a replacement for a clean asset build.
The approved Assets.car, icon and Sparkle framework remain template inputs.
The app, canonical Core, native update adapter and runtime XPC build from source.
Matching Sparkle development headers are required for the native adapter.
"""
import argparse
import hashlib
import json
import os
import re
import stat
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def verify_coverage_source(manifest, digest):
    # Reuse the exact eligible-file-set verifier; never generate an after-the-fact
    # manifest or treat a commit ID as the identity of compiled source.
    subprocess.run(['node', '--input-type=module', '-e',
                    "const {verifySourceManifest} = await import(process.argv[1]); "
                    "await verifySourceManifest(process.argv[2], process.argv[3], process.argv[4]);",
                    (ROOT / 'scripts/export-cli-source-manifest.mjs').as_uri(),
                    str(ROOT), str(manifest), digest], check=True)


def record_directory(path, forbidden):
    """Open an existing, owned destination without following any symlinks."""
    path = Path(os.path.abspath(path))
    if any(path == root or root in path.parents for root in forbidden):
        raise ValueError('Coverage build record must be outside source, template, app and work trees.')
    fd = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in path.parent.parts[1:]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
            info = os.fstat(fd)
            # Root-owned sticky directories (e.g. /tmp) are safe ancestors, but
            # the actual record parent must be private and owned by this user.
            sticky_root = info.st_uid == 0 and bool(info.st_mode & stat.S_ISVTX)
            if info.st_uid not in (0, os.getuid()) or (info.st_mode & 0o022 and not sticky_root):
                raise ValueError('Coverage build record has an unsafe parent directory.')
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise ValueError('Coverage build record parent must be owned by this user and not writable by others.')
        try:
            os.stat(path.name, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            return path, fd
        raise ValueError('Coverage build record must be a new file.')
    except BaseException:
        os.close(fd)
        raise


def write_coverage_record(path, directory_fd, executable, digest, forbidden):
    # Revalidate the pathname and directory identity after the build. Exclusive
    # creation through the retained descriptor cannot overwrite a raced target.
    checked_path, checked_fd = record_directory(path, forbidden)
    try:
        before, after = os.fstat(directory_fd), os.fstat(checked_fd)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise ValueError('Coverage build record parent changed during the build.')
    finally:
        os.close(checked_fd)
    for ancestor in (executable, *executable.parents):
        if ancestor.is_symlink():
            raise ValueError('Coverage executable must not have symlink ancestors.')
    executable_fd = os.open(executable, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(executable_fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError('Coverage executable must be a regular file owned by this user.')
        hasher = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(chunk)
        executable_sha = hasher.hexdigest()
    record = {
        'version': 1,
        'kind': 'scriv-coverage-build',
        'sourceManifestSha256': digest,
        'executableSha256': executable_sha,
        'sourceUnchanged': True,
        'coveragePrefix': '/scriv-source/',
        'counterUpdates': 'atomic',
        'limitations': [
            'Producer-declared integrity, not cryptographic attestation.',
            'Helper/template assets are not instrumented.',
        ],
    }
    fd = os.open(checked_path.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                 0o600, dir_fd=directory_fd)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(record, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        os.unlink(checked_path.name, dir_fd=directory_fd)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--automation', action='store_true', help='Compile the isolated stdio E2E driver; never distribute this build')
    parser.add_argument('--coverage', action='store_true', help='Instrument app/Core for buffer-only LLVM coverage; requires --automation; never distribute')
    parser.add_argument('--coverage-source-manifest', type=Path, help='Externally pinned exact source manifest; required with --coverage')
    parser.add_argument('--coverage-source-manifest-sha256', help='Pre-build SHA-256 of the pinned source manifest; required with --coverage')
    parser.add_argument('--coverage-build-record', type=Path, help='New external build record in an existing owned directory; required with --coverage')
    parser.add_argument('--sparkle-framework', type=Path, required=True,
                        help='Matching signed Sparkle 2.10.1 development framework including Headers')
    parser.add_argument('--template', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--discard-work-after-build', action='store_true',
                        help='Remove a newly created private work directory only after signature, source and coverage-record verification')
    parser.add_argument('--identity', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    args = parser.parse_args()
    if args.coverage and not args.automation:
        parser.error('--coverage requires --automation.')
    coverage_options = (args.coverage_source_manifest, args.coverage_source_manifest_sha256, args.coverage_build_record)
    if any(value is not None for value in coverage_options) and not args.coverage:
        parser.error('Coverage source manifest, digest and build record require --coverage.')
    if args.coverage and not all(coverage_options):
        parser.error('--coverage requires --coverage-source-manifest, --coverage-source-manifest-sha256 and --coverage-build-record together.')
    if args.coverage and not re.fullmatch(r'[a-f0-9]{64}', args.coverage_source_manifest_sha256):
        parser.error('Coverage source manifest SHA-256 must be 64 lowercase hexadecimal characters.')
    template, output, work = args.template.resolve(), args.output.resolve(), args.work.resolve()
    if args.discard_work_after_build:
        if not args.coverage:
            parser.error('--discard-work-after-build requires a verified coverage build record.')
        if work.exists() or Path(os.path.abspath(args.work)) != work:
            parser.error('Discardable work must be a new canonical directory.')
        if work == ROOT or ROOT in work.parents or work in ROOT.parents:
            parser.error('Discardable work must be outside the source tree.')
        parent = work.parent.stat()
        if parent.st_uid != os.getuid() or parent.st_mode & 0o022:
            parser.error('Discardable work needs an existing private parent owned by this user.')
    record_fd = None
    forbidden = (ROOT, template, output, work)
    if args.coverage:
        try:
            record_path, record_fd = record_directory(args.coverage_build_record, forbidden)
        except (OSError, ValueError) as error:
            parser.error(str(error))
    if output.exists() or output == template or template in output.parents or output in template.parents:
        parser.error('Output must be a new, separate app bundle.')
    for bundle in (template, output):
        if work == bundle or work in bundle.parents or bundle in work.parents:
            parser.error('Work must be separate from both template and output bundle trees.')
    if not args.build.isdecimal() or not all(part.isdecimal() for part in args.version.split('.')):
        parser.error('Use numeric version and build identifiers.')
    # The template is copied with symlinks preserved. Reject symlinked resource
    # ancestors before refreshing files, which could otherwise mutate the input.
    for directory in (template / 'Contents', template / 'Contents/Resources'):
        if directory.is_symlink() or not directory.is_dir():
            parser.error('Template Contents and Resources must be real directories.')
    info = plistlib.loads((template / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'app.scriv.uikit':
        parser.error('Template must be the UIKit Mac Catalyst Scriv app.')
    plugin_path = 'Contents/PlugIns/ScrivUpdatePlugin.bundle'
    helper_path = 'Contents/XPCServices/com.scriv.runtime-companion.bootstrap.xpc'
    for relative in [plugin_path + '/Contents/MacOS/ScrivUpdatePlugin', helper_path + '/Contents/MacOS/ScrivRuntimeCompanion']:
        if (template / relative).is_symlink() or not (template / relative).is_file():
            parser.error('Template is missing its native adapter or runtime service.')
    for relative in ['Contents/PlugIns', plugin_path, plugin_path + '/Contents', plugin_path + '/Contents/MacOS']:
        directory = template / relative
        if directory.is_symlink() or not directory.is_dir():
            parser.error('Template native adapter ancestors must be real directories.')
    sparkle_development = args.sparkle_framework.resolve()
    if sparkle_development.name != 'Sparkle.framework':
        parser.error('Sparkle development input must be named Sparkle.framework.')
    retained_sparkle = template / plugin_path / 'Contents/Frameworks/Sparkle.framework'
    for framework in [sparkle_development, retained_sparkle]:
        metadata = plistlib.loads((framework / 'Resources/Info.plist').read_bytes())
        if metadata.get('CFBundleShortVersionString') != '2.10.1':
            parser.error('Both Sparkle inputs must be version 2.10.1.')
        run('codesign', '--verify', '--deep', '--strict', framework)
    if not (sparkle_development / 'Headers/Sparkle.h').is_file():
        parser.error('Sparkle development headers are missing.')
    def framework_uuids(framework):
        value = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(framework / 'Sparkle')], text=True)
        return sorted(re.findall(r'UUID: ([0-9A-F-]+) \(([^)]+)\)', value))
    development_uuids = framework_uuids(sparkle_development)
    if not development_uuids or development_uuids != framework_uuids(retained_sparkle):
        parser.error('Sparkle development and retained framework binary UUIDs differ.')
    run('python3', ROOT / 'scripts/verify-catalyst-icon.py', template)
    run('codesign', '--verify', '--deep', '--strict', template)
    sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip())
    support = sdk / 'System/iOSSupport'
    if not (support / 'System/Library/Frameworks/UIKit.framework').exists():
        parser.error('The selected standalone macOS SDK lacks UIKit/Catalyst support.')
    work.mkdir(parents=True, exist_ok=not args.discard_work_after_build, mode=0o700)
    work_identity = work.stat()
    output.parent.mkdir(parents=True, exist_ok=True)
    # Request independent copy-on-write files, preserving signed framework links
    # and metadata. Copying a whole template for each build must not materialize
    # every unchanged resource on APFS. Failure leaves work available to inspect.
    run('/bin/cp', '-cRp', template, output)
    # Compiled icon assets require the verified template, but runtime resources
    # must match the source being compiled rather than the template's old code.
    for name in ('PeerTransfer', 'SampleImages'):
        destination = output / 'Contents/Resources' / name
        if destination.is_symlink() or destination.is_file():
            destination.unlink()
        elif destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(ROOT / 'apps/mac/Sources/ScrivApp/Resources' / name, destination)
    core = sorted((ROOT / 'apps/mac/Sources/ScrivCore').rglob('*.swift'))
    common = ['xcrun', 'swiftc', '-swift-version', '5', '-sdk', sdk,
              '-module-cache-path', work / 'module-cache', '-O', '-whole-module-optimization']
    catalyst = ['-target', 'arm64-apple-ios17.0-macabi', '-Fsystem', support / 'System/Library/Frameworks',
                '-I', support / 'usr/lib/swift', '-Xclang-linker', '-isysroot', '-Xclang-linker', sdk]
    # Keep helpers uninstrumented. Atomic increments preserve counts when the
    # same app/Core code runs on multiple threads.
    coverage_flags = ['-profile-generate', '-profile-coverage-mapping',
                      '-Xllvm', '-instrprof-atomic-counter-update-all',
                      '-coverage-prefix-map', f'{ROOT}=/scriv-source'] if args.coverage else []
    coverage_inputs = []
    coverage_defines = []
    objc_header = ROOT / 'apps/catalyst/UpdateBridge/ScrivUpdateBridge.h'
    if args.coverage:
        verify_coverage_source(args.coverage_source_manifest, args.coverage_source_manifest_sha256)
        coverage_object = work / 'ScrivCLICoverage.o'
        run('xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
            '-isysroot', sdk, '-target', 'arm64-apple-ios17.0-macabi',
            '-DSCRIV_CLI_AUTOMATION', '-DSCRIV_CLI_COVERAGE', '-c',
            ROOT / 'apps/catalyst/CLIInstrumentation/ScrivCLICoverage.c', '-o', coverage_object)
        coverage_inputs = [coverage_object]
        coverage_defines = ['-D', 'SCRIV_CLI_COVERAGE',
                            '-Xcc', '-DSCRIV_CLI_AUTOMATION', '-Xcc', '-DSCRIV_CLI_COVERAGE']
        objc_header = ROOT / 'apps/catalyst/CLIInstrumentation/ScrivCLICoverageBridge.h'
    run(*common, *catalyst, *coverage_flags, '-parse-as-library', '-emit-library', '-static', '-emit-module',
        '-module-name', 'ScrivCore', '-emit-module-path', work / 'ScrivCore.swiftmodule',
        *core, '-o', work / 'libScrivCore.a')
    shared = [ROOT / f'apps/mac/Sources/ScrivApp/Services/{name}.swift' for name in
              ['WorkspaceStore', 'CloudClient', 'CloudClient+Generation', 'CodexController',
               'CharacterAnalysisController', 'InternetPeerMedia', 'LocalAudioEngine', 'ResourceBundle']]
    shared.append(ROOT / 'apps/mac/Sources/ScrivApp/Views/ProjectHistoryPresentation.swift')
    ui = sorted((ROOT / 'apps/catalyst/ScrivUIKit').rglob('*.swift'))
    bridge = sorted((ROOT / 'apps/catalyst/MacRuntimeBridge').glob('*.swift'))
    run(*common, *catalyst, *coverage_flags, *coverage_defines,
        *(['-D', 'SCRIV_CLI_AUTOMATION'] if args.automation else []), '-module-name', 'ScrivUIKit', '-import-objc-header',
        objc_header, '-I', work, '-L', work, '-lScrivCore', *coverage_inputs,
        *ui, *bridge, *shared, '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
        '-o', output / 'Contents/MacOS/Scriv')
    cli_accessibility = output / 'Contents/PlugIns/ScrivCLIAccessibility.bundle'
    # Never carry the automation adapter into a normal build, even if a test
    # bundle was accidentally supplied as the otherwise validated template.
    if cli_accessibility.is_symlink() or cli_accessibility.is_file():
        cli_accessibility.unlink()
    elif cli_accessibility.exists():
        shutil.rmtree(cli_accessibility)
    if args.automation:
        native = cli_accessibility / 'Contents/MacOS'
        native.mkdir(parents=True)
        (cli_accessibility / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'app.scriv.cli-accessibility',
            'CFBundleExecutable': 'ScrivCLIAccessibility',
            'CFBundlePackageType': 'BNDL',
            'NSPrincipalClass': 'ScrivCLIAccessibilityBridge',
        }))
        run('xcrun', 'clang', '-fobjc-arc', '-isysroot', sdk,
            '-target', 'arm64-apple-macosx14.0', '-bundle', '-framework', 'AppKit',
            ROOT / 'apps/catalyst/AutomationNative/ScrivCLIAccessibility.m',
            '-o', native / 'ScrivCLIAccessibility')
    helper = output / helper_path
    run(*common, '-target', 'arm64-apple-macosx14.0', '-module-name', 'ScrivRuntimeCompanion',
        '-D', 'SCRIV_EMBEDDED_NATIVE_CORE', *core,
        ROOT / 'apps/runtime-bridge/Sources/ScrivRuntimeCompanion/main.swift',
        ROOT / 'apps/runtime-bridge/Sources/ScrivRuntimeCompanion/RuntimeBootstrapXPC.swift',
        '-o', helper / 'Contents/MacOS/ScrivRuntimeCompanion')
    info['CFBundleShortVersionString'], info['CFBundleVersion'] = args.version, args.build
    (output / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    plugin = output / plugin_path
    sparkle = plugin / 'Contents/Frameworks/Sparkle.framework'
    # Match the generated native macOS target, including its embedded canonical
    # Core. Compile Objective-C separately, then link Swift as MH_BUNDLE (not a
    # dylib); only Foundation/Data crosses the Catalyst/native adapter boundary.
    plugin_object = work / 'ScrivSparklePlugin.o'
    run('xcrun', 'clang', '-fobjc-arc', '-fmodules', '-isysroot', sdk,
        '-target', 'arm64-apple-macosx14.0', '-F', sparkle_development.parent,
        '-c', ROOT / 'apps/catalyst/UpdatePlugin/ScrivSparklePlugin.m', '-o', plugin_object)
    run(*common, '-target', 'arm64-apple-macosx14.0', '-module-name', 'ScrivNativeAdapter',
        '-D', 'SCRIV_EMBEDDED_NATIVE_CORE', '-import-objc-header',
        ROOT / 'apps/catalyst/UpdateBridge/ScrivUpdateBridge.h', '-parse-as-library',
        *core, ROOT / 'apps/runtime-bridge/Integration/ScrivRuntimeBootstrapClient.swift',
        ROOT / 'apps/catalyst/RuntimeAdapter/ScrivRuntimeBootstrapAdapter.swift', plugin_object,
        '-F', sparkle.parent, '-framework', 'Sparkle', '-framework', 'AppKit',
        '-framework', 'Security', '-Xlinker', '-bundle',
        '-Xlinker', '-rpath', '-Xlinker', '@loader_path/../Frameworks',
        '-Xlinker', '-rpath', '-Xlinker', '@loader_path/../../../Frameworks',
        '-o', plugin / 'Contents/MacOS/ScrivUpdatePlugin')
    for relative in ['Versions/B/XPCServices/Installer.xpc', 'Versions/B/XPCServices/Downloader.xpc',
                     'Versions/B/Autoupdate', 'Versions/B/Updater.app', '.']:
        component = sparkle / relative
        flags = ['--preserve-metadata=entitlements'] if relative.endswith('Downloader.xpc') else []
        run('codesign', '--force', '--sign', args.identity, '--options', 'runtime', *flags, component)
    for component in [plugin, helper] + ([cli_accessibility] if args.automation else []):
        run('codesign', '--force', '--sign', args.identity, '--options', 'runtime', component)
    entitlements = plistlib.loads((ROOT / 'apps/catalyst/ScrivUIKit.entitlements').read_bytes())
    entitlements['com.apple.security.temporary-exception.mach-lookup.global-name'] = ['app.scriv.uikit-spks', 'app.scriv.uikit-spki']
    entitlements_path = work / 'Scriv.entitlements'
    entitlements_path.write_bytes(plistlib.dumps(entitlements))
    run('codesign', '--force', '--sign', args.identity, '--options', 'runtime', '--entitlements', entitlements_path, output)
    run('codesign', '--verify', '--deep', '--strict', output)
    run('python3', ROOT / 'scripts/verify-catalyst-icon.py', output)
    platform = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(output / 'Contents/MacOS/Scriv')], text=True)
    if 'MACCATALYST' not in platform:
        raise RuntimeError('The app binary must target Mac Catalyst.')
    if args.coverage:
        verify_coverage_source(args.coverage_source_manifest, args.coverage_source_manifest_sha256)
        try:
            write_coverage_record(record_path, record_fd, output / 'Contents/MacOS/Scriv',
                                  args.coverage_source_manifest_sha256, forbidden)
        finally:
            os.close(record_fd)
    if args.discard_work_after_build:
        # All compiler outputs needed for replay are in the verified app. Keep
        # the source manifest and build record outside this owned scratch tree.
        current = work.lstat()
        if work.is_symlink() or work.resolve() != work or (
                current.st_dev, current.st_ino, current.st_uid) != (
                work_identity.st_dev, work_identity.st_ino, os.getuid()):
            raise RuntimeError('Build work changed; retaining it for inspection.')
        shutil.rmtree(work)
        print('Removed verified build scratch; signed app and coverage record retained.')
    print(platform)
    print(f'Built {output}; compiled assets and third-party Sparkle retained; app, Core, native adapter and XPC rebuilt from source.')


if __name__ == '__main__':
    main()
