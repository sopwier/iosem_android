# native core

## Current state

`app/src/main/cpp/native_core.cpp` compiles to `libiosem_core.so` and exposes
three JNI methods:

| method | behaviour |
| --- | --- |
| `version()` | build string |
| `capabilities()` | ABI, page size, CPU count, RAM, KVM availability, backend status |
| `probeBoot(dir)` | checks the five required slots plus the optional ramdisk and prints sizes; executes nothing |

There is no machine emulator in the Android app. The working reference
implementation is the host harness in `host/`; the Start button points there
and here.

## Why a machine model is required

XNU's ARM64 port is not a generic kernel. At entry it expects Apple's
`boot_args` structure, an Apple Device Tree blob, and a platform that provides
Apple's interrupt controller, timers, and platform kexts. QEMU's `-M virt`
does not satisfy that contract; patching XNU until it does means you are no
longer booting iOS's kernel, just a XNU-shaped kernel.

The public work that gets closest is Aleph Research's `xnu-qemu-arm64`: a QEMU
fork with an `iPhone6splus-n66-s8000` machine that models enough of an A9
platform to load a **decoded Mach-O XNU kernel directly**. It does not emulate
BootROM or iBoot. It patches hard-coded iOS 12.1 build 16B92 kernel addresses
in memory, uses a separately compiled block driver plus two HFS+ images, and
reaches launchd and a bash shell over serial or the upstream SSH tunnel. It is
not a usable phone and needs roughly 6 GB of guest RAM.

## Wiring a backend

1. Build QEMU `aarch64-softmmu` for Android `arm64-v8a`.
   QEMU is GPL-2.0; if you ship the resulting binary you must publish the
   corresponding source. A glib/pixman cross-build for the NDK is the hard
   part; most people build inside a Linux container with the NDK toolchain and
   link statically. The host harness in `host/` is the build recipe to port.
2. Add the machine model. Reuse the `xnu-qemu-arm64` fork's
   `iPhone6splus-n66-s8000` source (`hw/arm/n66_iphone6splus.c` and its
   dependencies) or write a smaller model that only covers early boot.
3. Drop the resulting `libqemu-system-aarch64.so` (plus any dependencies) into
   `app/src/main/jniLibs/arm64-v8a/`.
4. Extend `NativeCore` with:

   ```kotlin
   external fun start(configJson: String): Int
   external fun stop()
   external fun logFd(): Int
   ```

   `configJson` must carry the five n66 paths (`kernelcache.release.n66.out`,
   `DeviceTree.n66ap.im4p.out`, `aleph_bdev_drv.bin`, `hfs.main`, `hfs.sec`),
   the kernel command line and RAM size. Keep firmware paths and bytes out of
   logs.
5. Render the guest framebuffer into an `ANativeWindow` surface. Until then,
   a serial-only console is the honest target.

A 6 GiB guest is not realistic on most phones. A smaller `-m` value may get
through early kernel boot, but the public image procedure assumes 6 GiB. Test
on a host first; do not promise phone-sized iOS.

## Performance reality

Android apps cannot open `/dev/kvm` or run at EL2, so QEMU falls back to TCG.
Expect single-digit to low-double-digit percentages of native speed. Booting a
kernel to `launchd` will take minutes, and a graphical userspace is not
interactive. Combined with the 6 GiB guest requirement, this is why the host
harness is the realistic first target, not an Android phone.

## Legal boundary

Never commit, bundle or auto-download iBoot, kernelcache, device trees or
userland. The app accepts files the user selects and stores them in its private
directory. See `docs/LEGAL.md`.
