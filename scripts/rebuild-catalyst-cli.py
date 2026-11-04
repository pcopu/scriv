#!/usr/bin/env python3
"""Recompile Catalyst Swift with CLT, preserving a verified bundle's assets/adapter.

This is an incremental source rebuild, not a replacement for a clean asset build.
The existing approved Assets.car, icon, native update adapter and Sparkle bundle
are required inputs. The app, shared Core and runtime XPC are compiled from source.
"""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--template', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--identity', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True)
    args = parser.parse_args()
    template, output, work = args.template.resolve(), args.output.resolve(), args.work.resolve()
    if output.exists() or output == template or template in output.parents or output in template.parents:
        parser.error('Output must be a new, separate app bundle.')
    if not args.build.isdecimal() or not all(part.isdecimal() for part in args.version.split('.')):
        parser.error('Use numeric version and build identifiers.')
    info = plistlib.loads((template / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'app.scriv.uikit':
        parser.error('Template must be the UIKit Mac Catalyst Scriv app.')
    plugin_path = 'Contents/PlugIns/ScrivUpdatePlugin.bundle'
    helper_path = 'Contents/XPCServices/com.scriv.runtime-companion.bootstrap.xpc'
    for relative in [plugin_path + '/Contents/MacOS/ScrivUpdatePlugin', helper_path + '/Contents/MacOS/ScrivRuntimeCompanion']:
        if not (template / relative).is_file():
            parser.error('Template is missing its native adapter or runtime service.')
    run('python3', ROOT / 'scripts/verify-catalyst-icon.py', template)
    run('codesign', '--verify', '--deep', '--strict', template)
    sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip())
    support = sdk / 'System/iOSSupport'
    if not (support / 'System/Library/Frameworks/UIKit.framework').exists():
        parser.error('The selected standalone macOS SDK lacks UIKit/Catalyst support.')
    work.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(template, output, symlinks=True)
    core = sorted((ROOT / 'apps/mac/Sources/ScrivCore').glob('*.swift'))
    common = ['xcrun', 'swiftc', '-swift-version', '5', '-sdk', sdk,
              '-module-cache-path', work / 'module-cache', '-O', '-whole-module-optimization']
    catalyst = ['-target', 'arm64-apple-ios17.0-macabi', '-Fsystem', support / 'System/Library/Frameworks',
                '-I', support / 'usr/lib/swift', '-Xclang-linker', '-isysroot', '-Xclang-linker', sdk]
    run(*common, *catalyst, '-parse-as-library', '-emit-library', '-static', '-emit-module',
        '-module-name', 'ScrivCore', '-emit-module-path', work / 'ScrivCore.swiftmodule',
        *core, '-o', work / 'libScrivCore.a')
    shared = [ROOT / f'apps/mac/Sources/ScrivApp/Services/{name}.swift' for name in
              ['WorkspaceStore', 'CloudClient', 'CloudClient+Generation', 'CodexController',
               'CharacterAnalysisController', 'InternetPeerMedia', 'LocalAudioEngine', 'ResourceBundle']]
    shared.append(ROOT / 'apps/mac/Sources/ScrivApp/Views/ProjectHistoryPresentation.swift')
    ui = sorted((ROOT / 'apps/catalyst/ScrivUIKit').rglob('*.swift'))
    bridge = sorted((ROOT / 'apps/catalyst/MacRuntimeBridge').glob('*.swift'))
    run(*common, *catalyst, '-module-name', 'ScrivUIKit', '-import-objc-header',
        ROOT / 'apps/catalyst/UpdateBridge/ScrivUpdateBridge.h', '-I', work, '-L', work, '-lScrivCore',
        *ui, *bridge, *shared, '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
        '-o', output / 'Contents/MacOS/Scriv')
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
    for relative in ['Versions/B/XPCServices/Installer.xpc', 'Versions/B/XPCServices/Downloader.xpc',
                     'Versions/B/Autoupdate', 'Versions/B/Updater.app', '.']:
        component = sparkle / relative
        flags = ['--preserve-metadata=entitlements'] if relative.endswith('Downloader.xpc') else []
        run('codesign', '--force', '--sign', args.identity, '--options', 'runtime', *flags, component)
    for component in [plugin, helper]:
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
    print(platform)
    print(f'Built {output}; assets and native update adapter retained from the validated template.')


if __name__ == '__main__':
    main()
