# iosem

A legally constrained research project for running a **user-supplied iOS 12.1 kernel** under
QEMU, with an Android front-end for managing the required files.

> **Status.** The host-side n66 harness builds QEMU with the
> `iPhone6splus-n66-s8000` machine and can launch it with user-prepared files. The Android
> app now also bundles a cross-compiled QEMU backend for `arm64-v8a` and `x86_64`; on an
> API 30 x86_64 emulator it executes the packaged binary, lists the n66 machine, runs
> translated AArch64 code under TCG and reaches kernel loading. A real boot still requires
> the five user-supplied files (kernelcache, device tree, block driver, `hfs.main`,
> `hfs.sec`); neither harness has booted one here.

The project never contains or downloads Apple firmware. It can download Apple's open-source
XNU (APSL-2.0) and the GPL-2.0 `xnu-qemu-arm64` fork. Everything else — kernelcache,
device tree, HFS+ images, userland — is a user-supplied slot.

## What actually works

### Host n66 harness (`host/`)

- Builds the pinned Aleph `xnu-qemu-arm64` fork for `aarch64-softmmu` on Linux.
- Verifies that the resulting QEMU lists `iPhone6splus-n66-s8000`.
- Decodes a user's iOS 12.1 `kernelcache.release.n66` and `DeviceTree.n66ap.im4p` without
  pyasn1, and validates the decompressed Mach-O.
- Validates the five-file boot contract and prints or runs the exact machine command.
- Does **not** create the block-device driver or the HFS+ disk images; both are upstream
  procedures that modify Apple code. See [`host/DISKS.md`](host/DISKS.md).

### Android app (`app/`)

- Files tab with a download/import row per artifact, progress, SHA-256 and provenance.
- Legal gate that states what the app does not contain.
- Document-picker import into app-private storage under stable names.
- JNI probe reporting ABI, page size, CPU, RAM, KVM availability and slot presence.
- A packaged QEMU backend (`libqemu-system-aarch64.so`, an ELF executable extracted to
  `nativeLibraryDir`) with Start / Stop / Self-test / Check files and a serial console.
- `targetSdk = 28` so TCG keeps `execmem`; 16 KiB-aligned segments and a static libc++ so
  the same APK loads on 4 KiB and 16 KiB page kernels.
- Verified on an Android 11 `x86_64` emulator: the in-app Self-test returns
  `exit=0` / `machine listed: true`, TCG translates and executes AArch64 code, and Start
  opens the five artifact slots and enters kernel loading. With placeholder files it
  segfaults exactly as the host build does with the same placeholders.

The backend is a serial harness, not a usable phone: no GUI, touch, Wi-Fi, cellular or SEP.
There is no foreground service yet, so Android may kill the child when the app is
backgrounded.

## The target is narrower than "iOS in a box"

The only public machine model that gets close is Aleph Research's n66 fork. Its realistic
scope:

| item | reality |
| --- | --- |
| target | iOS 12.1, build 16B92, iPhone 6s Plus `n66` / `s8000` |
| boot path | QEMU loads a decoded Mach-O XNU kernel **directly**; no iBoot |
| kernel patches | hard-coded addresses for 16B92, applied in memory |
| result | launchd and a shell over serial or the upstream SSH tunnel; not a usable phone |
| GUI / touch / Wi-Fi / cellular / SEP | absent |
| acceleration | TCG on x86; no KVM for an AArch64 guest |
| guest RAM | 6 GiB in the upstream host procedure; the Android launcher requests half of physical RAM, clamped to 1–4 GiB |

The hard-coded patch addresses are why iOS 10/11 is not a supported shortcut. Supporting a
different build is reverse-engineering work, not a configuration flag. The upstream fork
also patches the kernel to bypass CoreTrust; that is research code with legal risk. Read
[`docs/LEGAL.md`](docs/LEGAL.md).

## Quick start: host harness

Build dependencies (Debian/Ubuntu):

```bash
sudo apt install build-essential flex bison libglib2.0-dev \
                 libpixman-1-dev zlib1g-dev libfdt-dev
```

No root? The repository can fetch a local compiler, flex/bison and libfdt
headers into `host/.build/`. You still need glib-2.0, pixman-1 and zlib
development files available for QEMU to configure.

```bash
./host/bootstrap-deps.sh
```

Then:

```bash
./host/build-qemu.sh
./host/doctor.sh
./host/selftest.sh
```

The build script downloads the pinned fork from GitHub (through `gh-proxy.com` by default;
set `IOSEM_GITHUB_PROXY=` for direct), pins the keycodemapdb commit, applies compatibility
fixes for modern keycodemapdb, and builds only `aarch64-softmmu`. It verifies the machine
appears in `-M help`.

`host/selftest.sh` builds synthetic IM4P/LZSS fixtures and checks the decoder,
the manifest, the boot-file validation and the dry-run command without touching
real firmware or booting QEMU. Run it after any change to the host scripts.

Prepare the files you own:

