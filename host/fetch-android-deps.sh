#!/usr/bin/env bash
# Fetch the aarch64 runtime used by the Android QEMU cross-build.
#
# The libraries come from Termux (bionic, aarch64):
#   glib (LGPL-2.1-or-later), pixman (MIT), pcre2 (BSD-3-Clause),
#   libffi (MIT), zlib (zlib), libiconv (LGPL-2.1-or-later),
#   libandroid-support (Apache-2.0), dtc/libfdt (GPL-2.0-or-later / BSD).
#
# Nothing Apple-authored is downloaded. This is only a build-time sysroot;
# the resulting libraries are bundled under their upstream licenses.

set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HOST_DIR/.." && pwd)"
BASE="https://packages-cf.termux.dev/apt/termux-main"
ABI="${IOSEM_ABI:-arm64-v8a}"
case "$ABI" in
    arm64-v8a) ARCH="aarch64" ;;
    x86_64) ARCH="x86_64" ;;
    *) echo "unsupported IOSEM_ABI: $ABI" >&2; exit 1 ;;
esac
DEPS="$REPO_ROOT/android-deps/termux-$ARCH"
ROOT="$DEPS/root"

PACKAGES=(
    "pool/main/g/glib/glib_2.90.1_${ARCH}.deb"
    "pool/main/libp/libpixman/libpixman_0.46.4-1_${ARCH}.deb"
    "pool/main/libf/libffi/libffi_3.8.0_${ARCH}.deb"
    "pool/main/p/pcre2/pcre2_10.49_${ARCH}.deb"
    "pool/main/z/zlib/zlib_1.4_${ARCH}.deb"
    "pool/main/liba/libandroid-support/libandroid-support_29-1_${ARCH}.deb"
    "pool/main/libi/libiconv/libiconv_1.19.1_${ARCH}.deb"
    "pool/main/d/dtc/dtc_1.8.1_${ARCH}.deb"
)

mkdir -p "$DEPS/debs" "$ROOT"

echo "Fetching the Termux package index for checksums ..."
index="$DEPS/Packages.gz"
curl -fL --retry 5 --retry-delay 3 --connect-timeout 30 -o "$index" \
    "$BASE/dists/stable/main/binary-$ARCH/Packages.gz"

for path in "${PACKAGES[@]}"; do
    file="$DEPS/debs/${path##*/}"
    if [[ -s "$file" ]]; then
        echo "have ${path##*/}"
    else
        echo "fetching ${path##*/}"
        curl -fL --retry 5 --retry-delay 3 --connect-timeout 30 -o "$file" "$BASE/$path"
    fi
done

echo "Verifying package checksums against the signed index ..."
python3 - "$index" "${PACKAGES[@]}" <<'PY'
import gzip
import hashlib
import sys
from pathlib import Path

index = Path(sys.argv[1])
wanted = set(Path(p).name for p in sys.argv[2:])
sums = {}
with gzip.open(index, "rt", errors="replace") as stream:
    name = None
    for line in stream:
        if line.startswith("Filename: "):
            name = line.split("/")[-1].strip()
        elif line.startswith("SHA256: ") and name in wanted:
            sums[name] = line.split(":", 1)[1].strip()

status = 0
base = Path(sys.argv[1]).parent / "debs"
for name in wanted:
    path = base / name
    expected = sums.get(name)
    if not expected:
        print(f"  no checksum for {name}")
        status = 1
        continue
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected:
        print(f"  BAD {name}")
        status = 1
    else:
        print(f"  ok  {name}")
raise SystemExit(status)
PY

echo "Extracting ..."
for file in "$DEPS"/debs/*.deb; do
    dpkg-deb -x "$file" "$ROOT"
done

# patchelf is needed to rewrite SONAME/NEEDED for Android's flat .so names.
if ! command -v patchelf >/dev/null 2>&1 && [[ ! -x "$DEPS/patchelf/usr/bin/patchelf" ]]; then
    echo "Fetching patchelf ..."
    (
        cd "$DEPS"
        apt-get download patchelf >/dev/null 2>&1 || true
        for deb in patchelf_*.deb; do
            [[ -f "$deb" ]] || continue
            dpkg-deb -x "$deb" "$DEPS/patchelf"
        done
    )
fi

echo
echo "Runtime ready: $ROOT/data/data/com.termux/files/usr"
echo "patchelf: ${PATCHELF:-$DEPS/patchelf/usr/bin/patchelf}"
echo "Bundle licenses with the APK; see docs/LEGAL.md."
