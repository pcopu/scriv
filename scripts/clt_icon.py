#!/usr/bin/env python3
"""Build and strictly inspect a development-only source-backed ICNS file.

This does not create Assets.car or replace the Xcode/release icon gate.
"""
import argparse
import plistlib
from pathlib import Path
import struct
import subprocess
import tempfile

SOURCES = {
    b"icp4": ("icon_16x16.png", 16),
    b"icp5": ("icon_32x32.png", 32),
    b"icp6": ("icon_32x32@2x.png", 64),
    b"ic07": ("icon_128x128.png", 128),
    b"ic08": ("icon_256x256.png", 256),
    b"ic09": ("icon_512x512.png", 512),
    b"ic10": ("icon_512x512@2x.png", 1024),
    b"ic11": ("icon_16x16@2x.png", 32),
    b"ic12": ("icon_32x32@2x.png", 64),
    b"ic13": ("icon_128x128@2x.png", 256),
    b"ic14": ("icon_256x256@2x.png", 512),
}

def png(source, size):
    if source.is_symlink() or not source.is_file():
        raise ValueError("missing or symlinked icon source: " + str(source))
    data = source.read_bytes()
    if (len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR"
            or struct.unpack(">II", data[16:24]) != (size, size)):
        raise ValueError("invalid icon PNG or dimensions: " + str(source))
    return data

def build(source, output):
    if output.exists() or output.is_symlink():
        raise ValueError("icon output must be new")
    chunks = []
    for kind, (name, size) in SOURCES.items():
        data = png(source / name, size)
        chunks.append(kind + struct.pack(">I", len(data) + 8) + data)
    payload = b"".join(chunks)
    output.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)

def verify(source, icon, info):
    if icon.is_symlink() or not icon.is_file():
        raise ValueError("missing or symlinked development icon")
    if info.get("CFBundleIconFile") != "AppIcon.icns":
        raise ValueError("development bundle icon metadata mismatch")
    data = icon.read_bytes()
    if len(data) < 8 or data[:4] != b"icns" or struct.unpack(">I", data[4:8])[0] != len(data):
        raise ValueError("invalid ICNS header")
    seen, offset = set(), 8
    while offset < len(data):
        if offset + 8 > len(data): raise ValueError("truncated ICNS chunk")
        kind, length = data[offset:offset + 4], struct.unpack(">I", data[offset + 4:offset + 8])[0]
        if kind not in SOURCES or kind in seen or length < 8 or offset + length > len(data):
            raise ValueError("unknown, duplicate or truncated ICNS chunk")
        name, size = SOURCES[kind]
        if data[offset + 8:offset + length] != png(source / name, size):
            raise ValueError("ICNS pixels differ from source: " + name)
        seen.add(kind)
        offset += length
    if seen != set(SOURCES) or offset != len(data):
        raise ValueError("missing ICNS representation")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    icon = args.app / "Contents/Resources/AppIcon.icns"
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    verify(args.source, icon, info)
    # Verify that Apple's decoder accepts the container. This does not prove
    # Finder's display or pixel-exact decoder round-trips at every scale.
    with tempfile.TemporaryDirectory(prefix="scriv-icon-check-") as temp:
        subprocess.run(["/usr/bin/iconutil", "-c", "iconset", "-o",
                        str(Path(temp) / "decoded.iconset"), str(icon)], check=True)
    print("PASS: development ICNS embeds every approved PNG byte-for-byte; iconutil decoded it.")
    print("NOT ESTABLISHED: Assets.car, Xcode icon gate, Finder display or release acceptance.")

if __name__ == "__main__":
    main()
