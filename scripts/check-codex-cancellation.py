#!/usr/bin/env python3
"""Compile the native controller and exercise cancellation and account refresh.

Optionally set SCRIV_CORE_BUILD_DIR to a directory containing libScrivCore.a and
ScrivCore.swiftmodule built for this Mac. All output and journal data stay in a
temporary directory. Requires macOS, standalone Command Line Tools, and Python 3.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="scriv-codex-cancellation-") as temp:
    work = Path(temp)
    core = Path(os.environ.get("SCRIV_CORE_BUILD_DIR", work))
    if "SCRIV_CORE_BUILD_DIR" not in os.environ:
        sources = sorted((root / "apps/mac/Sources/ScrivCore").glob("*.swift"))
        subprocess.run(["swiftc", "-parse-as-library", "-emit-library", "-static", "-emit-module", "-module-name", "ScrivCore", "-emit-module-path", str(core / "ScrivCore.swiftmodule"), "-o", str(core / "libScrivCore.a"), *map(str, sources)], check=True)
    source = (root / "apps/mac/Sources/ScrivApp/Services/CodexController.swift").read_text()
    # The controller is copied solely to avoid touching the owner's preferences
    # or observing the real desktop sleep notifications in this headless check.
    for snippet in ('UserDefaults.standard.set(executablePath, forKey: "codexExecutable")', 'UserDefaults.standard.set(endpoint, forKey: "codexEndpoint")'):
        if source.count(snippet) != 1: raise SystemExit("Controller setup changed; update the isolated check")
        source = source.replace(snippet, "")
    start_marker = '        #if !targetEnvironment(macCatalyst)\n        sleepObserver = NSWorkspace.shared'
    if source.count(start_marker) != 1: raise SystemExit("Controller sleep observer changed; update the isolated check")
    start = source.index(start_marker)
    end = source.index("        #endif", start) + len("        #endif")
    source = source[:start] + source[end:]
    controller = work / "CodexController.swift"
    controller.write_text(source)
    binary = work / "check"
    subprocess.run(["swiftc", "-parse-as-library", "-I", str(core), str(controller), str(root / "tests/codex-cancellation.selfcheck.swift"), str(core / "libScrivCore.a"), "-o", str(binary)], check=True)
    fake = work / "fake-codex"
    shutil.copyfile(root / "tests/fixtures/fake-codex-cancellation.py", fake)
    fake.chmod(0o700)
    for mode in os.environ.get("SCRIV_FAKE_MODES", "unrelated,missing,own,manual,late,acknowledged").split(","):
        env = {key: value for key, value in os.environ.items() if key in ("PATH", "LANG", "LC_ALL", "TMPDIR")}
        env["HOME"] = str(work)
        env.update(SCRIV_FAKE_MODE=mode, SCRIV_FAKE_EXECUTABLE=str(fake), SCRIV_FAKE_INTERRUPT_LOG=str(work / (mode + ".log")), SCRIV_VERIFICATION_ROOT=str(work / mode))
        subprocess.run([str(binary), "--screenshots"], env=env, check=True, timeout=20)
    account_binary = work / "account-check"
    subprocess.run(["swiftc", "-parse-as-library", "-I", str(core), str(controller), str(root / "tests/codex-account-refresh.selfcheck.swift"), str(core / "libScrivCore.a"), "-o", str(account_binary)], check=True)
    account_fake = work / "fake-account"
    shutil.copyfile(root / "tests/fixtures/fake-codex-account-refresh.py", account_fake)
    account_fake.chmod(0o700)
    for mode in os.environ.get("SCRIV_FAKE_ACCOUNT_MODES", "stale_signed_out,stale_signed_in,stale_failure,latest_failure").split(","):
        env = {key: value for key, value in os.environ.items() if key in ("PATH", "LANG", "LC_ALL", "TMPDIR")}
        env.update(HOME=str(work), SCRIV_FAKE_ACCOUNT_MODE=mode, SCRIV_FAKE_EXECUTABLE=str(account_fake), SCRIV_VERIFICATION_ROOT=str(work / ("account-" + mode)))
        subprocess.run([str(account_binary), "--screenshots"], env=env, check=True, timeout=20)
