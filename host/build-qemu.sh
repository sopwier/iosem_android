#!/usr/bin/env bash
# Build the Aleph xnu-qemu-arm64 fork (aarch64-softmmu) on a Linux host.
#
# The fork is pinned to a commit so the n66 machine does not silently change.
# It is GPL-2.0; this script does not redistribute it, it downloads source.
#
# Usage:
#   ./host/build-qemu.sh
#   IOSEM_JOBS=8 ./host/build-qemu.sh
#   XNU_QEMU_DIR=/path/to/existing/source ./host/build-qemu.sh
#
# Network: GitHub directly is often slow.  Set IOSEM_GITHUB_PROXY to a mirror
# prefix (default https://gh-proxy.com/) or to an empty string to use GitHub.

set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HOST_DIR/.." && pwd)"
BUILD_DIR="${IOSEM_BUILD_DIR:-$HOST_DIR/.build}"
DOWNLOADS="$BUILD_DIR/downloads"
DEFAULT_SRC="$BUILD_DIR/xnu-qemu-arm64"
ENV_FILE="$BUILD_DIR/toolchain.env"

SOURCE_COMMIT="2694993f9281a8678d519704c3cd29d4c9d39415"
SOURCE_SHA256="82cff711b4bfe91ba6cdaacfe7825778557281018f7c33613c92b661e82faaa1"
KEYMAP_COMMIT="22b8996dba9041874845c7446ce89ec4ae2b713d"
KEYMAP_SHA256="94f5aa8fff6bbc2a4eb413e2399e094dd86010ca7cdab4b7e56eda35661ba887"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

if [[ -n "${XNU_QEMU_DIR:-}" ]]; then
    SRC_DIR="$XNU_QEMU_DIR"
    MANAGE_SOURCE=0
else
    SRC_DIR="$DEFAULT_SRC"
    MANAGE_SOURCE=1
fi

JOBS="${IOSEM_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

need() {
    command -v "$1" >/dev/null 2>&1 || return 1
}

missing=()
for command in make gcc g++ pkg-config flex bison python3 curl tar; do
    need "$command" || missing+=("$command")
done
for package in glib-2.0 pixman-1 zlib; do
    pkg-config --exists "$package" 2>/dev/null || missing+=("pkg-config:$package")
done
if ! printf '#include <libfdt.h>\nint main(void){return 0;}\n' | "${CC:-cc}" -x c - -o /dev/null >/dev/null 2>&1; then
    missing+=("libfdt headers")
fi

