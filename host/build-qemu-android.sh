#!/usr/bin/env bash
# Cross-compile the n66 QEMU fork for Android/arm64 and package it into the APK.
#
# This is a research build: it expects the host harness (host/build-qemu.sh)
# to have run at least once, because that step produces the patched Makefile
# and the pinned keycodemapdb checkout.
#
# Requirements:
#   - Android NDK r26b (26.1.10909125) at $ANDROID_NDK_HOME, $IOSEM_NDK, or
#     .android-sdk/ndk/26.1.10909125
#   - android-deps/termux-aarch64/root populated (see host/fetch-android-deps.sh)
#
# Usage:
#   ./host/build-qemu-android.sh
#   ./host/build-qemu-android.sh --package-only

set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HOST_DIR/.." && pwd)"

NDK="${ANDROID_NDK_HOME:-${IOSEM_NDK:-$REPO_ROOT/.android-sdk/ndk/26.1.10909125}}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
ABI="${IOSEM_ABI:-arm64-v8a}"
case "$ABI" in
    arm64-v8a) TRIPLE="aarch64-linux-android"; HOST_TAG="aarch64" ;;
    x86_64) TRIPLE="x86_64-linux-android"; HOST_TAG="x86_64" ;;
    *) echo "unsupported IOSEM_ABI: $ABI" >&2; exit 1 ;;
esac
TERMUX_ROOT="${IOSEM_TERMUX_ROOT:-$REPO_ROOT/android-deps/termux-$HOST_TAG/root}"
TCROOT="$TERMUX_ROOT/data/data/com.termux/files/usr"
SRC="${IOSEM_ANDROID_SRC:-$HOST_DIR/.build/xnu-qemu-android-$HOST_TAG}"
HOST_SRC="$HOST_DIR/.build/xnu-qemu-arm64"
DOWNLOADS="$HOST_DIR/.build/downloads"
ARCHIVE="$DOWNLOADS/xnu-qemu-arm64-2694993f9281a8678d519704c3cd29d4c9d39415.tar.gz"
JOBS="${IOSEM_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"

PACKAGE_ONLY=0
[[ "${1:-}" == "--package-only" ]] && PACKAGE_ONLY=1

if [[ ! -x "$TOOLCHAIN/bin/clang" ]]; then
    echo "NDK not found at $NDK (set ANDROID_NDK_HOME)" >&2
    exit 1
fi
if [[ ! -d "$TCROOT/lib" ]]; then
    echo "Termux runtime not found at $TCROOT" >&2
    echo "Run host/fetch-android-deps.sh first." >&2
    exit 1
fi

if ((PACKAGE_ONLY == 0)); then
    if [[ ! -d "$SRC" ]]; then
        echo "Creating Android source tree at $SRC ..."
        if [[ ! -s "$ARCHIVE" ]]; then
            echo "missing $ARCHIVE; run host/build-qemu.sh once to download it" >&2
            exit 1
        fi
        mkdir -p "$SRC"
        tar -xzf "$ARCHIVE" -C "$SRC" --strip-components=1

        # Reuse the patched Makefile and filtered keycodemapdb from the host
        # build so this script does not duplicate the compatibility logic.
        if [[ -f "$HOST_SRC/Makefile" && -d "$HOST_SRC/ui/keycodemapdb" ]]; then
            cp "$HOST_SRC/Makefile" "$SRC/Makefile"
            rm -rf "$SRC/ui/keycodemapdb"
            cp -a "$HOST_SRC/ui/keycodemapdb" "$SRC/ui/keycodemapdb"
        else
            echo "run host/build-qemu.sh first: patched Makefile/keycodemapdb missing" >&2
            exit 1
        fi
    fi

    # bionic declares openpty() in <pty.h>, but QEMU 4.2 only includes that
    # header for glibc. Patch idempotently.
    python3 - "$SRC/util/qemu-openpty.c" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
old = "#if defined(__GLIBC__)\n# include <pty.h>"
new = "#if defined(__GLIBC__) || defined(__ANDROID__)\n# include <pty.h>"
if old in s:
    p.write_text(s.replace(old, new, 1))
    print("patched qemu-openpty.c for bionic")
