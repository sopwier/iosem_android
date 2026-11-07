# Legal

Not legal advice. Read the licences and, for anything commercial, talk to a lawyer.

## What this repository contains

- Original MIT-licensed scaffold code (UI, file store, download worker, JNI probe) and
  host-side build/boot scripts.
- A catalogue that points at **Apple's own XNU source release** (APSL-2.0) and the
  **Aleph xnu-qemu-arm64 fork** (GPL-2.0). Both source trees are fetched at runtime or by a
  host script, not bundled.
- A **cross-compiled QEMU binary** in `app/src/main/jniLibs/` (`libqemu-system-aarch64.so`
  and its bundled shared libraries). This binary is built by `host/build-qemu-android.sh`
  from the same pinned GPL-2.0 fork and from Termux-packaged LGPL/MIT/BSD libraries.
  `app/src/main/assets/licenses/` carries the notices for every bundled ELF.
- No Apple firmware, no iBoot, no kernelcache, no device tree, no dyld shared cache, no
  SEP firmware, no signing keys, no decryption code, no jailbreak code.
- No IPSW download links and no firmware acquisition. `host/prepare-artifacts.py` only
  decodes files the user already has, and `host/DISKS.md` links to the upstream macOS
  procedure instead of automating it.

## XNU

XNU is published by Apple under the **Apple Public Source License 2.0**. The licence grants
rights to use, reproduce, modify and distribute the source and executable forms, subject to
conditions: keep the notices, include the licence, make source available for distributed
binaries and modifications, and comply with the patent and termination terms. Read the
`LICENSE` file in the XNU tree you download; do not assume MIT-style freedom.

The XNU source is not a bootable iOS image. Building it needs a macOS host and Apple's
toolchain, and the result still expects Apple's platform.

## Apple firmware and the rest of an IPSW

Everything else in an IPSW — iBoot, kernelcache-wrapped kexts, device trees, the system
volume, the dyld shared cache, SEP firmware — is Apple copyright. Apple does not license it
for redistribution. Copying it into a repository, an APK, a container image or a download
server is infringement in most jurisdictions, regardless of whether the emulator itself is
legal.

Signed components add a second layer: extracting, decrypting or bypassing signature checks
can violate anti-circumvention provisions (DMCA §1201 in the US, the EUCD and national
equivalents elsewhere), even when you own the device.

The public n66 fork is not a clean signed boot: its machine model patches the guest kernel
in memory to bypass CoreTrust, and its documented image procedure patches and re-signs
`launchd`. This repository does not implement those patches, but `host/build-qemu.sh`
downloads and runs the upstream fork. Treat the host harness as research on hardware you
own, not as a distribution-ready product, and do not redistribute the modified Apple
images. If you need a clean-room signed boot, this is not it.

## Bundled QEMU binary (GPL-2.0)

The Android APK contains QEMU built from the Aleph `xnu-qemu-arm64` fork, whose commit
`2694993f9281a8678d519704c3cd29d4c9d39415` is pinned in `host/build-qemu.sh`. QEMU is
GPL-2.0-or-later, so distributing an APK that contains it means you must also make the
**corresponding source** available to the recipients, including your modifications.

This repository does that by construction: `host/build-qemu-android.sh` reproduces the
binary from the pinned upstream tarball (SHA-256 pinned), the portability patch to
`util/qemu-openpty.c` is applied in the script itself, and the packaging step
(`host/package-qemu-android.sh`) only rewrites ELF headers. If you ship a modified binary,
publish the modified source alongside it.

Bundled dependencies and their licences are listed in
`app/src/main/assets/licenses/NOTICE.txt`; full texts are in the same directory.

## Emulators are not the same as firmware

US case law (Sony v. Connectix, Sony v. Bleem) has treated emulation as fair use in some
circumstances. That protects the emulator, not the distribution of the platform's firmware,
and not circumvention. A clean emulator that accepts user-supplied images is a very
different legal object from an app with an IPSW inside it. This repository is deliberately
the former.

## What the app does with your files

- The document picker gives the app read access to one file you choose.
- The file is copied into the app's private storage under a stable name.
- Its SHA-256, size and origin are recorded locally.
- Nothing is uploaded. There is no analytics and no telemetry.
- Removing the artifact deletes the copy.
- The host scripts read the paths you pass and write only to `host/firmware/` and
  `host/.build/`; no firmware is uploaded.

## Your obligations

- Only import firmware from hardware you own.
- Do not redistribute extracted firmware, in whole or in part.
- Do not use the project to bypass signing, AMFI, the trust cache or the SEP.
- If you distribute a build that links QEMU, comply with GPL-2.0 and publish the
  corresponding source for the QEMU components you ship.
- If you distribute a build that includes XNU binaries, comply with APSL-2.0.

## Takedown posture

If you fork this and add firmware downloads, extraction, decryption or signing bypasses, you
are on your own. That is not what the code or the documentation does, and the project name
should not be used to imply otherwise.
