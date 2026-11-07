#!/usr/bin/env python3
"""Inspect a directory of user-supplied n66 boot artifacts.

This does not extract or download anything. It reports names, sizes, leading
bytes, SHA-256 and whether the five files required by the public
iPhone6splus-n66-s8000 command are present.

Examples:
    python3 tools/verify_artifacts.py host/firmware
    python3 tools/verify_artifacts.py host/firmware --strict
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys

# name, required
ARTIFACTS = [
    ("kernelcache.release.n66.out", True),
    ("DeviceTree.n66ap.im4p.out", True),
    ("aleph_bdev_drv.bin", True),
    ("hfs.main", True),
    ("hfs.sec", True),
    ("048-32651-104.dmg.out", False),
]

MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
}


def classify(path: str) -> str:
    with open(path, "rb") as handle:
        head = handle.read(64)
        size = os.path.getsize(path)
        volume_header = b""
        if size >= 1024 + 2:
            handle.seek(1024)
            volume_header = handle.read(2)
        handle.seek(max(0, size - 1024))
        tail = handle.read()

    if head[:4] == b"IM4P":
        return "IM4P"
    if head[:4] == b"IMG4":
        return "IMG4"
    if head.startswith(b"complzss"):
        return "LZSS kernel"
    if head[:4] in MACHO_MAGICS:
        return "Mach-O"
    if volume_header in (b"H+", b"HX"):
        return "HFS+"
    if b"koly" in tail:
        return "UDIF"
    if head[:1] == b"\x30":
        return "DER/IM4P"
    if head[:4] == b"\x7fELF":
        return "ELF"
    return "flat/unknown"


def sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def human(size: int) -> str:
    value = float(size)
    for unit in ("B", "kB", "MB", "GB"):
        if value < 1000 or unit == "GB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{size} B"
        value /= 1000
    return f"{value:.1f} GB"


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("directory", help="directory containing the artifact files")
    parser.add_argument("--strict", action="store_true", help="exit non-zero if a required file is missing")
    args = parser.parse_args()

    if not os.path.isdir(args.directory):
        print(f"not a directory: {args.directory}", file=sys.stderr)
        return 2

    missing_required = 0
    print(f"directory: {os.path.abspath(args.directory)}")
    print()
    print(f"{'file':32} {'status':8} {'format':13} {'size':>12}  sha256")
    print("-" * 92)

    for name, required in ARTIFACTS:
        path = os.path.join(args.directory, name)
        if not os.path.isfile(path):
            status = "MISSING" if required else "optional"
            if required:
                missing_required += 1
            print(f"{name:32} {status:8} {'-':13} {'-':>12}  -")
            continue

        size = os.path.getsize(path)
        kind = classify(path)
        print(f"{name:32} {'ok':8} {kind:13} {human(size):>12}  {sha256(path)[:16]}…")

    print()
    extras = sorted(
        entry
        for entry in os.listdir(args.directory)
        if os.path.isfile(os.path.join(args.directory, entry))
        and entry not in {name for name, _ in ARTIFACTS}
        and entry not in {"index.json", "manifest.json"}
    )
    if extras:
        print("other files present (ignored):")
        for entry in extras:
            print(f"  {entry}")

    if missing_required:
        print()
        print(f"{missing_required} required file(s) missing.")
        print("host/prepare-artifacts.py can produce the kernel and device tree;")
        print("the driver and HFS+ images remain user-built. See host/DISKS.md.")
        return 1 if args.strict else 0

    print()
    print("All five command-line files are present. This still does not prove the set boots:")
    print("the kernel must be iOS 12.1 16B92, the driver must match its symbols, and the")
    print("disk images must come from the same build.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
