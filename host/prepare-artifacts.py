#!/usr/bin/env python3
"""Prepare user-supplied iOS 12.1 (16B92, n66) files for the n66 QEMU machine.

This tool only transforms files that the user already owns:

  * kernelcache.release.n66 (IM4P/DER, LZSS-compressed Mach-O)
  * DeviceTree.n66ap.im4p   (IM4P/DER)
  * 048-32651-104.dmg       (IM4P/DER ramdisk, optional here)

It never downloads Apple firmware, decrypts anything, or touches a signing
check.  The resulting files are ordinary decoded data in a local directory.

The n66 machine also needs two things this script cannot create from an IPSW:

  * aleph_bdev_drv.bin   -- built from xnu-qemu-arm64-tools and matching kernel
                            symbols; see host/README.md
  * hfs.main / hfs.sec   -- HFS+ disk images prepared with the Aleph wiki's
                            macOS hdiutil/rsync/launchd procedure

Use --ipsw to pull only the three files above out of an IPSW zip, or --input
DIR when you have already extracted them.  The output directory defaults to
host/firmware.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import shutil
import struct
import sys
import tempfile
import zipfile
from pathlib import Path

KERNEL_OUT = "kernelcache.release.n66.out"
DEVICE_TREE_OUT = "DeviceTree.n66ap.im4p.out"
RAMDISK_OUT = "048-32651-104.dmg.out"
DRIVER_NAME = "aleph_bdev_drv.bin"
MAIN_DISK_NAME = "hfs.main"
SECONDARY_DISK_NAME = "hfs.sec"

LZSS_N = 4096
LZSS_F = 18
LZSS_THRESHOLD = 2
MAX_DECOMPRESSED = 2 * 1024 * 1024 * 1024

MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",  # MH_MAGIC, big endian
    b"\xce\xfa\xed\xfe",  # MH_CIGAM
    b"\xfe\xed\xfa\xcf",  # MH_MAGIC_64
    b"\xcf\xfa\xed\xfe",  # MH_CIGAM_64
    b"\xca\xfe\xba\xbe",  # FAT_MAGIC
    b"\xbe\xba\xfe\xca",  # FAT_CIGAM
}


class PrepareError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_der_tlv(data: bytes, offset: int) -> tuple[int, bytes, int]:
    """Return (tag, value, next_offset) for one DER TLV."""
    if offset >= len(data):
        raise PrepareError("truncated DER element")
    tag = data[offset]
    offset += 1
    if offset >= len(data):
        raise PrepareError("truncated DER length")
    first = data[offset]
    offset += 1
    if first & 0x80:
        count = first & 0x7F
        if count == 0 or count > 4:
            raise PrepareError("unsupported DER length encoding")
        if offset + count > len(data):
            raise PrepareError("truncated DER long length")
        length = int.from_bytes(data[offset : offset + count], "big")
        offset += count
    else:
        length = first
    end = offset + length
    if end > len(data):
        raise PrepareError("DER element extends past end of file")
    return tag, data[offset:end], end


def im4p_payload(path: Path, expected_subtype: str) -> bytes:
    """Extract the fourth element (payload) from an Apple IM4P DER object."""
    data = path.read_bytes()
    tag, sequence, _ = read_der_tlv(data, 0)
    if tag != 0x30:
        raise PrepareError(f"{path.name}: not a DER SEQUENCE (tag 0x{tag:02x})")

    fields: list[tuple[int, bytes]] = []
    offset = 0
    while offset < len(sequence):
        field_tag, value, offset = read_der_tlv(sequence, offset)
        fields.append((field_tag, value))

    if len(fields) < 4:
        raise PrepareError(f"{path.name}: IM4P has only {len(fields)} fields")

    def text(index: int) -> str:
        try:
            return fields[index][1].decode("ascii", "strict")
        except UnicodeDecodeError as exc:
            raise PrepareError(f"{path.name}: field {index} is not ASCII") from exc

    if text(0) != "IM4P":
        raise PrepareError(f"{path.name}: magic is {text(0)!r}, expected 'IM4P'")
    if text(1) != expected_subtype:
        raise PrepareError(
            f"{path.name}: subtype is {text(1)!r}, expected {expected_subtype!r}"
        )

    payload_tag, payload = fields[3]
    if payload_tag & 0x1F != 0x04:
        raise PrepareError(
            f"{path.name}: payload tag 0x{payload_tag:02x} is not an OCTET STRING"
        )
    if not payload:
        raise PrepareError(f"{path.name}: IM4P payload is empty")
    return payload


def lzss_decompress(data: bytes) -> bytes:
    """Port of Apple's LZSS decompressor used by the kernelcache."""
    if not data.startswith(b"complzss"):
        raise PrepareError("LZSS: missing 'complzss' magic")
    if len(data) < 0x180:
        raise PrepareError("LZSS: truncated 0x180-byte header")

    decompressed_size = struct.unpack(">L", data[12:16])[0]
    compressed_size = struct.unpack(">L", data[16:20])[0]
    if decompressed_size == 0 or decompressed_size > MAX_DECOMPRESSED:
        raise PrepareError(f"LZSS: unreasonable output size {decompressed_size}")
    if compressed_size == 0 or 0x180 + compressed_size > len(data):
        raise PrepareError(
            f"LZSS: compressed size {compressed_size} does not fit in {len(data)} bytes"
        )

    src = data[0x180 : 0x180 + compressed_size]
    text = bytearray(b" " * (LZSS_N + LZSS_F - 1))
    out = bytearray(decompressed_size)
    src_index = 0
    dst_index = 0
    r = LZSS_N - LZSS_F
    flags = 0

    while True:
        flags >>= 1
        if flags & 0x100 == 0:
            if src_index >= compressed_size:
                break
            flags = src[src_index] | 0xFF00
            src_index += 1

        if flags & 1:
            if src_index >= compressed_size:
                break
            byte = src[src_index]
            src_index += 1
            if dst_index >= decompressed_size:
                raise PrepareError("LZSS: output buffer overrun (literal)")
            out[dst_index] = byte
            dst_index += 1
            text[r] = byte
            r = (r + 1) & (LZSS_N - 1)
        else:
            if src_index + 1 >= compressed_size:
                break
            i = src[src_index]
            src_index += 1
            j = src[src_index]
            src_index += 1
            i |= (j & 0xF0) << 4
            count = (j & 0x0F) + LZSS_THRESHOLD
            for k in range(count + 1):
                byte = text[(i + k) & (LZSS_N - 1)]
                if dst_index >= decompressed_size:
                    raise PrepareError("LZSS: output buffer overrun (match)")
                out[dst_index] = byte
                dst_index += 1
                text[r] = byte
                r = (r + 1) & (LZSS_N - 1)

    if dst_index != decompressed_size:
        raise PrepareError(
            f"LZSS: produced {dst_index} bytes, header promised {decompressed_size}"
        )
    return bytes(out)