PY

    export PKG_CONFIG_SYSROOT_DIR="$TERMUX_ROOT"
    export PKG_CONFIG_LIBDIR="$TCROOT/lib/pkgconfig:$TCROOT/share/pkgconfig"
    export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
    export CC="$TOOLCHAIN/bin/$TRIPLE"26-clang
    export CXX="$TOOLCHAIN/bin/$TRIPLE"26-clang++
    export AR="$TOOLCHAIN/bin/llvm-ar"
    export AS="$TOOLCHAIN/bin/llvm-as"
    export NM="$TOOLCHAIN/bin/llvm-nm"
    export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
    export STRIP="$TOOLCHAIN/bin/llvm-strip"
    export OBJCOPY="$TOOLCHAIN/bin/llvm-objcopy"
    export LD="$TOOLCHAIN/bin/ld.lld"

    cd "$SRC"
    if [[ ! -f config-host.mak ]]; then
        echo "Configuring aarch64-softmmu for Android ..."
        ./configure \
            --target-list=aarch64-softmmu \
            --extra-cflags="-I$TCROOT/include -I$TCROOT/include/glib-2.0 -I$TCROOT/lib/glib-2.0/include -I$TCROOT/include/pixman-1" \
            --extra-ldflags="-L$TCROOT/lib" \
            --audio-drv-list= \
            --disable-capstone --disable-slirp --disable-werror --disable-docs \
            --disable-tools --disable-guest-agent \
            --disable-gtk --disable-sdl --disable-vnc --disable-curses --disable-opengl \
            --disable-virglrenderer --disable-usb-redir --disable-libusb \
            --disable-vhost-net --disable-vhost-crypto --disable-vhost-user \
            --disable-vhost-vsock --disable-vhost-scsi --disable-virtfs \
            --disable-glusterfs --disable-libiscsi --disable-libnfs --disable-rbd \
            --disable-curl --disable-smartcard --disable-spice \
            --disable-seccomp --disable-attr --disable-cap-ng --disable-xfsctl \
            --disable-libpmem --disable-iconv
    fi

    # Android's app seccomp policy blocks signalfd/signalfd4 with SIGSYS.
    # QEMU falls back to a pipe + helper thread when CONFIG_SIGNALFD is off.
    # The aarch64 probe already fails (there is only SYS_signalfd4), but the
    # x86_64 probe succeeds and the resulting binary is killed at startup
    # inside the app.
    if grep -q '^CONFIG_SIGNALFD=y' config-host.mak 2>/dev/null; then
        sed -i 's/^CONFIG_SIGNALFD=y/CONFIG_SIGNALFD=n/' config-host.mak
        sed -i '/#define CONFIG_SIGNALFD 1/d' config-host.h
        rm -f util/compatfd.o
        echo "disabled signalfd: Android app seccomp blocks it"
    fi

    # Android 15+ devices may use 16 KiB pages and refuse to map ELF segments
    # aligned to only 4 KiB. The Termux libraries are already 0x4000-aligned;
    # the executable and the NDK's libc++_shared are not. Link libc++ statically
    # and align every segment to 16 KiB so the same APK works on both page sizes.
    if ! grep -q 'max-page-size' config-host.mak 2>/dev/null; then
        sed -i 's|^LDFLAGS=\(.*\)$|LDFLAGS=\1 -Wl,-z,max-page-size=16384 -static-libstdc++|' config-host.mak
        rm -f aarch64-softmmu/qemu-system-aarch64
        echo "linking for 16 KiB pages and static libc++"
    fi

    echo "Building with $JOBS job(s) ..."
    make -j"$JOBS"
fi

QEMU_BIN="$SRC/aarch64-softmmu/qemu-system-aarch64"
[[ -x "$QEMU_BIN" ]] || { echo "build did not produce $QEMU_BIN" >&2; exit 1; }

IOSEM_ABI="$ABI" IOSEM_TERMUX_ROOT="$TCROOT" \
    "$HOST_DIR/package-qemu-android.sh" "$QEMU_BIN"

cat <<EOF

Packaged native backend:
  app/src/main/jniLibs/$ABI/libqemu-system-aarch64.so

Next:
  ./host/build-apk.sh
  adb install -r app/build/outputs/apk/debug/app-debug.apk

The APK still does not contain any Apple firmware.
EOF
