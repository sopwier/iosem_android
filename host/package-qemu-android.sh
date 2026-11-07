#!/usr/bin/env bash
# Package a cross-compiled qemu-system-aarch64 into the Android APK's jniLibs.
#
# Android only extracts entries whose names end in ".so", and the app can only
# execute files from nativeLibraryDir. The QEMU ELF is therefore renamed to
# libqemu-system-aarch64.so and every bundled shared library is renamed from
# its versioned form (libglib-2.0.so.0) to a plain .so, with the DT_NEEDED
# strings rewritten in place.
#
# patchelf is deliberately NOT used: it relocates PT_INTERP for large
# executables and the Android kernel then refuses to execve them (EINVAL).
# elf-rewrite-needed.py only shortens strings inside .dynstr, so every section
# and program header keeps its original offset.
#
# Usage:
#   host/package-qemu-android.sh [path-to-qemu-system-aarch64]
#
# Environment:
#   IOSEM_ABI           arm64-v8a (default) or x86_64
#   IOSEM_TERMUX_ROOT   extracted Termux prefix for that ABI
#   IOSEM_JNI_DIR       destination (default app/src/main/jniLibs/$IOSEM_ABI)

set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HOST_DIR/.." && pwd)"

ABI="${IOSEM_ABI:-arm64-v8a}"
case "$ABI" in
    arm64-v8a) TRIPLE="aarch64-linux-android"; HOST_TAG="aarch64" ;;
    x86_64) TRIPLE="x86_64-linux-android"; HOST_TAG="x86_64" ;;
    *) echo "unsupported IOSEM_ABI: $ABI" >&2; exit 1 ;;
esac

QEMU_BIN="${1:-$HOST_DIR/.build/xnu-qemu-android-$HOST_TAG/aarch64-softmmu/qemu-system-aarch64}"
TERMUX_ROOT="${IOSEM_TERMUX_ROOT:-$REPO_ROOT/android-deps/termux-$HOST_TAG/root/data/data/com.termux/files/usr}"
JNI_DIR="${IOSEM_JNI_DIR:-$REPO_ROOT/app/src/main/jniLibs/$ABI}"
NDK="${ANDROID_NDK_HOME:-${IOSEM_NDK:-$REPO_ROOT/.android-sdk/ndk/26.1.10909125}}"
NDK_SYSROOT_LIB="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/$TRIPLE"
REWRITE="$HOST_DIR/elf-rewrite-needed.py"

if [[ ! -x "$QEMU_BIN" ]]; then
    echo "missing QEMU binary: $QEMU_BIN" >&2
    exit 1
fi
if [[ ! -d "$TERMUX_ROOT/lib" ]]; then
    echo "missing Termux runtime: $TERMUX_ROOT" >&2
    exit 1
fi
command -v readelf >/dev/null 2>&1 || { echo "readelf is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

# Names provided by Android itself; do not bundle these.
is_system() {
    case "$1" in
        libc.so|libm.so|libdl.so|liblog.so|libandroid.so|libstdc++.so|libatomic.so|libGLESv2.so|libEGL.so)
            return 0 ;;
        *) return 1 ;;
    esac
}

# Resolve a NEEDED name to the file that provides it.
resolve() {
    local name="$1"
    if [[ "$name" == "libc++_shared.so" && -e "$NDK_SYSROOT_LIB/$name" ]]; then
        echo "$NDK_SYSROOT_LIB/$name"
        return 0
    fi
    if [[ -e "$TERMUX_ROOT/lib/$name" ]]; then
        readlink -f "$TERMUX_ROOT/lib/$name"
        return 0
    fi
    return 1
}

# Map the original versioned file name to the flat bundled name.
flat_name() {
    local name="$1"
    case "$name" in
        libglib-2.0.so.*) echo "libglib-2.0.so" ;;
        libgobject-2.0.so.*) echo "libgobject-2.0.so" ;;
        libgio-2.0.so.*) echo "libgio-2.0.so" ;;
        libgmodule-2.0.so.*) echo "libgmodule-2.0.so" ;;
        libgthread-2.0.so.*) echo "libgthread-2.0.so" ;;
        libz.so.*) echo "libz.so" ;;
        libffi.so.*) echo "libffi.so" ;;
        *) echo "$name" ;;
    esac
}

rm -rf "$JNI_DIR"
mkdir -p "$JNI_DIR"

