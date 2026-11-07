#!/usr/bin/env bash
# Offline self-test for the host harness.
#
# Builds synthetic IM4P/LZSS fixtures, runs the decoder, and checks the boot
# script's validation and dry-run path. It never executes QEMU and never reads
# or writes real firmware.

set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HOST_DIR/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/iosem-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SRC="$WORK/src"
OUT="$WORK/out"
mkdir -p "$SRC" "$OUT"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

echo "1/5 generating synthetic IM4P/LZSS fixtures"
python3 - "$SRC" <<'PY'
import struct
import sys
from pathlib import Path

src = Path(sys.argv[1])


def der(tag, body):
    if len(body) < 0x80:
        length = bytes([len(body)])
    elif len(body) < 0x100:
        length = bytes([0x81, len(body)])
    elif len(body) < 0x10000:
        length = bytes([0x82, len(body) >> 8, len(body) & 0xFF])
    else:
        length = bytes([0x83, len(body) >> 16, (len(body) >> 8) & 0xFF, len(body) & 0xFF])
    return bytes([tag]) + length + body


def im4p(subtype, payload):
    body = der(0x16, subtype.encode()) + der(0x16, b"selftest") + der(0x04, payload)
    return der(0x30, der(0x16, b"IM4P") + body)


def lzss_literals(payload):
    stream = bytearray()
    for start in range(0, len(payload), 8):
        chunk = payload[start : start + 8]
        stream.append((1 << len(chunk)) - 1)
        stream.extend(chunk)
    header = bytearray(0x180)
    header[:8] = b"complzss"
    struct.pack_into(">L", header, 12, len(payload))
    struct.pack_into(">L", header, 16, len(stream))
    return bytes(header) + bytes(stream)


macho = b"\xcf\xfa\xed\xfe" + bytes(range(64)) + b"SELFTEST" * 16
(src / "kernelcache.release.n66").write_bytes(im4p("krnl", lzss_literals(macho)))
(src / "DeviceTree.n66ap.im4p").write_bytes(im4p("dtre", b"\x00\x01synthetic-dt" + bytes(64)))
(src / "048-32651-104.dmg").write_bytes(im4p("rdsk", b"synthetic-ramdisk" + bytes(64)))
PY

echo "2/5 decoding with prepare-artifacts.py"
python3 "$HOST_DIR/prepare-artifacts.py" --input "$SRC" --out "$OUT" >/dev/null

# Explicit paths must work without --input/--ipsw.
EXPLICIT="$WORK/explicit"
python3 "$HOST_DIR/prepare-artifacts.py" \
    --kernel "$SRC/kernelcache.release.n66" \
    --device-tree "$SRC/DeviceTree.n66ap.im4p" \
    --out "$EXPLICIT" >/dev/null
[[ -s "$EXPLICIT/kernelcache.release.n66.out" ]] || fail "explicit kernel path was not decoded"

echo "3/5 checking decoded outputs"
[[ -s "$OUT/kernelcache.release.n66.out" ]] || fail "kernel output missing"
[[ -s "$OUT/DeviceTree.n66ap.im4p.out" ]] || fail "device tree output missing"
[[ -s "$OUT/manifest.json" ]] || fail "manifest missing"
python3 - "$OUT/kernelcache.release.n66.out" <<'PY'
import sys
from pathlib import Path

head = Path(sys.argv[1]).read_bytes()[:4]
if head not in {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe"}:
    raise SystemExit(f"decoded kernel is not Mach-O: {head.hex()}")
PY

echo "4/5 checking boot-script validation and dry run"
printf 'driver' > "$OUT/aleph_bdev_drv.bin"
python3 - "$OUT" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
for name in ("hfs.main", "hfs.sec"):
    image = bytearray(4096)
    image[1024:1026] = b"H+"
    (root / name).write_bytes(image)
PY

"$HOST_DIR/boot-n66.sh" --firmware "$OUT" --dry-run > "$WORK/dry-run.txt"
grep -q 'iPhone6splus-n66-s8000' "$WORK/dry-run.txt" || fail "machine name missing from command"
grep -q -- '-serial mon:stdio' "$WORK/dry-run.txt" || fail "serial console missing from command"

if "$HOST_DIR/boot-n66.sh" --firmware "$SRC" --dry-run >/dev/null 2>&1; then
    fail "boot script accepted a directory without the five boot files"
fi

# A file with the right name but the wrong content must be rejected before QEMU
# starts.  Restore the real decoded kernel afterwards.
cp "$OUT/kernelcache.release.n66.out" "$WORK/kernel.bak"
printf 'IM4P-not-a-macho' > "$OUT/kernelcache.release.n66.out"
if "$HOST_DIR/boot-n66.sh" --firmware "$OUT" --dry-run >/dev/null 2>&1; then
    fail "boot script accepted a non-Mach-O kernel"
fi
mv "$WORK/kernel.bak" "$OUT/kernelcache.release.n66.out"

# The HFS+ check must also reject a raw non-HFS image.
printf 'not-hfs' > "$OUT/hfs.main"
if "$HOST_DIR/boot-n66.sh" --firmware "$OUT" --dry-run >/dev/null 2>&1; then
    fail "boot script accepted a disk image without an HFS+ signature"
fi
python3 - "$OUT" <<'PY'
import sys
from pathlib import Path

image = bytearray(4096)
image[1024:1026] = b"H+"
(Path(sys.argv[1]) / "hfs.main").write_bytes(image)
PY

echo "5/5 checking artifact verifier"
python3 "$REPO_ROOT/tools/verify_artifacts.py" "$OUT" > "$WORK/verify.txt" ||
    fail "artifact verifier rejected a complete five-file set"
grep -q 'All five command-line files are present' "$WORK/verify.txt" ||
    fail "artifact verifier did not report a complete set"
if python3 "$REPO_ROOT/tools/verify_artifacts.py" "$SRC" --strict >/dev/null 2>&1; then
    fail "artifact verifier --strict accepted an incomplete set"
fi

echo
echo "PASS: decoder, manifest, boot validation and dry run all behave as expected."
