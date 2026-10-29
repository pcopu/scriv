#!/usr/bin/env python3
"""Non-authenticated app-server smoke test using a fresh, credential-free home.

Starts only the supplied executable. Tests initialize, account/read and model/list;
never logs in, creates a thread or starts a model turn. Reports no account data,
model names, runtime logs or credentials. The owned process group is always stopped.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def stop_owned(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    if os.name == "posix":
        os.killpg(process.pid, signal.SIGTERM)
    else:
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
        process.wait(timeout=5)


def smoke(executable: str, timeout: float, report: dict) -> None:
    with tempfile.TemporaryDirectory(prefix="scriv-codex-smoke-") as temporary:
        root = Path(temporary)
        home = root / "codex-home"
        home.mkdir()
        # Deliberately do not inherit auth/provider variables or the real home.
        environment = {"HOME": str(root), "CODEX_HOME": str(home), "TMPDIR": str(root),
                       "PATH": os.environ.get("PATH", os.defpath), "LANG": "C.UTF-8"}
        version = subprocess.run([executable, "--version"], env=environment, cwd=root,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout, check=True).stdout.decode().strip()
        if not re.fullmatch(r"codex-cli [0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.+-]*", version):
            raise RuntimeError("The supplied executable did not identify itself as codex-cli.")
        report["runtime"] = version
        process = subprocess.Popen([executable, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, cwd=root, env=environment, start_new_session=os.name == "posix")
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        buffer = b""
        def send(message: dict) -> None:
            process.stdin.write(json.dumps(message).encode() + b"\n")
            process.stdin.flush()
        def reply(identifier: int):
            nonlocal buffer
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if not line.strip():
                        continue
                    value = json.loads(line)
                    if value.get("id") == identifier:
                        if "error" in value:
                            raise RuntimeError(f"Runtime rejected smoke request {identifier}; response details were not recorded.")
                        return value.get("result")
                if selector.select(max(0, deadline - time.monotonic())):
                    data = os.read(process.stdout.fileno(), 65536)
                    if not data:
                        raise RuntimeError("Runtime closed its response pipe before the smoke completed.")
                    buffer += data
                    if len(buffer) > 4 * 1024 * 1024:
                        raise RuntimeError("Runtime response exceeded the 4 MiB smoke-test frame limit.")
            raise TimeoutError(f"Runtime smoke request {identifier} timed out.")
        try:
            send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "scriv_contract_smoke", "title": "Scriv isolated smoke", "version": "1.0.0"}}})
            reply(1)
            report["initialize"] = True
            send({"method": "initialized"})
            send({"id": 2, "method": "account/read", "params": {"refreshToken": False}})
            account = reply(2)
            if not isinstance(account, dict) or "account" not in account or account["account"] is not None:
                raise RuntimeError("Expected a signed-out account in the isolated test home; no account details were recorded.")
            report["signedOutAccountRead"] = True
            send({"id": 3, "method": "model/list", "params": {"limit": 100, "includeHidden": False}})
            models = reply(3)
            if not isinstance(models, dict) or not isinstance(models.get("data"), list):
                raise RuntimeError("Runtime did not return a model catalog array.")
            report["modelList"] = True
            report["modelListCount"] = len(models["data"])
        finally:
            stop_owned(process)
            report["ownedChildStopped"] = process.poll() is not None
            selector.close()
            process.stdin.close()
            process.stdout.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", help="Installed Codex executable (prefer its native binary)")
    parser.add_argument("--report", type=Path, help="Optional JSON evidence destination")
    parser.add_argument("--timeout", type=float, default=20, help="Seconds per request (default 20)")
    args = parser.parse_args()
    report = {"isolatedHome": True, "credentialsProvided": False, "authenticated": False,
              "modelTurnStarted": False, "nativeControllerTested": False, "passed": False}
    try:
        if not 0 < args.timeout <= 120:
            raise ValueError("Request timeout must be greater than zero and at most 120 seconds.")
        executable = shutil.which(args.executable)
        if executable is None:
            raise ValueError("The supplied Codex executable could not be located.")
        smoke(str(Path(executable).resolve()), args.timeout, report)
        report["passed"] = True
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
