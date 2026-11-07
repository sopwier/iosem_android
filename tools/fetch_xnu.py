#!/usr/bin/env python3
"""Download Apple's open-source XNU kernel tree.

XNU is published by Apple under the Apple Public Source License 2.0. This
script fetches the upstream tarball and verifies that it contains the license
file. It does not fetch any iOS firmware, iBoot, kernelcache or userland.

Examples:
    python3 tools/fetch_xnu.py
    python3 tools/fetch_xnu.py --tag xnu-4903.221.2 --out /tmp/xnu.tar.gz
    python3 tools/fetch_xnu.py --list-tags
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tarfile
import urllib.error
import urllib.request

DEFAULT_TAG = "xnu-4903.221.2"
ARCHIVE_URL = "https://github.com/apple-oss-distributions/xnu/archive/refs/tags/{tag}.tar.gz"
TAGS_API = "https://api.github.com/repos/apple-oss-distributions/xnu/tags?per_page=30"
USER_AGENT = "iosem-tools/0.2 (XNU source fetcher)"


def human(size: float) -> str:
    for unit in ("B", "kB", "MB", "GB"):
        if size < 1000 or unit == "GB":
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1000
    return f"{size:.1f} GB"


def list_tags() -> int:
    request = urllib.request.Request(TAGS_API, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        tags = json.load(response)
    for item in tags:
        print(item["name"])
    return 0


def download(url: str, destination: str, expected_sha256: str | None) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    digest = hashlib.sha256()
    received = 0

    with urllib.request.urlopen(request, timeout=60) as response, open(destination, "wb") as output:
        total = int(response.headers.get("Content-Length") or 0)
        while True:
            chunk = response.read(1 << 16)
            if not chunk:
                break
            output.write(chunk)
            digest.update(chunk)
            received += len(chunk)
            if total:
                percent = received * 100 // total
                print(
                    f"\r{percent:3d}%  {human(received)} / {human(total)}",
                    end="",
                    file=sys.stderr,
                    flush=True,
                )
            else:
                print(f"\r{human(received)}", end="", file=sys.stderr, flush=True)

    print(file=sys.stderr)
    actual = digest.hexdigest()

    if expected_sha256 and actual.lower() != expected_sha256.lower():
        raise SystemExit(f"sha256 mismatch: expected {expected_sha256}, got {actual}")

    return actual


def inspect_archive(path: str) -> None:
    with tarfile.open(path, "r:gz") as archive:
        names = archive.getnames()
    if not any(name.endswith("/LICENSE") or name == "LICENSE" for name in names):
        raise SystemExit("archive does not contain a LICENSE file; refusing to trust it")
    roots = {name.split("/", 1)[0] for name in names if "/" in name}
    print(f"archive root: {', '.join(sorted(roots))}")
    print(f"entries: {len(names)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", default=DEFAULT_TAG, help=f"XNU release tag (default: {DEFAULT_TAG})")
    parser.add_argument("--out", help="output path (default: ./<tag>.tar.gz)")
    parser.add_argument("--sha256", help="expected SHA-256 of the archive")
    parser.add_argument("--force", action="store_true", help="overwrite an existing file")
    parser.add_argument("--list-tags", action="store_true", help="print recent upstream tags and exit")
    args = parser.parse_args()

    if args.list_tags:
        return list_tags()

    destination = args.out or f"{args.tag}.tar.gz"
    if os.path.exists(destination) and not args.force:
        print(f"refusing to overwrite {destination} (use --force)", file=sys.stderr)
        return 2

    url = ARCHIVE_URL.format(tag=args.tag)
    print(f"tag:  {args.tag}")
    print(f"url:  {url}")
    print(f"out:  {destination}")

    actual = download(url, destination, args.sha256)
    inspect_archive(destination)

    print(f"sha256: {actual}")
    print()
    print("This is kernel source, not a bootable image.")
    print("It is useful for the n66 block-driver build, which needs matching headers and symbols.")
    print("Building iOS itself still requires Apple's toolchain and a matching kernelcache.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
