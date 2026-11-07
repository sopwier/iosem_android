#!/usr/bin/env bash
# Boot a headless Android emulator, install the APK, and verify that the
# packaged QEMU executable actually loads and runs on Android.
#
# This does not boot iOS. It proves the launcher path:
#   - the ELF executable is extracted into nativeLibraryDir
#   - bionic's linker resolves the bundled flat .so closure via LD_LIBRARY_PATH
#   - SELinux allows executing it for a targetSdk-28 app
#   - the n66 machine is present in `-M help`
#
# If a device is already connected and booted, that device is reused and the
# script will not stop it.
#
# Requirements: KVM, ~4 GiB free RAM, the emulator + a system image:
#   sdkmanager "emulator" "system-images;android-30;aosp_atd;x86_64"
#
# Usage:
#   ./host/test-android-emulator.sh
#   IOSEM_AVD=my-avd IOSEM_MEM=2048 ./host/test-android-emulator.sh

set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HOST_DIR/.." && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$REPO_ROOT/.android-sdk}}"
APK="${IOSEM_APK:-$REPO_ROOT/app/build/outputs/apk/debug/app-debug.apk}"
AVD="${IOSEM_AVD:-iosem-test}"
IMAGE="${IOSEM_IMAGE:-system-images;android-30;aosp_atd;x86_64}"
MEM="${IOSEM_MEM:-2048}"
ADB="$SDK/platform-tools/adb"
EMULATOR="$SDK/emulator/emulator"
PACKAGE="dev.iosem"
LOGCAT="$REPO_ROOT/host/.build/emulator-logcat.txt"

if [[ ! -x "$EMULATOR" ]]; then
    echo "emulator missing: $EMULATOR" >&2
    exit 1
fi
if [[ ! -x "$ADB" ]]; then
    echo "adb missing: $ADB" >&2
    exit 1
fi
if [[ ! -f "$APK" ]]; then
    echo "APK missing: $APK (run host/build-apk.sh)" >&2
    exit 1
fi
if [[ ! -r /dev/kvm ]]; then
    echo "warning: /dev/kvm is not readable; booting will be very slow" >&2
fi

export ANDROID_SDK_ROOT="$SDK"
export ANDROID_HOME="$SDK"

# avdmanager may place AVDs under $XDG_CONFIG_HOME/.android/avd while the
# emulator defaults to $HOME/.android/avd. Point both at the same place.
if [[ ! -d "$HOME/.android/avd" && -d "$HOME/.config/.android/avd" ]]; then
    export ANDROID_AVD_HOME="$HOME/.config/.android/avd"
fi

# --- reuse or boot ---------------------------------------------------------
mkdir -p "$REPO_ROOT/host/.build"

is_booted() {
    [[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]
}

EMU_PID=""
if is_booted; then
    echo "Reusing the connected device; it will be left running."
else
    # --- AVD ---------------------------------------------------------------
    if ! "$EMULATOR" -list-avds 2>/dev/null | grep -qx "$AVD"; then
        echo "Creating AVD '$AVD' from $IMAGE ..."
        printf 'no\n' | "$SDK/cmdline-tools/latest/bin/avdmanager" create avd \
            -n "$AVD" -k "$IMAGE" --device "medium_phone" --force
    fi

    echo "Booting $AVD ..."
    "$EMULATOR" -avd "$AVD" \
        -no-window -no-audio -no-boot-anim -no-snapshot \
        -gpu swiftshader_indirect \
        -memory "$MEM" \
        -netdelay none -netspeed full \
        > "$REPO_ROOT/host/.build/emulator-stdout.txt" 2>&1 &
    EMU_PID=$!

    cleanup() {
        echo "Stopping emulator (pid $EMU_PID) ..."
        "$ADB" emu kill >/dev/null 2>&1 || true
        kill "$EMU_PID" 2>/dev/null || true
    }
    trap cleanup EXIT

    echo "Waiting for device ..."
    "$ADB" wait-for-device
    for _ in $(seq 1 180); do
        is_booted && break
        sleep 2
    done
    if ! is_booted; then
        echo "emulator did not finish booting; see host/.build/emulator-stdout.txt" >&2
        exit 1
    fi
fi
echo "Device: $("$ADB" shell getprop ro.product.cpu.abi | tr -d '\r') / API $("$ADB" shell getprop ro.build.version.sdk | tr -d '\r')"

# --- install ---------------------------------------------------------------
"$ADB" install -r "$APK"

"$ADB" logcat -c || true
"$ADB" shell am start -n "$PACKAGE/.MainActivity" >/dev/null
sleep 5

# --- verify nativeLibraryDir ----------------------------------------------
echo
echo "=== extracted native libraries ==="
APK_PATH="$("$ADB" shell pm path "$PACKAGE" | tr -d '\r' | sed -n 's#^package:##p' | head -1)"
APK_DIR="$(dirname "$APK_PATH")"
ABI="$("$ADB" shell getprop ro.product.cpu.abi | tr -d '\r')"
NATIVE_DIR="$APK_DIR/lib/$ABI"
echo "nativeLibraryDir = $NATIVE_DIR"
"$ADB" shell "ls -l $NATIVE_DIR/libqemu-system-aarch64.so 2>&1" || true

# --- self-test: execute the packaged ELF as the app -----------------------
echo
echo "=== run-as self-test (qemu -M help) ==="
"$ADB" shell "run-as $PACKAGE sh -c 'cd /data/data/$PACKAGE && LD_LIBRARY_PATH=$NATIVE_DIR $NATIVE_DIR/libqemu-system-aarch64.so -M help'" \
    > "$REPO_ROOT/host/.build/emulator-selftest.txt" 2>&1 || true
if grep -q "iPhone6splus-n66-s8000" "$REPO_ROOT/host/.build/emulator-selftest.txt"; then
    echo "PASS: the packaged QEMU executable runs and lists the n66 machine."
    grep -m1 "iPhone6splus-n66-s8000" "$REPO_ROOT/host/.build/emulator-selftest.txt"
    SELFTEST=0
else
    echo "FAIL: could not run the packaged executable."
    sed -n '1,40p' "$REPO_ROOT/host/.build/emulator-selftest.txt"
    SELFTEST=1
fi

# --- collect logs ----------------------------------------------------------
"$ADB" logcat -d > "$LOGCAT" 2>/dev/null || true
echo
echo "logcat written to $LOGCAT"
echo "--- iosem-qemu lines ---"
grep -F "iosem-qemu" "$LOGCAT" | tail -20 || echo "(none yet; press Self-test in the app)"

exit "$SELFTEST"