if ((${#missing[@]})); then
    echo "Missing host build dependencies:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    echo >&2
    echo "Debian/Ubuntu with root:" >&2
    echo "  sudo apt install build-essential flex bison libglib2.0-dev libpixman-1-dev zlib1g-dev libfdt-dev" >&2
    echo "No root, Debian/Ubuntu:" >&2
    echo "  ./host/bootstrap-deps.sh" >&2
    echo "  (that helper covers g++, flex, bison and libfdt; glib/pixman/zlib" >&2
    echo "   development files still need package-manager access or manual paths)" >&2
    exit 1
fi

download_github() {
    local url="$1" output="$2" expected_sha="$3"
    local proxy="${IOSEM_GITHUB_PROXY-https://gh-proxy.com/}"
    local tmp="${output}.part"

    if [[ -f "$output" && -n "$expected_sha" ]]; then
        if echo "$expected_sha  $output" | sha256sum --check --status 2>/dev/null; then
            return 0
        fi
    fi

    mkdir -p "$(dirname "$output")"
    rm -f "$tmp"

    if [[ -n "$proxy" ]]; then
        echo "Downloading ${url##*/} via ${proxy%%/} ..."
        if curl -fL --retry 5 --retry-delay 3 --connect-timeout 20 \
            -o "$tmp" "${proxy}${url}"; then
            :
        else
            echo "Mirror failed; trying GitHub directly ..." >&2
            rm -f "$tmp"
        fi
    fi

    if [[ ! -s "$tmp" ]]; then
        echo "Downloading ${url##*/} from GitHub ..."
        curl -fL --retry 5 --retry-delay 3 --connect-timeout 20 -o "$tmp" "$url"
    fi

    if [[ -n "$expected_sha" ]]; then
        echo "$expected_sha  $tmp" | sha256sum --check
    fi
    mv "$tmp" "$output"
}

patch_makefile_keymap() {
    local makefile="$SRC_DIR/Makefile"
    python3 - "$makefile" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = """\t    $(PYTHON) $(KEYCODEMAP_GEN) \\
\t          --lang glib2 \\
\t          --varname qemu_input_map_$${src}_to_$${dst} \\
\t          code-map $(KEYCODEMAP_CSV) $${src} $${dst} \\
\t        > $@ || rm -f $@, \"GEN\", \"$@\")"""
new = """\t    $(PYTHON) $(KEYCODEMAP_GEN) \\
\t          code-map $(KEYCODEMAP_CSV) $${src} $${dst} \\
\t          --lang glib2 \\
\t          --varname qemu_input_map_$${src}_to_$${dst} \\
\t        > $@ || rm -f $@, \"GEN\", \"$@\")"""
if old in text:
    path.write_text(text.replace(old, new, 1))
    print("Patched keymap-gen argument order for current keycodemapdb.")
elif "code-map $(KEYCODEMAP_CSV)" in text:
    print("keymap-gen argument order already patched.")
else:
    raise SystemExit("Could not find the keymap-gen rule in Makefile")
PY
}

filter_keymap_csv() {
    # This QEMU is older than the current keycodemapdb.  The CSV contains
    # qcodes that this tree's QKeyCode enum does not define (F13+, lang1/2,
    # etc.), and glib2 output references them as C identifiers.  Blank the
    # unsupported column values before generating the tables.
    python3 - "$SRC_DIR" <<'PY'
import csv
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
ui_json = (root / "qapi/ui.json").read_text()
match = re.search(r"\{ 'enum': 'QKeyCode',\s*'data': \[(.*?)\] \}", ui_json, re.S)
if not match:
    raise SystemExit("Could not locate the QKeyCode enum in qapi/ui.json")
supported = {name.upper() for name in re.findall(r"'([^']+)'", match.group(1))}

csv_path = root / "ui/keycodemapdb/data/keymaps.csv"
with csv_path.open(newline="") as stream:
    rows = list(csv.reader(stream))
header = rows[0]
try:
    column = header.index("QEMU QKeyCode")
except ValueError:
    raise SystemExit("keymaps.csv has no QEMU QKeyCode column")

changed = 0
for row in rows[1:]:
    if len(row) > column and row[column] and row[column].upper() not in supported:
        row[column] = ""
        changed += 1

with csv_path.open("w", newline="") as stream:
    csv.writer(stream).writerows(rows)
print(f"Filtered {changed} qcodes unsupported by this QEMU tree.")
PY
}

if ((MANAGE_SOURCE)); then
    archive="$DOWNLOADS/xnu-qemu-arm64-$SOURCE_COMMIT.tar.gz"
    if [[ ! -f "$archive" || -n "$SOURCE_SHA256" ]] && ! echo "$SOURCE_SHA256  $archive" | sha256sum --check --status 2>/dev/null; then
        download_github \
            "https://github.com/alephsecurity/xnu-qemu-arm64/archive/$SOURCE_COMMIT.tar.gz" \
            "$archive" "$SOURCE_SHA256"
    fi

    marker="$SRC_DIR/.iosem-source-$SOURCE_COMMIT"
    if [[ ! -f "$marker" ]]; then
        if [[ -d "$SRC_DIR" && -n "$(ls -A "$SRC_DIR" 2>/dev/null || true)" ]]; then
            if [[ "${IOSEM_FORCE_SOURCE:-0}" != "1" ]]; then
                echo "$SRC_DIR exists but is not the pinned checkout." >&2
                echo "Remove it, or set IOSEM_FORCE_SOURCE=1 to replace it." >&2
                exit 1
            fi
            rm -rf "$SRC_DIR"
        fi
        mkdir -p "$SRC_DIR"
        echo "Extracting xnu-qemu-arm64 $SOURCE_COMMIT ..."
        tar -xzf "$archive" -C "$SRC_DIR" --strip-components=1

        keymap_archive="$DOWNLOADS/keycodemapdb-$KEYMAP_COMMIT.tar.gz"
        if [[ ! -s "$keymap_archive" ]] ||
           ! echo "$KEYMAP_SHA256  $keymap_archive" | sha256sum --check --status 2>/dev/null; then
            download_github \
                "https://github.com/qemu/keycodemapdb/archive/$KEYMAP_COMMIT.tar.gz" \
                "$keymap_archive" "$KEYMAP_SHA256"
        fi
        mkdir -p "$SRC_DIR/ui/keycodemapdb"
        tar -xzf "$keymap_archive" -C "$SRC_DIR/ui/keycodemapdb" --strip-components=1
        touch "$SRC_DIR/.git-submodule-status"
        touch "$marker"
    fi
else
    echo "Using external source tree: $SRC_DIR"
    if [[ ! -f "$SRC_DIR/configure" ]]; then
        echo "XNU_QEMU_DIR does not contain QEMU's configure script." >&2
        exit 1
    fi
fi

patch_makefile_keymap
filter_keymap_csv

cd "$SRC_DIR"

if [[ ! -f config-host.mak ]]; then
    echo "Configuring aarch64-softmmu ..."
    ./configure \
        --target-list=aarch64-softmmu \
        --disable-capstone \
        --disable-pie \
        --disable-slirp \
        --disable-werror \
        --disable-docs
fi

echo "Building with $JOBS job(s) ..."
make -j"$JOBS"

QEMU_BIN="$SRC_DIR/aarch64-softmmu/qemu-system-aarch64"
if [[ ! -x "$QEMU_BIN" ]]; then
    echo "Build finished but $QEMU_BIN is missing." >&2
    exit 1
fi
if ! "$QEMU_BIN" -M help 2>/dev/null | grep -q 'iPhone6splus-n66-s8000'; then
    echo "Built QEMU, but the n66 machine is not listed by -M help." >&2
    exit 1
fi

cat <<EOF

Built: $QEMU_BIN
Machine: iPhone6splus-n66-s8000

Next:
  ./host/doctor.sh
  ./host/prepare-artifacts.py --ipsw /path/to/iPhone_5.5_12.1_16B92_Restore.ipsw
  ./host/boot-n66.sh --firmware host/firmware --dry-run

The machine boots a decoded, patched kernel directly. It does not run iBoot.
EOF
