# Host n66 harness

This directory is the first real milestone: a Linux host build of the
[`alephsecurity/xnu-qemu-arm64`](https://github.com/alephsecurity/xnu-qemu-arm64)
fork and a command-line harness for its `iPhone6splus-n66-s8000` machine.

It is **not** an Android backend and it does **not** include iOS. It is a
host-side way to validate the exact machine model and file contract that an
Android backend would have to reuse.

## What actually boots

The public n66 machine is specific and narrower than the project discussion
sometimes suggests:

| item | reality |
| --- | --- |
| target | iOS 12.1, build 16B92, iPhone 6s Plus `n66` / `s8000` |
| boot path | QEMU loads a **decoded, in-memory-patched XNU kernel directly** |
| iBoot | **not used**; the machine has no BootROM or iBoot emulation |
| kernel patches | hard-coded virtual addresses for 16B92 inside `hw/arm/n66_iphone6splus.c` |
| userspace | launchd plus a bash shell over serial or the upstream SSH tunnel, not a usable phone |
| GUI / touch / Wi-Fi / cellular / SEP | absent; SSH only through the upstream TCP tunnel |
| CPU | one A9-class CPU under TCG; no KVM acceleration on x86 |
| RAM | 6 GiB guest by default; a phone will not fit this |

The hard-coded kernel addresses are why iOS 10/11 is **not** a supported target
for this machine. Changing the build requires finding the equivalent patch
sites and boot arguments for that kernel, which is reverse-engineering work,
not a flag.

The fork also patches the kernel in memory to bypass CoreTrust and several
other checks. That is upstream research code, not code in this repository.
Read the legal note before using it.

## The five-file contract

The machine command needs these files. The first two can be derived from a
user's IPSW; the other three cannot be produced by this repository's decoder.

| file | required | how you get it |
| --- | --- | --- |
| `kernelcache.release.n66.out` | yes | decode `kernelcache.release.n66` from your IPSW (ASN.1 IM4P + LZSS) |
| `DeviceTree.n66ap.im4p.out` | yes | decode `Firmware/all_flash/DeviceTree.n66ap.im4p` |
| `aleph_bdev_drv.bin` | yes | compile `xnu-qemu-arm64-tools/aleph_bdev_drv` against matching kernel symbols |
| `hfs.main` | yes | prepared HFS+ image containing the iOS system volume |
| `hfs.sec` | yes | prepared HFS+ image mounted at `/private/var` |
| `048-32651-104.dmg.out` | optional | decoded restore ramdisk; not used by the custom-disk command |

`prepare-artifacts.py` handles the first two and the optional ramdisk. It does
not download anything and it does not create the disk images or the driver.
See [`DISKS.md`](DISKS.md) for the disk step.

## Quick start

On Debian/Ubuntu with normal build dependencies:

```bash
sudo apt install build-essential flex bison libglib2.0-dev \
                 libpixman-1-dev zlib1g-dev libfdt-dev
```

If you do not have root, this repository has a Debian/Ubuntu helper that
downloads the compiler, flex/bison and libfdt headers into `host/.build/`
without installing system packages. You still need glib-2.0, pixman-1 and
zlib development files (or at least their headers, libraries and pkg-config
metadata) available for QEMU to configure.

```bash
./host/bootstrap-deps.sh
```

Build QEMU:

```bash
./host/build-qemu.sh
./host/doctor.sh
./host/selftest.sh
```

The build script pins the fork to commit
`2694993f9281a8678d519704c3cd29d4c9d39415`, applies two compatibility fixes for
a modern host (keycodemapdb CLI order, and filtering qcodes newer than this
QEMU tree), and builds `aarch64-softmmu` only. It downloads the source from
GitHub; `IOSEM_GITHUB_PROXY` defaults to `https://gh-proxy.com/` because
direct GitHub is slow on some networks. Set it to an empty string to use
GitHub directly.

Prepare files from an IPSW you obtained for a device you own:

```bash
./host/prepare-artifacts.py \
  --ipsw ~/Downloads/iPhone_5.5_12.1_16B92_Restore.ipsw \
  --out host/firmware
```

Then add the driver and the two disks described in [`DISKS.md`](DISKS.md):

```bash
cp /path/to/aleph_bdev_drv.bin host/firmware/
cp /path/to/hfs.main host/firmware/
cp /path/to/hfs.sec host/firmware/
```

Check and boot:

```bash
./host/doctor.sh
./host/boot-n66.sh --dry-run
./host/boot-n66.sh
```

`boot-n66.sh` refuses to run if any of the five files is missing. To see the
exact command before a full set exists, run it with `--dry-run`; to populate a
partial set, use `prepare-artifacts.py --input DIR` or pass explicit
`--kernel`/`--device-tree` paths. There is no silent fallback.

## Building the block-device driver

This is upstream work and needs a cross-compiler plus the XNU headers and
symbols matching the kernel you are booting. The public recipe is:

```bash
# 1. Matching open-source XNU headers. iOS 12.1 is XNU 4903.221.2.
python3 tools/fetch_xnu.py --tag xnu-4903.221.2 --out /tmp/xnu-4903.221.2.tar.gz
mkdir -p /tmp/xnu && tar -xzf /tmp/xnu-4903.221.2.tar.gz -C /tmp/xnu --strip-components=1

# 2. The helper repository.
git clone https://github.com/alephsecurity/xnu-qemu-arm64-tools.git /tmp/xnu-tools

# 3. Symbols from the decoded kernel. GNU binutils nm cannot read Mach-O;
#    use LLVM's nm (package: llvm) or macOS nm.
llvm-nm -n host/firmware/kernelcache.release.n66.out > /tmp/symbols.nm
grep -q ' _' /tmp/symbols.nm || echo "warning: no symbols found"

# 4. Cross compiler: upstream uses aarch64-none-elf-gcc (bare-metal). On
#    Debian/Ubuntu, gcc-aarch64-linux-gnu is a usable substitute when the
#    freestanding flags still link; pass CROSS=aarch64-linux-gnu-. Verify the
#    resulting flat binary, and prefer aarch64-none-elf for exact parity.
sudo apt install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
export XNU_SOURCES=/tmp/xnu
export KERNEL_SYMBOLS_FILE=/tmp/symbols.nm
export QEMU_DIR="$PWD/host/.build/xnu-qemu-arm64"
export NUM_BLOCK_DEVS=2
make -C /tmp/xnu-tools/aleph_bdev_drv CROSS=aarch64-linux-gnu-
cp /tmp/xnu-tools/aleph_bdev_drv/bin/aleph_bdev_drv.bin host/firmware/
```

If your toolchain is named differently, override `CROSS` and `CC` on the make
command line. The driver is position-independent code loaded into kernel
memory by the machine's hook mechanism; it must match the kernel's symbols.

## Android emulator app

The Android app now packages a cross-compiled QEMU backend. The artifact manager
and the launcher are real; the five Apple files are still user-supplied.

```bash
# 1. Fetch the bionic aarch64/x86_64 runtime used at build time.
./host/fetch-android-deps.sh

# 2. Cross-build the machine and copy it into app/src/main/jniLibs.
./host/build-qemu-android.sh

# 3. Build the APK.
./host/build-apk.sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Inside the app: import the five files through **Files**, then press **Start** in
**Console**. **Self-test** runs `qemu-system-aarch64 -M help` and confirms that
the executable and its bundled libraries load on the device.

### How the backend is packaged

- The ELF executable is named `libqemu-system-aarch64.so` inside the APK, so
  Android extracts it to `nativeLibraryDir`, the only app-owned directory that
  stays executable for modern target levels.
- GLib, GThread, pixman, libfdt, PCRE2, libiconv, zlib, libandroid-support and
  the NDK's `libc++_shared` are copied under flat `.so` names. Their
  `DT_NEEDED` strings (and `DT_SONAME`) are rewritten **in place** by
  `host/elf-rewrite-needed.py`. patchelf is deliberately not used: on large
  executables it relocates `PT_INTERP` and `.dynsym` to the end of the file and
  the Android kernel then refuses the result with `EINVAL` on `execve`.
- There is no `RUNPATH`. The launcher sets `LD_LIBRARY_PATH` to
  `nativeLibraryDir`, which is what bionic uses to resolve the flat names.
- `useLegacyPackaging = true` (and therefore `extractNativeLibs=true`) makes the
  package manager unpack those files.
- **`targetSdk = 28` is deliberate.** QEMU TCG writes translated code into
  anonymous memory and executes it. Android 10+ removes `execmem` from app
  SELinux domains for targetSdk >= 29; Termux targets 28 for the same reason.
  `compileSdk` remains 35.
- **`CONFIG_SIGNALFD` is forced off.** Android's app seccomp policy blocks
  `signalfd` (x86_64) and `signalfd4` (aarch64) with `SIGSYS`. The aarch64 probe
  already fails, but the x86_64 build would be killed on startup without the
  override; QEMU's pipe + helper thread fallback is used instead.
- **Segments are aligned to 16 KiB and libc++ is static.** Android 15+ devices
  may use 16 KiB pages and refuse 4 KiB-aligned `LOAD` segments. The Termux
  libraries already ship `0x4000` alignment; the executable is linked with
  `-Wl,-z,max-page-size=16384`, and `-static-libstdc++` removes the NDK's
  4 KiB-aligned `libc++_shared.so` from the bundle. The same APK therefore runs
  on both 4 KiB and 16 KiB page kernels.

### What has actually been run on Android

Verified on an Android 11 (API 30) x86_64 emulator with the packaged APK:

- the app installs and extracts the whole backend into `nativeLibraryDir`;
- **Self-test** in the app returns `exit=0` and `machine listed: true`;
- `-M virt -accel tcg` translates and executes AArch64 code, so `execmem`,
  bionic's linker and the bundled glib/pixman closure all work inside the
  app's SELinux/seccomp domain;
- **Start** launches the n66 machine, opens the five artifact files and reaches
  kernel loading. With placeholder files it then crashes, exactly as the host
  build does with the same placeholders.

A real boot still needs the five genuine files from iOS 12.1 build 16B92.

`host/test-android-emulator.sh` automates the emulator install and the
`run-as` execution check.

### Android limitations

- 4 KiB ELF alignment only. Devices with 16 KiB pages need a rebuild with
  `-Wl,-z,max-page-size=16384` and 16 KiB-aligned bundled libraries.
- The launcher requests half of physical RAM (rounded down to 512 MiB, clamped
  to 1-4 GiB). Most phones will not sustain the upstream 6 GiB configuration,
  and Android's low-memory killer may terminate the app first.
- QEMU runs inside the app process. There is no foreground service yet, so
  backgrounding the app can stop the machine.
- Only the serial console is exposed. `xnu-ramfb` is off.
- x86_64 Android is supported by the same scripts (`IOSEM_ABI=x86_64`); it is
  useful for emulator testing but runs the AArch64 guest under TCG.

## Known limitations

- **No iBoot.** The machine is not an iPhone boot chain. It is a research
  harness that loads a patched kernel.
- **16B92 only.** Other builds will not hit the hard-coded patch addresses.
- **Unaccelerated on x86.** `-cpu max` with TCG; expect a slow boot. KVM support
  exists upstream only on an AArch64 host with a matching kernel.
- **6 GiB guest.** The test host had only about 2 GiB available, so the default
  is tight. `--ram 4G` may work for early boot, but the upstream procedure
  assumes 6 GiB.
- **Serial only.** `xnu-ramfb=on` exists but is a textual framebuffer, not a
  usable display path.
- **No graceful shutdown.** Killing QEMU can leave `hfs.sec` needing repair.

## Troubleshooting

**`missing file ui/keycodemapdb/README`** — the GitHub tarball is not a git
checkout with submodules. `build-qemu.sh` supplies the pinned keycodemapdb
archive. Do not use a plain QEMU release tarball for this fork.

**`invalid choice: 'glib2'`** — the current keycodemapdb moved its `--lang`
option behind the subcommand. `build-qemu.sh` applies the argument-order patch.

**`Q_KEY_CODE_F13` / `LANG1` undeclared** — current keycodemapdb has qcodes that
this older QEMU does not. The build script filters the CSV against the tree's
own `QKeyCode` enum before generating the tables.

**`DTC (libfdt) version >= 1.4.2 not present`** — install `libfdt-dev`, or use
`bootstrap-deps.sh` and source `host/.build/toolchain.env`.

**`nm: ... file format not recognized`** — GNU binutils cannot read a Mach-O
kernel. Use `llvm-nm` (Debian/Ubuntu package `llvm`) or macOS `nm` to produce the
symbols file for the driver build.

**QEMU exits immediately after `-M` parsing** — check that all five paths are
absolute, exist, and contain no commas. The machine's `-M` property syntax is
comma-separated.

**`Kernel does not start with a Mach-O magic`** — you pointed at the original
`kernelcache.release.n66` (IM4P) instead of the decoded
`kernelcache.release.n66.out`. Run `prepare-artifacts.py`. Use
`--skip-type-checks` only if you know the file is valid.

**`does not look like an HFS+ volume`** — `hfs.main` and `hfs.sec` must be raw
HFS+ images with an `H+` or `HX` volume signature at offset 1024. A DMG or a
freshly `dd`'d empty file will not work.

**No display window** — `boot-n66.sh` adds `-display none` when `--ramfb off`
(the default) because the serial console is the reliable path. Pass
`--ramfb on` if you want to try the textual framebuffer.

## Legal note

The source downloaded by `build-qemu.sh` is GPL-2.0. XNU headers are APSL-2.0.
The iOS kernelcache, device tree, disk images, iBoot and userland are Apple
copyright and are not included or fetched by this repository. The upstream
fork modifies the guest kernel in memory to bypass CoreTrust; using it may
raise anti-circumvention issues in your jurisdiction. This harness is for
research on hardware and software you own. Do not redistribute Apple binaries
or modified images.
