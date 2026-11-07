#!/usr/bin/env bash
# Boot the n66 (iPhone 6s Plus, A9) machine with user-prepared files.
#
# This runs the Aleph xnu-qemu-arm64 machine, which loads a decoded and patched
# iOS 12.1 kernel directly.  It does not emulate BootROM or iBoot.
#
# Usage:
#   ./host/boot-n66.sh --firmware host/firmware --dry-run
#   ./host/boot-n66.sh --firmware /path/to/n66-files
#   ./host/boot-n66.sh --firmware /path/to/n66-files --ram 4G --ramfb on

set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HOST_DIR/.." && pwd)"
FIRMWARE="$HOST_DIR/firmware"
QEMU_BIN="${IOSEM_QEMU_BIN:-}"
RAM="6G"
RAMFB="off"
DRY_RUN=0
SKIP_TYPE_CHECKS=0
CMD_ARGS="debug=0x8 kextlog=0xfff cpus=1 rd=disk0 serial=2"

usage() {
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  --firmware DIR   directory containing the five boot files (default: host/firmware)
  --qemu PATH      qemu-system-aarch64 binary
  --ram SIZE       guest RAM (default: 6G)
  --ramfb on|off   textual framebuffer (default: off; serial is the reliable path)
  --cmdline TEXT   override the kernel command line
  --skip-type-checks  do not check the kernel Mach-O magic or HFS+ signatures
  --dry-run        validate and print the command without executing it
  -h, --help       show this help

Required files in --firmware:
  kernelcache.release.n66.out
  DeviceTree.n66ap.im4p.out
  aleph_bdev_drv.bin
  hfs.main
  hfs.sec
EOF
}

