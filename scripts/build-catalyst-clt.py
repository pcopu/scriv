#!/usr/bin/env python3
"""Build a local, ad-hoc signed Catalyst development candidate with Apple CLT.

This is not the Xcode archive/release workflow. It does not compile Assets.car,
notarize, install, update, or launch the app. See AGENTS.md for constraints.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import uuid
from clt_icon import build as build_dev_icon

ROOT = Path(__file__).resolve().parent.parent
SCRATCH_MARKER = b"Scriv CLT isolated build root v1\n"

def validate_output(out, scratch_root):
    """Accept only a fresh direct child of the private marked scratch root."""
    out, scratch_root = Path(out), Path(scratch_root)
    if (not out.is_absolute() or not scratch_root.is_absolute() or
            ".." in out.parts or ".." in scratch_root.parts or out.parent != scratch_root):
        raise ValueError("output must be a fresh direct child of the private scratch root")
    try:
        if scratch_root.resolve(strict=True) != scratch_root:
            raise ValueError("scratch root and its ancestors must not be symlinks")
        info = scratch_root.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError("scratch root must be a private 0700 directory owned by this user")
        marker_fd = os.open(scratch_root / ".scriv-clt-root", os.O_RDONLY | os.O_NOFOLLOW)
        try:
            marker_stat = os.fstat(marker_fd)
            if (not stat.S_ISREG(marker_stat.st_mode) or marker_stat.st_uid != os.getuid() or
                    os.read(marker_fd, len(SCRATCH_MARKER) + 1) != SCRATCH_MARKER):
                raise ValueError("scratch root marker is invalid")
        finally:
            os.close(marker_fd)
        try:
            out.lstat()
        except FileNotFoundError:
            return out
        raise ValueError("output already exists")
    except OSError as error:
        raise ValueError("scratch root or marker cannot be safely inspected") from error

class OutputLease:
    """Bind initial validation and creation to one open scratch-root inode."""
    def __init__(self, out, scratch_root):
        self.out, self.root = Path(out), Path(scratch_root)
        self.fd = None
        try:
            self.fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            self.check()
        except Exception:
            self.close()
            raise

    def check(self):
        validate_output(self.out, self.root)
        opened, current = os.fstat(self.fd), self.root.lstat()
        if (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino):
            raise ValueError("scratch root changed since validation")
        marker = os.open('.scriv-clt-root', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self.fd)
        try:
            info = os.fstat(marker)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                    os.read(marker, len(SCRATCH_MARKER) + 1) != SCRATCH_MARKER):
                raise ValueError("scratch root marker changed since validation")
        finally:
            os.close(marker)

    def create(self):
        self.check()
        os.mkdir(self.out.name, 0o700, dir_fd=self.fd)

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def __enter__(self): return self
    def __exit__(self, *args): self.close()

def acquire_output(out, scratch_root):
    # Reject protected paths before even opening the scratch root.
    if not Path(out).is_absolute() or Path(out).parent != Path(scratch_root) or '..' in Path(out).parts:
        raise ValueError("output must be a fresh direct child of the private scratch root")
    return OutputLease(out, scratch_root)

def create_output(out, scratch_root):
    with acquire_output(out, scratch_root) as lease:
        lease.create()

def validate_development_identity(identity):
    if not re.fullmatch(r"app\.scriv\.cltfixture\.[a-z0-9]+", identity):
        raise ValueError("invalid isolated development identity")
    return identity

def development_info(info, identity):
    info = dict(info)
    info["CFBundleIdentifier"] = validate_development_identity(identity)
    info["CFBundleDisplayName"] = "Scriv CLT Fixture"
    for key in ("CFBundleURLTypes", "CFBundleDocumentTypes", "UTExportedTypeDeclarations", "LSApplicationQueriesSchemes"):
        info.pop(key, None)
    info["SUEnableAutomaticChecks"] = False
    return info

def development_entitlements(entitlements, identity):
    validate_development_identity(identity)
    entitlements = dict(entitlements)
    if entitlements.get("com.apple.security.app-sandbox") is not True:
        raise ValueError("development fixture requires the app sandbox")
    entitlements["com.apple.security.temporary-exception.mach-lookup.global-name"] = [identity + "-spks", identity + "-spki"]
    return entitlements

def icon_verifier(mode):
    if mode == "release": return "verify-catalyst-icon.py"
    if mode == "development-icns": return "clt_icon.py"
    raise ValueError("unknown icon verification mode")

def development_main(identity):
    validate_development_identity(identity)
    return '''import Foundation
import UIKit
import Darwin
// Fail closed before UIKit or any workspace service initializes.
let fixtureID = "''' + identity + '''"
let fixtureHome = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
guard CommandLine.arguments.contains("--screenshots"),
      Bundle.main.bundleIdentifier == fixtureID,
      fixtureHome.hasSuffix("/Library/Containers/" + fixtureID + "/Data") else {
    fputs("CLT fixture requires its unique sandbox and --screenshots\\n", stderr)
    exit(78)
}
let fixtureRoot = URL(fileURLWithPath: fixtureHome).appendingPathComponent("tmp/ScrivCLTFixture-" + UUID().uuidString).path
setenv("SCRIV_VERIFICATION_ROOT", fixtureRoot, 1)
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, NSStringFromClass(ScrivUIKitApplication.self), NSStringFromClass(ScrivUIKitAppDelegate.self))
'''

def run(*args, env=None):
    print("+", " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True, env=env)

def output(*args):
    return subprocess.check_output(list(map(str, args)), text=True).strip()

def copy_dir(src, dst):
    run("/usr/bin/ditto", src, dst)

def write_plist(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(data, sort_keys=False))

def framework_tree_sha256(root):
    """Hash paths, types, modes, symlink targets and bytes without following links."""
    entries = []
    for parent, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(parent) / name
            rel = path.relative_to(root).as_posix()
            mode = stat.S_IMODE(path.lstat().st_mode)
            if path.is_symlink():
                target = path.resolve(strict=True)
                if target != root and root not in target.parents:
                    raise RuntimeError("framework symlink escapes its root: " + rel)
                value = "link\0" + os.readlink(path)
            elif path.is_file():
                value = "file\0" + hashlib.sha256(path.read_bytes()).hexdigest()
            elif path.is_dir():
                value = "dir"
            else:
                raise RuntimeError("unsupported framework entry: " + rel)
            entries.append((rel, mode, value))
    h = hashlib.sha256()
    for rel, mode, value in sorted(entries):
        h.update((rel + "\0" + oct(mode) + "\0" + value + "\n").encode())
    return h.hexdigest()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output", required=True, type=Path,
                   help="fresh direct child of /private/tmp/scriv-clt-builds-<uid>")
    p.add_argument("--sparkle-framework", required=True, type=Path,
                   help="existing, verified Sparkle 2.10.1 framework")
    p.add_argument("--sparkle-tree-sha256", required=True,
                   help="independently verified framework-tree fingerprint")
    p.add_argument("--preflight-only", action="store_true",
                   help="validate inputs and space without creating output")
    p.add_argument("--development-icns", action="store_true",
                   help="explicitly build a source-backed development ICNS (not Assets.car)")
    args = p.parse_args()
    if not args.development_icns:
        p.error("select --development-icns for this development-only route")
    if sys.platform != "darwin":
        p.error("Apple Command Line Tools on macOS are required")
    out = args.output
    scratch_root = Path("/private/tmp") / ("scriv-clt-builds-" + str(os.getuid()))
    try:
        lease = acquire_output(out, scratch_root)
    except (OSError, ValueError) as error:
        p.error(str(error))
    with lease:
        if shutil.disk_usage(out.parent).free < 2_684_354_560:
            p.error("at least 2.5 GiB of free space is required before building")
        sparkle = args.sparkle_framework.resolve(strict=True)
        if sparkle.name != "Sparkle.framework" or not sparkle.is_dir():
            p.error("--sparkle-framework must name a framework directory")
        if not re.fullmatch(r"[0-9a-f]{64}", args.sparkle_tree_sha256):
            p.error("--sparkle-tree-sha256 must be 64 lowercase hexadecimal characters")
        version = plistlib.loads((sparkle / "Resources/Info.plist").read_bytes())
        if version.get("CFBundleShortVersionString") != "2.10.1":
            p.error("the existing framework must be Sparkle 2.10.1")
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", sparkle)
        actual_tree = framework_tree_sha256(sparkle)
        if actual_tree != args.sparkle_tree_sha256:
            p.error("Sparkle framework tree differs from the supplied verified fingerprint")
        print("Sparkle framework tree SHA-256:", actual_tree, flush=True)
        sdk = output("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path")
        swift = output("/usr/bin/xcrun", "--find", "swiftc")
        clang = output("/usr/bin/xcrun", "--find", "clang")
        arch = output("/usr/bin/uname", "-m")
        if arch not in ("arm64", "x86_64"):
            p.error("unsupported host architecture")
        ios = Path(sdk) / "System/iOSSupport"
        if not (ios / "System/Library/Frameworks/UIKit.framework").exists():
            p.error("SDK lacks Catalyst UIKit")
        assets = ROOT / "apps/catalyst/ScrivUIKit/Assets.xcassets"
        if sorted(x.name for x in assets.iterdir()) != ["AppIcon.appiconset", "Contents.json"]:
            p.error("unhandled asset catalog entries; CLT cannot compile Assets.car")
        icons = assets / "AppIcon.appiconset"
        icon_meta = json.loads((icons / "Contents.json").read_text())
        expected = {f"icon_{size}x{size}{scale}.png"
                    for size in (16, 32, 128, 256, 512) for scale in ("", "@2x")}
        expected_entries = [
            {"filename": f"icon_{size}x{size}{suffix}.png", "idiom": "mac",
             "scale": scale, "size": f"{size}x{size}"}
            for size in (16, 32, 128, 256, 512)
            for suffix, scale in (("", "1x"), ("@2x", "2x"))
        ]
        expected_entries.append({"filename": "icon_512x512@2x.png", "idiom": "universal",
                                 "platform": "ios", "size": "1024x1024"})
        canonical = lambda entries: sorted(json.dumps(x, sort_keys=True) for x in entries)
        if (canonical(icon_meta.get("images", [])) != canonical(expected_entries)
                or {x.name for x in icons.iterdir()} != expected | {"Contents.json"}):
            p.error("unhandled app icon entries; do not silently omit catalog content")
        if args.preflight_only:
            print("Preflight passed; no output directory was created.")
            return
        lease.create()
        build = out / "build"
        build.mkdir()
        identity = validate_development_identity("app.scriv.cltfixture.a" + uuid.uuid4().hex)
        print("Isolated development bundle ID:", identity, flush=True)
        app = out / "Scriv.app/Contents"
        macos, resources = app / "MacOS", app / "Resources"
        macos.mkdir(parents=True)
        resources.mkdir()
        core = sorted((ROOT / "apps/mac/Sources/ScrivCore").rglob("*.swift"))
        ui = sorted((ROOT / "apps/catalyst/ScrivUIKit").rglob("*.swift"))
        ui.remove(ROOT / "apps/catalyst/ScrivUIKit/App/main.swift")
        fixture_main = build / "main.swift"
        fixture_main.write_text(development_main(identity))
        ui.append(fixture_main)
        bridge = sorted((ROOT / "apps/catalyst/MacRuntimeBridge").rglob("*.swift"))
        services = ROOT / "apps/mac/Sources/ScrivApp"
        legacy = [services / ("Services/" + n + ".swift") for n in (
            "WorkspaceStore", "CloudClient", "CloudClient+Generation", "CodexController",
            "CharacterAnalysisController", "InternetPeerMedia", "LocalAudioEngine", "ResourceBundle")]
        legacy.append(services / "Views/ProjectHistoryPresentation.swift")
        header = ROOT / "apps/catalyst/UpdateBridge/ScrivUpdateBridge.h"
        native = ["-target", arch + "-apple-macos14.0", "-sdk", sdk, "-swift-version", "5"]
        catalyst = ["-target", arch + "-apple-ios17.0-macabi", "-sdk", sdk, "-swift-version", "5",
                    "-Fsystem", ios / "System/Library/Frameworks", "-I", ios / "usr/lib/swift",
                    "-Xclang-linker", "-isysroot", "-Xclang-linker", sdk]
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(build / "clang-cache"),
                   SWIFTPM_MODULECACHE_OVERRIDE=str(build / "swift-cache"))
        if not core or not ui:
            raise RuntimeError("missing canonical Swift sources")
        # Emit both module and object: UIKit links the same ScrivCore source.
        run(swift, *catalyst, "-parse-as-library", "-whole-module-optimization",
            "-module-name", "ScrivCore", "-emit-module", "-emit-module-path", build / "ScrivCore.swiftmodule",
            "-emit-object", "-o", build / "ScrivCore.o", *core, env=env)
        run(swift, *catalyst, "-module-name", "ScrivUIKit", "-I", build,
            "-import-objc-header", header, "-o", macos / "Scriv",
            *ui, *bridge, *legacy, build / "ScrivCore.o", env=env)
        # Native Swift adapter is a separately linked nested dylib; the ObjC plugin
        # uses the same Foundation-only bridge and never exposes Swift model types.
        plugin = app / "PlugIns/ScrivUpdatePlugin.bundle/Contents"
        (plugin / "MacOS").mkdir(parents=True)
        (plugin / "Frameworks").mkdir()
        adapter = plugin / "Frameworks/libScrivNativeAdapter.dylib"
        run(swift, *native, "-parse-as-library", "-emit-library", "-module-name", "ScrivNativeAdapter",
            "-D", "SCRIV_EMBEDDED_NATIVE_CORE", "-import-objc-header", header,
            "-Xlinker", "-install_name", "-Xlinker", "@rpath/libScrivNativeAdapter.dylib",
            "-o", adapter, *core,
            ROOT / "apps/runtime-bridge/Integration/ScrivRuntimeBootstrapClient.swift",
            ROOT / "apps/catalyst/RuntimeAdapter/ScrivRuntimeBootstrapAdapter.swift", env=env)
        copy_dir(sparkle, plugin / "Frameworks/Sparkle.framework")
        copied_sparkle = plugin / "Frameworks/Sparkle.framework"
        if framework_tree_sha256(copied_sparkle.resolve()) != args.sparkle_tree_sha256:
            raise RuntimeError("copied Sparkle framework does not match the verified input")
        run(clang, "-target", arch + "-apple-macos14.0", "-isysroot", sdk, "-fobjc-arc",
            "-fmodules", "-bundle", "-F", plugin / "Frameworks", "-framework", "Sparkle",
            "-framework", "Foundation", "-L", plugin / "Frameworks", "-lScrivNativeAdapter",
            "-Wl,-rpath,@loader_path/../Frameworks", "-o", plugin / "MacOS/ScrivUpdatePlugin",
            ROOT / "apps/catalyst/UpdatePlugin/ScrivSparklePlugin.m", env=env)
        plugin_info = plistlib.loads((ROOT / "apps/catalyst/UpdatePlugin/Info.plist").read_bytes())
        plugin_info["CFBundleExecutable"] = "ScrivUpdatePlugin"
        write_plist(plugin / "Info.plist", plugin_info)
        xpc = app / "XPCServices/com.scriv.runtime-companion.bootstrap.xpc/Contents"
        (xpc / "MacOS").mkdir(parents=True)
        runtime = ROOT / "apps/runtime-bridge/Sources/ScrivRuntimeCompanion"
        run(swift, *native, "-module-name", "ScrivRuntimeCompanion",
            "-D", "SCRIV_EMBEDDED_NATIVE_CORE", "-o", xpc / "MacOS/ScrivRuntimeCompanion",
            *core, runtime / "main.swift", runtime / "RuntimeBootstrapXPC.swift", env=env)
        shutil.copy2(ROOT / "apps/runtime-bridge/Bootstrap-Info.plist", xpc / "Info.plist")
        for name in ("PeerTransfer", "SampleImages"):
            copy_dir(services / "Resources" / name, resources / name)
        build_dev_icon(icons, resources / "AppIcon.icns")
        info = plistlib.loads((ROOT / "apps/catalyst/Info.plist").read_bytes())
        replacements = {"$(DEVELOPMENT_LANGUAGE)": "en", "$(EXECUTABLE_NAME)": "Scriv",
                        "$(PRODUCT_BUNDLE_IDENTIFIER)": "app.scriv.uikit",
                        "$(MARKETING_VERSION)": "1.0", "$(CURRENT_PROJECT_VERSION)": "1",
                        "$(PRODUCT_MODULE_NAME)": "ScrivUIKit",
                        "$(SCRIV_UPDATE_FEED_URL)": "https://scriv-updates.why-not.work/appcast.xml",
                        "$(SCRIV_UPDATE_CHANNEL)": "stable", "$(SCRIV_UPDATE_PUBLIC_KEY)": "",
                        "$(DEVELOPMENT_TEAM)": ""}
        def expand(v):
            if isinstance(v, str):
                for a, b in replacements.items():
                    v = v.replace(a, b)
                if "$(" in v:
                    raise RuntimeError("unresolved build variable in Info.plist")
                return v
            if isinstance(v, list): return [expand(x) for x in v]
            if isinstance(v, dict): return {k: expand(x) for k, x in v.items()}
            return v
        info = development_info(expand(info), identity)
        info["CFBundleIconFile"] = "AppIcon.icns"
        write_plist(app / "Info.plist", info)
        run(sys.executable, ROOT / "scripts" / icon_verifier("development-icns"), app.parent, icons)
        ent = development_entitlements(plistlib.loads((ROOT / "apps/catalyst/ScrivUIKit.entitlements").read_bytes()), identity)
        ent_path = build / "Scriv-development.entitlements"
        write_plist(ent_path, ent)
        framework = plugin / "Frameworks/Sparkle.framework"
        for component in (framework / "Versions/B/XPCServices/Installer.xpc",
                          framework / "Versions/B/XPCServices/Downloader.xpc",
                          framework / "Versions/B/Autoupdate", framework / "Versions/B/Updater.app",
                          framework):
            cmd = ["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime"]
            if component.name == "Downloader.xpc": cmd += ["--preserve-metadata=entitlements"]
            run(*cmd, component)
        for component in (adapter, plugin.parent, xpc.parent):
            run("/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", component)
        run("/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime",
            "--entitlements", ent_path, app.parent)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", app.parent)
        run("/usr/bin/plutil", "-lint", app / "Info.plist")
        # This command has no release mode. The separate Xcode release workflow
        # continues to require verify-catalyst-icon.py and its Assets.car check.
        print("DEVELOPMENT BUNDLE BUILT", app.parent)
        print("Release icon gate NOT RUN: Assets.car, notarization and signed update acceptance remain required.")

if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.CalledProcessError, RuntimeError, ValueError) as error:
        print("BUILD FAILED:", error, file=sys.stderr)
        sys.exit(1)