def looks_like_macho(data: bytes) -> bool:
    return data[:4] in MACHO_MAGICS


def kernel_payload(path: Path) -> bytes:
    """Accept a raw Mach-O, a complzss blob, or an IM4P kernel."""
    head = path.read_bytes()[:4]
    if head in MACHO_MAGICS:
        return path.read_bytes()
    data = path.read_bytes()
    if data.startswith(b"complzss"):
        return lzss_decompress(data)
    if head[:1] == b"\x30":
        decoded = im4p_payload(path, "krnl")
        if decoded.startswith(b"complzss"):
            return lzss_decompress(decoded)
        if looks_like_macho(decoded):
            return decoded
        raise PrepareError(
            f"{path.name}: decoded kernel is neither complzss nor Mach-O"
        )
    raise PrepareError(
        f"{path.name}: expected a raw Mach-O, complzss kernel, or IM4P kernel"
    )


def device_tree_payload(path: Path) -> bytes:
    data = path.read_bytes()
    if data[:1] == b"\x30":
        return im4p_payload(path, "dtre")
    return data


def ramdisk_payload(path: Path) -> bytes:
    data = path.read_bytes()
    if data[:1] == b"\x30":
        return im4p_payload(path, "rdsk")
    return data


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(data)
    os.replace(temporary, path)