while (($#)); do
    case "$1" in
        --firmware)
            [[ $# -ge 2 ]] || { echo "--firmware needs a value" >&2; exit 2; }
            FIRMWARE="$2"
            shift 2
            ;;
        --qemu)
            [[ $# -ge 2 ]] || { echo "--qemu needs a value" >&2; exit 2; }
            QEMU_BIN="$2"
            shift 2
            ;;
        --ram)
            [[ $# -ge 2 ]] || { echo "--ram needs a value" >&2; exit 2; }
            RAM="$2"
            shift 2
            ;;
        --ramfb)
            [[ $# -ge 2 ]] || { echo "--ramfb needs on or off" >&2; exit 2; }
            RAMFB="$2"
            shift 2
            ;;
        --cmdline)
            [[ $# -ge 2 ]] || { echo "--cmdline needs a value" >&2; exit 2; }
            CMD_ARGS="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --skip-type-checks)
            SKIP_TYPE_CHECKS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$RAMFB" in
    on|off) ;;
    *) echo "--ramfb must be 'on' or 'off'" >&2; exit 2 ;;
esac

if [[ -z "$QEMU_BIN" ]]; then
    for candidate in \
        "$HOST_DIR/.build/xnu-qemu-arm64/aarch64-softmmu/qemu-system-aarch64" \
        "$REPO_ROOT/xnu-qemu-arm64/aarch64-softmmu/qemu-system-aarch64" \
        "$(command -v qemu-system-aarch64 2>/dev/null || true)"
    do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            QEMU_BIN="$candidate"
            break
        fi
    done
fi

FW="$(cd "$FIRMWARE" 2>/dev/null && pwd || true)"
if [[ -z "$FW" || ! -d "$FW" ]]; then
    echo "Firmware directory not found: $FIRMWARE" >&2
    echo "Run prepare-artifacts.py and read host/README.md." >&2
    exit 2
fi

files=(
    "kernelcache.release.n66.out"
    "DeviceTree.n66ap.im4p.out"
    "aleph_bdev_drv.bin"
    "hfs.main"
    "hfs.sec"
)

missing=()
for name in "${files[@]}"; do
    if [[ ! -s "$FW/$name" ]]; then
        missing+=("$name")
    fi
done

if ((${#missing[@]})); then
    echo "Missing or empty boot files in $FW:" >&2
    printf '  [--] %s\n' "${missing[@]}" >&2
    echo >&2
    echo "Required files are user-supplied. See host/README.md and host/DISKS.md." >&2
    echo "prepare-artifacts.py can decode the kernel and device tree, but it cannot" >&2
    echo "build aleph_bdev_drv.bin or the two HFS+ images." >&2
    exit 2
fi

if [[ -z "$QEMU_BIN" || ! -x "$QEMU_BIN" ]]; then
    echo "qemu-system-aarch64 not found." >&2
    echo "Build it with ./host/build-qemu.sh or pass --qemu PATH." >&2
    exit 2
fi

if ! "$QEMU_BIN" -M help 2>/dev/null | grep -q 'iPhone6splus-n66-s8000'; then
    echo "$QEMU_BIN does not provide the iPhone6splus-n66-s8000 machine." >&2
    echo "Build the Aleph fork, not upstream QEMU." >&2
    exit 2
fi

for path in "$FW/kernelcache.release.n66.out" "$FW/DeviceTree.n66ap.im4p.out" \
            "$FW/aleph_bdev_drv.bin" "$FW/hfs.main" "$FW/hfs.sec"; do
    if [[ "$path" == *,* ]]; then
        echo "File names containing commas cannot be passed to -M properties: $path" >&2
        exit 2
    fi
done

if ((!SKIP_TYPE_CHECKS)); then
    kernel="$FW/kernelcache.release.n66.out"
    magic="$(od -An -tx1 -v -N4 "$kernel" | tr -d ' \n')"
    case "$magic" in
        feedface|cefaedfe|feedfacf|cffaedfe|cafebabe|bebafeca) ;;
        *)
            echo "Kernel does not start with a Mach-O magic (got 0x$magic)." >&2
            echo "The n66 machine needs the DECODED kernel, not an IM4P/LZSS file." >&2
            echo "Run host/prepare-artifacts.py, or pass --skip-type-checks if this is deliberate." >&2
            exit 2
            ;;
    esac

    for disk in hfs.main hfs.sec; do
        signature="$(dd if="$FW/$disk" bs=1 skip=1024 count=2 status=none 2>/dev/null || true)"
        if [[ "$signature" != "H+" && "$signature" != "HX" ]]; then
            echo "$disk does not look like an HFS+ volume (no H+/HX signature at offset 1024)." >&2
            echo "The block driver exposes raw HFS+ images; see host/DISKS.md." >&2
            echo "Pass --skip-type-checks if you are using a different container." >&2
            exit 2
        fi
    done
fi

if [[ -r /proc/meminfo ]]; then
    mem_mib="$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)"
    avail_mib="${mem_mib:-0}"
    if [[ "$RAM" =~ ^([0-9]+)G$ ]]; then
        want_mib=$(( BASH_REMATCH[1] * 1024 ))
    elif [[ "$RAM" =~ ^([0-9]+)M$ ]]; then
        want_mib=${BASH_REMATCH[1]}
    else
        want_mib=0
    fi
    if (( want_mib > 0 && avail_mib < want_mib + 512 )); then
        echo "warning: only ${avail_mib} MiB RAM available; guest requests ${RAM}." >&2
        echo "         The upstream procedure assumes 6G, but early boot may fit in less." >&2
    fi
fi

# The machine's property parser is comma-separated.  Keep this one -M argument
# as a single array element so spaces in kern-cmd-args survive.
machine="iPhone6splus-n66-s8000"
machine+=",kernel-filename=$FW/kernelcache.release.n66.out"
machine+=",dtb-filename=$FW/DeviceTree.n66ap.im4p.out"
machine+=",driver-filename=$FW/aleph_bdev_drv.bin"
machine+=",qc-file-0-filename=$FW/hfs.main"
machine+=",qc-file-1-filename=$FW/hfs.sec"
machine+=",kern-cmd-args=$CMD_ARGS"
machine+=",xnu-ramfb=$RAMFB"

cmd=("$QEMU_BIN" -M "$machine" -cpu max -m "$RAM" -serial mon:stdio)
if [[ "$RAMFB" == "off" ]]; then
    cmd+=(-display none)
fi

echo "QEMU:      $QEMU_BIN"
echo "Firmware:  $FW"
echo "RAM:       $RAM"
echo "Framebuffer: $RAMFB"
echo "Mode:      TCG (this host is not natively AArch64)"
echo

if ((DRY_RUN)); then
    printf 'Command:\n  '
    printf '%q ' "${cmd[@]}"
    printf '\n'
    exit 0
fi

echo "Starting. Serial console is on stdio; quit with Ctrl-A X."
echo "There is no graceful shutdown; hfs.sec may need repair after a hard stop."
echo
exec "${cmd[@]}"