# Breadth-first dependency walk starting at QEMU.
declare -A seen=()
queue=("$(readlink -f "$QEMU_BIN")")
files=()

while ((${#queue[@]})); do
    file="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -n "${seen[$file]:-}" ]] && continue
    seen["$file"]=1
    files+=("$file")

    while IFS= read -r needed; do
        [[ -z "$needed" ]] && continue
        is_system "$needed" && continue
        if provided="$(resolve "$needed")"; then
            [[ -z "${seen[$provided]:-}" ]] && queue+=("$provided")
        else
            echo "warning: unresolved dependency $needed (from ${file##*/})" >&2
        fi
    done < <(readelf -d "$file" 2>/dev/null | awk '/\(NEEDED\)/ {gsub(/[\[\]]/, "", $NF); print $NF}')
done

echo "Bundling ${#files[@]} ELF files:"
declare -A rename=()
for file in "${files[@]}"; do
    name="$(basename "$file")"
    if [[ "$file" == "$(readlink -f "$QEMU_BIN")" ]]; then
        dest="$JNI_DIR/libqemu-system-aarch64.so"
    else
        flat="$(flat_name "$name")"
        dest="$JNI_DIR/$flat"
        # The library's own SONAME is what DT_NEEDED entries name it by.
        soname="$(readelf -d "$file" 2>/dev/null | awk '/\(SONAME\)/ {gsub(/[\[\]]/, "", $NF); print $NF}')"
        if [[ -n "$soname" && "$soname" != "$flat" ]]; then
            rename["$soname"]="$flat"
        fi
        if [[ "$name" != "$flat" && -z "$soname" ]]; then
            rename["$name"]="$flat"
        fi
    fi
    cp -L "$file" "$dest"
    chmod 755 "$dest"
    printf '  %-30s -> %s\n' "$name" "$(basename "$dest")"
done

# Rewrite DT_NEEDED / DT_SONAME in place. Every target name is shorter than
# the versioned original, so no offset changes.
if ((${#rename[@]})); then
    echo
    echo "Rewriting dynamic names:"
    args=()
    for old in "${!rename[@]}"; do
        args+=("$old=${rename[$old]}")
    done
    for dest in "$JNI_DIR"/*.so; do
        python3 "$REWRITE" "$dest" "${args[@]}"
    done
fi

echo
echo "Verifying bundled dependencies ..."
status=0
for dest in "$JNI_DIR"/*.so; do
    while IFS= read -r needed; do
        [[ -z "$needed" ]] && continue
        is_system "$needed" && continue
        if [[ ! -e "$JNI_DIR/$needed" ]]; then
            echo "  MISSING $needed (needed by $(basename "$dest"))" >&2
            status=1
        fi
    done < <(readelf -d "$dest" 2>/dev/null | awk '/\(NEEDED\)/ {gsub(/[\[\]]/, "", $NF); print $NF}')
done

if ((status != 0)); then
    echo "dependency closure is incomplete" >&2
    exit 1
fi

# Android 15+ devices may use 16 KiB pages and will refuse to load a library
# whose LOAD segments are only 4 KiB-aligned. The build script produces 16 KiB
# alignment and links libc++ statically; flag anything that regressed.
for dest in "$JNI_DIR"/*.so; do
    align="$(readelf -lW "$dest" | awk '/LOAD/ {print $NF; exit}')"
    case "$align" in
        0x1000)
            echo "warning: $(basename "$dest") is 4 KiB-aligned (will not load on 16 KiB-page devices)" >&2
            ;;
    esac
done

# Sanity: the executable must still be a well-formed PIE with PT_INTERP early.
readelf -lW "$JNI_DIR/libqemu-system-aarch64.so" | grep -q 'Requesting program interpreter: /system/bin/linker64' \
    || { echo "packaged executable lost its interpreter" >&2; exit 1; }
interp_offset="$(readelf -lW "$JNI_DIR/libqemu-system-aarch64.so" | awk '/INTERP/ {print $2; exit}')"
[[ "$interp_offset" == "0x0002a8" ]] \
    || echo "warning: PT_INTERP moved to $interp_offset (patchelf-style relocation?)" >&2

echo "OK: $JNI_DIR"
ls -lh "$JNI_DIR"
readelf -h "$JNI_DIR/libqemu-system-aarch64.so" | grep -E 'Class|Machine|Type'