def copy_atomic(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".tmp")
    shutil.copyfile(source, temporary)
    os.replace(temporary, destination)


def find_one(root: Path, candidates: list[str], predicate) -> Path | None:
    for name in candidates:
        direct = root / name
        if direct.is_file():
            return direct
    matches = sorted(path for path in root.rglob("*") if path.is_file() and predicate(path.name))
    return matches[0] if matches else None


def extract_ipsw(ipsw: Path, staging: Path) -> dict[str, Path]:
    """Extract only the three relevant members from a user-supplied IPSW."""
    wanted: dict[str, Path] = {}
    with zipfile.ZipFile(ipsw) as archive:
        names = archive.namelist()

        def pick(label: str, predicate) -> str | None:
            matches = sorted(name for name in names if predicate(name))
            if not matches:
                return None
            member = matches[0]
            destination = staging / Path(member).name
            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as source, destination.open("wb") as target:
                shutil.copyfileobj(source, target, length=1 << 20)
            wanted[label] = destination
            return member

        members = {
            "kernel": pick("kernel", lambda name: name.endswith("kernelcache.release.n66")),
            "device_tree": pick(
                "device tree",
                lambda name: "/DeviceTree.n66ap.im4p" in "/" + name,
            ),
            "ramdisk": pick("ramdisk", lambda name: name.endswith("048-32651-104.dmg")),
        }

    print(f"IPSW: {ipsw}")
    for label, member in members.items():
        print(f"  {label:12} {'found: ' + member if member else 'not found'}")
    return wanted