```bash
./host/prepare-artifacts.py \
  --ipsw ~/Downloads/iPhone_5.5_12.1_16B92_Restore.ipsw \
  --out host/firmware
```

Then add the three files the decoder cannot make:

```bash
cp aleph_bdev_drv.bin hfs.main hfs.sec host/firmware/
./host/boot-n66.sh --dry-run
./host/boot-n66.sh
```

See [`host/README.md`](host/README.md) for the driver build and the exact upstream image
procedure.

## Quick start: Android app

Requirements: Android Studio (or AGP 8.6.1 + Gradle 8.7 + **JDK 21**; AGP needs a full JDK
with `jlink`, not just a JRE), Android SDK 35, NDK 26.1.10909125 and CMake 3.22.1 installed
through the SDK manager.

Build the app alone with:

```bash
./gradlew :app:assembleDebug
```

That APK has **no QEMU backend**, because the cross-compiled binaries are not committed
(`app/src/main/jniLibs/` is gitignored). To get a working backend, build it first:

```bash
# pick the ABI you will run
export IOSEM_ABI=x86_64          # or arm64-v8a for a physical device
./host/fetch-android-deps.sh
./host/build-qemu-android.sh
./host/build-apk.sh
```

`build-qemu-android.sh` reuses the patched source tree produced by `host/build-qemu.sh`, so
run the host build once first. Open the folder in Android Studio and run on an `arm64-v8a`
device or an `x86_64` emulator. If you build from the command line, point Gradle at your SDK
in `local.properties`:

```properties
sdk.dir=/path/to/Android/Sdk
```

The GitHub Actions workflow builds `:app:assembleDebug` on every push and uploads it as
`iosem-debug-apk`. That artifact is deliberately **source-only** (no packaged backend);
use the local build above for an APK that can actually launch the machine.

## Boot-file contract

The host harness and the Android app use the same stable names:

| slot | file | required | source |
| --- | --- | --- | --- |
| kernelcache | `kernelcache.release.n66.out` | yes | decoded from your iOS 12.1 IPSW |
| device tree | `DeviceTree.n66ap.im4p.out` | yes | decoded from your iOS 12.1 IPSW |
| block driver | `aleph_bdev_drv.bin` | yes | built from `xnu-qemu-arm64-tools` + matching symbols |
| main disk | `hfs.main` | yes | prepared HFS+ image; see `host/DISKS.md` |
| secondary disk | `hfs.sec` | yes | prepared HFS+ image; see `host/DISKS.md` |
| ramdisk | `048-32651-104.dmg.out` | no | decoded restore ramdisk |
| XNU source | `xnu-<tag>.tar.gz` | no | Apple APSL-2.0 |
| n66 QEMU source | `xnu-qemu-arm64-<sha>.tar.gz` | no | GPL-2.0 fork |

Filling every slot is necessary but not sufficient. The kernel must be 16B92, the driver
must match its symbols, and the disk images must come from the same iOS build.

## Project layout

```
app/                     Android app (Kotlin, Compose, WorkManager)
  src/main/cpp/          JNI probe + CMake
  src/main/assets/       catalog.json
  src/main/java/dev/iosem/
    data/                catalog, store, download worker, legal gate
    ui/                  files / console / about screens
host/                    Linux n66 QEMU harness
  bootstrap-deps.sh      Debian/Ubuntu no-root dependency helper
  build-qemu.sh          pinned fork build + compatibility patches
  build-qemu-android.sh  cross-build the fork for Android (arm64/x86_64)
  package-qemu-android.sh  ELF renames + in-place DT_NEEDED rewrite
  fetch-android-deps.sh  Termux bionic runtime used at build time
  test-android-emulator.sh  headless emulator install + run-as check
  doctor.sh              host, backend and boot-file checks
  selftest.sh            synthetic decoder + dry-run checks; never boots
  prepare-artifacts.py   IM4P/DER + LZSS decoder; no firmware download
  boot-n66.sh            validated n66 command line
  DISKS.md               upstream hfs.main/hfs.sec procedure
core/README.md           backend contract and Android limits
docs/                    legality, feasibility, architecture
tools/                   XNU fetcher and artifact verifier
```

## Documentation

- [`host/README.md`](host/README.md) — build, file contract, driver, limitations.
- [`host/DISKS.md`](host/DISKS.md) — why the disk images are not automated.
- [`docs/FEASIBILITY.md`](docs/FEASIBILITY.md) — what real iOS requires, milestone by milestone.
- [`docs/LEGAL.md`](docs/LEGAL.md) — licensing, anti-circumvention, what the app refuses to do.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — components and backend contract.
- [`core/README.md`](core/README.md) — Android machine integration and TCG performance.

## Licence

The scaffold code in this repository is MIT (see `LICENSE`). XNU is APSL-2.0. QEMU and the
n66 fork are GPL-2.0; if you link and distribute them, the GPL applies to that distribution.
Apple firmware is not licensed for redistribution and is not part of this project.
