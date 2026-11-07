# Feasibility

This document separates what is hard from what is impossible, and what is legal from what
is merely difficult. It is engineering analysis, not legal advice.

## Two different products share the name "iOS emulator"

1. **API-compatible clone.** Reimplement the frameworks and run recompiled apps. This is
   what people usually mean by "iOS emulator"; it is a fake system, and it is not what this
   project is.
2. **Full-system emulation.** Emulate the hardware and run the real, signed firmware. This
   is what "run real iOS" means. It requires the real boot chain and real Apple binaries.

This repository is aimed at (2) and refuses to ship the pieces that make (2) possible only
through redistribution of Apple code.

## The real boot chain

| stage | what it is | open source | redistributable | emulatable |
| --- | --- | --- | --- | --- |
| SecureROM / BootROM | mask ROM in the SoC | no | no | only by modelling the checks it performs |
| LLB / iBoot | Apple bootloader, signed | no | no | yes, if supplied by the user |
| Device Tree | Apple `DeviceTree` blob | no | no | yes, as data |
| kernelcache | XNU + prelinked kexts, signed | partly (XNU is APSL) | XNU yes, kexts no | yes, if supplied |
| SEP | Secure Enclave, separate core | no | no | not meaningfully |
| launchd / userspace | system volume, dyld cache | no | no | only with a matching system volume |
| AMFI / trust cache | code-signing enforcement | partly | no | cannot be bypassed legally |

XNU on ARM64 receives a `boot_args` pointer chain from iBoot. It expects an Apple Device
Tree and Apple platform drivers. There is no generic `virt` board support. That single fact
rules out "just run the open-source kernel under normal QEMU".

## What the closest public work achieves

Aleph Research's [`xnu-qemu-arm64`](https://github.com/alephsecurity/xnu-qemu-arm64):

- adds a custom QEMU machine (`iPhone6splus-n66-s8000`) that models enough of an A9 platform;
- **does not emulate BootROM or iBoot**; it loads a decoded Mach-O XNU kernel directly
  and patches hard-coded kernel addresses in memory;
- targets exactly iOS 12.1 build 16B92 (`kernelcache.release.n66`), because those patch
  addresses are build-specific;
- reaches launchd and an interactive bash shell over serial or the upstream SSH tunnel;
- requires a separate block-device driver and two prepared HFS+ images;
- requires roughly 6 GB of guest RAM;
- has no GUI, no App Store, no general networking, no SEP, no cellular, no usable phone.

This is why "use an older iOS" is not a shortcut: a different build means different patch
sites and a different machine model. The host harness in `host/` reproduces the public 16B92
milestone; it does not add support for iOS 10 or 11.

A separate experiment boots a macOS Apple Silicon kernel under QEMU `virt` with a modified
device tree and reaches `launchd`, described by its author as "completely useless". Both are
research artifacts, not products.

## Android-specific constraints

| constraint | consequence |
| --- | --- |
| No `/dev/kvm`, no EL2 | QEMU must use TCG (binary translation). Roughly 5–20% of native. |
| App memory limits, even with `largeHeap` | a 6 GB guest is not realistic on most phones; expect 1–2 GB and a kernel-only boot. |
| Thermal throttling | sustained TCG load throttles within minutes. |
| No raw block devices | disk images must be file-backed inside app storage. |
| Foreground service limits | long downloads need `dataSync`; long VM runs need a persistent notification. |
| SELinux / seccomp | no arbitrary device access, no custom kernel modules. App seccomp blocks `signalfd`/`signalfd4`, so the backend must be built with `CONFIG_SIGNALFD` off; otherwise it dies with `SIGSYS`. |
| W^X / `execmem` | TCG needs executable anonymous memory; apps targeting API 29+ are denied it. This build targets API 28, like Termux, and TCG has been observed translating and running AArch64 code in the app domain. |
| 16 KiB page devices | handled: the executable is linked with `-Wl,-z,max-page-size=16384`, libc++ is static, and the Termux libraries are already 16 KiB-aligned. |

A phone that can host the *files* is not a phone that can host the *machine*. The Android
backend now exists and has been run on an x86_64 API 30 emulator: the app executes it from
`nativeLibraryDir`, lists the n66 machine, runs translated code under TCG, and enters
kernel loading. What it cannot do is conjure the five Apple files, or give a 6 GB guest
enough RAM on a phone.

The two Android-specific bugs found during that test are documented because they are not
obvious: patchelf relocates `PT_INTERP` on large executables and the kernel then rejects
the binary with `EINVAL`, and the app seccomp policy kills QEMU with `SIGSYS` on
`signalfd`.

## Milestones if someone continues this

**M0 — artifact pipeline (this repository).** Download XNU source; import firmware slots;
verify names, sizes, container magic and hashes; gate boot on completeness.

**M1 — host-side kernel boot.** On a Linux host, use `xnu-qemu-arm64` to boot a user's
iPhone 6s-class image to a shell. This validates the artifact set without Android in the
loop. The harness is in [`host/`](../host/README.md): it builds the pinned fork, decodes
the kernel/device tree, and launches the n66 machine. It is blocked only by Apple files the
user must supply, plus the upstream disk-preparation and driver-build steps.

**M2 — cross-build the backend (done).** `host/build-qemu-android.sh` builds QEMU
`aarch64-softmmu` for Android with the n66 machine, and
`host/package-qemu-android.sh` rewrites the dependency closure into flat `.so`
names with `$ORIGIN` RUNPATH. The launcher runs it from `nativeLibraryDir` and
streams the serial console. It is a separate process, not an in-process JNI
backend, because QEMU assumes it owns the process.

**M3 — framebuffer.** Present the guest framebuffer into an `ANativeWindow`. Expect a
slideshow; do not promise interaction. Not started.

**M4 — storage.** File-backed root filesystem, snapshot/rollback, no writes outside app
storage.

**M5 — honesty pass.** Publish a compatibility matrix per board/build, with measured boot
times and a clear "kernel only / shell only / no userspace" status.

## Verdict

- **Run real iOS userland on Android:** not achievable today, and not legally distributable
  even if it were. SEP, AMFI and the signed system volume are the blockers, not CPU
  emulation.
- **Boot real XNU from a user's own kernelcache to a shell on a Linux host:** achievable,
  research-grade, slow, and now implemented in `host/` for the public n66 target. It
  patches the guest kernel in memory and bypasses CoreTrust, so it is not a clean-room
  signed boot and may be legally restricted.
- **Do the same on an Android phone:** the backend now exists and is packaged, including
  16 KiB-page support. It is still blocked by the user-supplied Apple files and, on most
  phones, the memory budget. The serial console is the only interface. The artifact
  manager, launcher and QEMU self-test are the parts that work today.
- **Ship a clean artifact manager and a documented backend contract:** the app now also
  ships a GPL-2.0 QEMU backend built from pinned source, with license notices in
  `app/src/main/assets/licenses/`.
