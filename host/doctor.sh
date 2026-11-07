#!/usr/bin/env bash
# Report whether this host can build the n66 QEMU backend and whether the
# user-supplied boot files are present.  This never downloads firmware.

set -uo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HOST_DIR/.." && pwd)"
BUILD_DIR="${IOSEM_BUILD_DIR:-$HOST_DIR/.build}"
ENV_FILE="$BUILD_DIR/toolchain.env"
FW="${1:-$HOST_DIR/firmware}"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

ok=0
warn=0
bad=0

status() {
    local state="$1" label="$2" detail="${3:-}"
    case "$state" in
        ok)   printf '  [ok]   %-26s %s\n' "$label" "$detail"; ((ok++)) ;;
        warn) printf '  [warn] %-26s %s\n' "$label" "$detail"; ((warn++)) ;;
        bad)  printf '  [--]   %-26s %s\n' "$label" "$detail"; ((bad++)) ;;
    esac
}

echo "iosem host doctor"
echo "host: $(uname -s) $(uname -m), $(getconf _NPROCESSORS_ONLN 2>/dev/null || echo '?') CPUs"
echo

echo "Build tools"
for command in make gcc g++ pkg-config flex bison python3 curl tar; do
    if command -v "$command" >/dev/null 2>&1; then
        status ok "$command" "$(command -v "$command")"
    else
        status bad "$command" "missing"
    fi
done
for package in glib-2.0 pixman-1 zlib; do
    if version="$(pkg-config --modversion "$package" 2>/dev/null)"; then
        status ok "pkg-config $package" "$version"
    else
        status bad "pkg-config $package" "missing"
    fi
done
if printf '#include <libfdt.h>\nint main(void){return 0;}\n' | "${CC:-cc}" -x c - -o /dev/null >/dev/null 2>&1; then
    status ok "libfdt" "headers and library usable"
else
    status bad "libfdt" "missing libfdt-dev"
fi

echo
echo "Machine backend"
QEMU_BIN="${IOSEM_QEMU_BIN:-}"
if [[ -z "$QEMU_BIN" ]]; then
    for candidate in \
        "$BUILD_DIR/xnu-qemu-arm64/aarch64-softmmu/qemu-system-aarch64" \
        "$REPO_ROOT/xnu-qemu-arm64/aarch64-softmmu/qemu-system-aarch64" \
        "$(command -v qemu-system-aarch64 2>/dev/null || true)"
    do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            QEMU_BIN="$candidate"
            break
        fi
    done
fi

if [[ -n "$QEMU_BIN" && -x "$QEMU_BIN" ]]; then
    status ok "qemu-system-aarch64" "$QEMU_BIN"
    if "$QEMU_BIN" -M help 2>/dev/null | grep -q 'iPhone6splus-n66-s8000'; then
        status ok "n66 machine" "iPhone6splus-n66-s8000"
    else
        status bad "n66 machine" "binary is upstream QEMU or a different fork"
    fi
else
    status bad "qemu-system-aarch64" "not built; run ./host/build-qemu.sh"
fi

echo
echo "Host resources"
if [[ -r /proc/meminfo ]]; then
    mem_mib="$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)"
    if [[ -n "$mem_mib" && "$mem_mib" -lt 7000 ]]; then
        status warn "available RAM" "${mem_mib} MiB (guest default is 6 GiB; use --ram)"
    else
        status ok "available RAM" "${mem_mib:-?} MiB"
    fi
fi
avail_kb="$(df -Pk "$HOST_DIR" | awk 'NR==2 {print $4}')"
status ok "free disk (host/)" "$((avail_kb / 1024 / 1024)) GiB"
if [[ -r /dev/kvm ]]; then
    status warn "/dev/kvm" "present, but x86 KVM cannot run an AArch64 guest"
else
    status ok "/dev/kvm" "absent; TCG is expected"
fi

echo
echo "Boot files ($FW)"
if [[ ! -d "$FW" ]]; then
    status bad "firmware directory" "missing"
else
    required=(
        kernelcache.release.n66.out
        DeviceTree.n66ap.im4p.out
        aleph_bdev_drv.bin
        hfs.main
        hfs.sec
    )
    for name in "${required[@]}"; do
        if [[ -s "$FW/$name" ]]; then
            bytes="$(stat -c '%s' "$FW/$name" 2>/dev/null || echo '?')"
            status ok "$name" "$bytes bytes"
        else
            status bad "$name" "missing or empty"
        fi
    done
    optional=(048-32651-104.dmg.out manifest.json)
    for name in "${optional[@]}"; do
        if [[ -s "$FW/$name" ]]; then
            bytes="$(stat -c '%s' "$FW/$name" 2>/dev/null || echo '?')"
            status ok "$name (optional)" "$bytes bytes"
        else
            status warn "$name (optional)" "absent"
        fi
    done
fi

echo
echo "Summary: $ok ok, $warn warning(s), $bad missing/blocking item(s)"
if ((bad)); then
    echo
    echo "This host is not ready.  See host/README.md for the five-file contract."
    exit 1
fi
echo "Host is ready to build and launch the n66 command line."
