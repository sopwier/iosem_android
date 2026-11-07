#!/usr/bin/env bash
# Build the Android APK locally.
#
# The QEMU backend must already be packaged by host/build-qemu-android.sh.
# If it is absent the app still builds, but the Console reports that the
# native backend is missing instead of pretending to emulate.

set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HOST_DIR/.." && pwd)"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$REPO_ROOT/.android-sdk}}"
export ANDROID_HOME="$SDK"
export ANDROID_SDK_ROOT="$SDK"

# AGP needs a full JDK (jlink), not just a JRE.
needs_jdk=1
if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/jlink" ]]; then
    needs_jdk=0
fi
if ((needs_jdk)); then
    for candidate in \
        /usr/lib/jvm/java-21-openjdk-amd64 \
        /usr/lib/jvm/java-17-openjdk-amd64 \
        /tmp/jdk21-root/usr/lib/jvm/java-21-openjdk-amd64; do
        if [[ -x "$candidate/bin/jlink" ]]; then
            export JAVA_HOME="$candidate"
            needs_jdk=0
            break
        fi
    done
fi
if ((needs_jdk)); then
    echo "no full JDK with jlink found; set JAVA_HOME to a JDK 17 or 21" >&2
    exit 1
fi

if [[ ! -f "$REPO_ROOT/local.properties" ]]; then
    printf 'sdk.dir=%s\n' "$SDK" > "$REPO_ROOT/local.properties"
fi

cd "$REPO_ROOT"

if [[ -x .gradle-dists/extracted/gradle-8.7/bin/gradle ]]; then
    GRADLE=.gradle-dists/extracted/gradle-8.7/bin/gradle
elif command -v gradle >/dev/null 2>&1; then
    GRADLE=gradle
else
    GRADLE=./gradlew
fi

if [[ ! -e app/src/main/jniLibs/arm64-v8a/libqemu-system-aarch64.so ]]; then
    echo "warning: QEMU backend is not packaged; the APK will report it as missing" >&2
fi

"$GRADLE" --no-daemon :app:assembleDebug

APK="$REPO_ROOT/app/build/outputs/apk/debug/app-debug.apk"
[[ -f "$APK" ]] || { echo "APK not produced" >&2; exit 1; }

echo
ls -lh "$APK"
echo "Install with: adb install -r $APK"