def build_manifest(out_dir: Path, records: list[dict]) -> None:
    manifest = {
        "generated_at": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        "target": "iPhone 6s Plus (n66, s8000), iOS 12.1 (16B92)",
        "note": (
            "Decoded user-supplied data. Not distributed with iosem. "
            "hfs.main, hfs.sec and aleph_bdev_drv.bin are not derivable by this script."
        ),
        "files": records,
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Decode user-owned iOS 12.1 n66 kernel/device tree/ramdisk files.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--ipsw", type=Path, help="user-supplied iPhone_5.5_12.1_16B92_Restore.ipsw")
    parser.add_argument("--input", type=Path, help="directory containing extracted IPSW files")
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parent / "firmware")
    parser.add_argument("--kernel", type=Path, help="explicit kernelcache.release.n66 path")
    parser.add_argument("--device-tree", type=Path, help="explicit DeviceTree.n66ap.im4p path")
    parser.add_argument("--ramdisk", type=Path, help="explicit 048-32651-104.dmg path")
    parser.add_argument("--driver", type=Path, help="explicit aleph_bdev_drv.bin path")
    parser.add_argument("--main-disk", type=Path, help="explicit prepared hfs.main path")
    parser.add_argument("--secondary-disk", type=Path, help="explicit prepared hfs.sec path")
    parser.add_argument("--force", action="store_true", help="overwrite existing outputs")
    parser.add_argument(
        "--allow-unverified-kernel",
        action="store_true",
        help="do not require the decompressed kernel to look like Mach-O",
    )
    args = parser.parse_args(argv)

    if args.ipsw and args.input:
        parser.error("pass only one of --ipsw FILE or --input DIR")

    out_dir: Path = args.out.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    input_dir = args.input.resolve() if args.input else None
    if input_dir and not input_dir.is_dir():
        parser.error(f"--input is not a directory: {input_dir}")
    if args.ipsw and not args.ipsw.is_file():
        parser.error(f"--ipsw is not a file: {args.ipsw}")

    work_context = tempfile.TemporaryDirectory(prefix="iosem-ipsw-") if args.ipsw else None
    try:
        source_root = Path(work_context.name) if work_context else input_dir
        if args.ipsw:
            available = extract_ipsw(args.ipsw.resolve(), source_root)
        else:
            available = {}

        def choose(explicit: Path | None, candidates: list[str], predicate) -> Path | None:
            if explicit:
                path = explicit.resolve()
                if not path.is_file():
                    raise PrepareError(f"not a file: {path}")
                return path
            if explicit is None and source_root and not args.ipsw:
                return find_one(source_root, candidates, predicate)
            for _, path in available.items():
                if path.name in candidates:
                    return path
            return None

        kernel = choose(
            args.kernel,
            ["kernelcache.release.n66"],
            lambda name: name == "kernelcache.release.n66",
        )
        device_tree = choose(
            args.device_tree,
            ["DeviceTree.n66ap.im4p"],
            lambda name: name.startswith("DeviceTree.n66ap") and name.endswith(".im4p"),
        )
        ramdisk = choose(
            args.ramdisk,
            ["048-32651-104.dmg"],
            lambda name: name == "048-32651-104.dmg",
        )

        if not kernel:
            raise PrepareError(
                "no kernelcache.release.n66 found; pass --kernel or --ipsw/--input"
            )
        if not device_tree:
            raise PrepareError(
                "no DeviceTree.n66ap.im4p found; pass --device-tree or --ipsw/--input"
            )

        records: list[dict] = []

        def emit(label: str, source: Path, destination: Path, data: bytes) -> None:
            if destination.exists() and not args.force:
                raise PrepareError(
                    f"{destination} already exists; pass --force to overwrite"
                )
            write_atomic(destination, data)
            records.append(
                {
                    "kind": label,
                    "source_name": source.name,
                    "fileName": destination.name,
                    "size": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                }
            )
            print(f"  {label:12} -> {destination}  ({len(data):,} bytes)")

        print("Decoding:")
        kernel_data = kernel_payload(kernel)
        if not looks_like_macho(kernel_data) and not args.allow_unverified_kernel:
            raise PrepareError(
                "decompressed kernel does not start with a Mach-O magic; "
                "pass --allow-unverified-kernel only if you know why"
            )
        emit("kernel", kernel, out_dir / KERNEL_OUT, kernel_data)

        emit("device tree", device_tree, out_dir / DEVICE_TREE_OUT, device_tree_payload(device_tree))

        if ramdisk:
            emit("ramdisk", ramdisk, out_dir / RAMDISK_OUT, ramdisk_payload(ramdisk))
        else:
            print("  ramdisk      not found (optional for the custom-disk boot path)")

        # These are not derivable from an IPSW, but copy them when supplied.
        for explicit, destination_name, label in (
            (args.driver, DRIVER_NAME, "driver"),
            (args.main_disk, MAIN_DISK_NAME, "main disk"),
            (args.secondary_disk, SECONDARY_DISK_NAME, "secondary disk"),
        ):
            if explicit is None:
                continue
            source = explicit.resolve()
            if not source.is_file():
                raise PrepareError(f"{label}: not a file: {source}")
            destination = out_dir / destination_name
            if destination.exists() and not args.force:
                raise PrepareError(f"{destination} already exists; pass --force to overwrite")
            copy_atomic(source, destination)
            records.append(
                {
                    "kind": label,
                    "source_name": source.name,
                    "fileName": destination.name,
                    "size": destination.stat().st_size,
                    "sha256": sha256_file(destination),
                }
            )
            print(f"  {label:12} -> {destination}  ({destination.stat().st_size:,} bytes)")

        build_manifest(out_dir, records)
    except (PrepareError, zipfile.BadZipFile, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    finally:
        if work_context:
            work_context.cleanup()

    print()
    print(f"Output: {out_dir}")
    print("Still required for a boot:")
    missing = [
        name
        for name in (DRIVER_NAME, MAIN_DISK_NAME, SECONDARY_DISK_NAME)
        if not (out_dir / name).is_file()
    ]
    if missing:
        for name in missing:
            print(f"  [--] {name}")
        print("  See host/README.md and host/DISKS.md. These cannot be derived from an IPSW")
        print("  by this script: the driver is compiled against kernel symbols, and the")
        print("  disks require the Aleph macOS preparation procedure.")
    else:
        print("  all files needed by the n66 command line are present")
    print()
    print(f"Next: {Path(__file__).resolve().parent / 'boot-n66.sh'} --firmware {out_dir} --dry-run")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
