# Preparing `hfs.main` and `hfs.sec`

The n66 machine's block-device driver exposes two raw HFS+ images. The upstream
procedure builds both from two files in the iOS 12.1 IPSW:

- `048-32651-104.dmg` — the restore ramdisk; `prepare-artifacts.py` decodes it
  to `048-32651-104.dmg.out`, which is a raw HFS+ disk image.
- `048-31952-103.dmg` — the update/system volume used to populate the main
  disk and `/private/var`.

This step is **not automated** here. It needs macOS `hdiutil`, HFS+ write
access, `jtool` for signing, and edits to Apple's `launchd`; the result contains
Apple code and must not be redistributed. The canonical instructions are the
upstream wiki:

<https://github.com/alephsecurity/xnu-qemu-arm64/wiki/Build-iOS-on-QEMU>

What that procedure does, in outline:

1. Decode the ramdisk with the ASN.1 IM4P helper:
   `asn1rdskdecode.py 048-32651-104.dmg 048-32651-104.dmg.out`.
2. Copy the decoded image to `hfs.main`, resize it to 6 GiB with
   `hdiutil resize -imagekey diskimage-class=CRawDiskImage`, and attach it.
3. Attach `048-31952-103.dmg` directly, empty the ramdisk volume, then
   `rsync` the system volume (`PeaceB16B92.N56N66OS`) onto it.
4. Add the unsigned tooling the upstream procedure uses (rootlessJB's
   `iosbinpack64`), the TCP tunnel binary, and four launch daemons: `bash`,
   `mount_sec`, `tcptunnel`, `dropbear`.
5. Replace `/etc/fstab` with the two-disk layout:
   `/dev/disk0 / hfs ro 0 1` and `/dev/disk1 /private/var hfs rw,nosuid,nodev 0 2`.
6. Remove `/private/var/*` from the main image (it moves to `hfs.sec`), remove
   `com.apple.mobile.keybagd.plist`, patch `sbin/launchd` in Ghidra, and re-sign
   it with `jtool`.
7. Eject the main image. That file is `hfs.main`.
8. Build `hfs.sec` the same way: copy the decoded ramdisk, resize to 6 GiB,
   empty it, `rsync` the main image's `/private/var` into it, and create a
   `dropbear` directory.
9. Eject both images. The resulting files are `hfs.main` and `hfs.sec`.

The upstream result reaches `launchd` and an interactive bash shell. The
console is on the serial port; SSH is available only through the custom TCP
tunnel on port 2222. There is no GUI, Wi-Fi, cellular or SEP.

If you have a Linux-only host, you still need a way to mount and write HFS+
images (`hfsprogs` / kernel HFS+ write support), plus a way to convert the
Apple UDIF system DMG (for example `dmg2img`). This repository deliberately
does not script those operations: they modify Apple binaries and signing state,
and the exact recipe is version-specific.

Put the final images in `host/firmware/`:

```bash
cp hfs.main hfs.sec host/firmware/
```

Then `./host/doctor.sh` should show all five required files as present. The
boot script checks for an `H+`/`HX` volume signature at offset 1024; a DMG or
an empty `dd` image will be rejected.

## Legal warning

The upstream procedure patches and re-signs `launchd` and disables signing
checks so the modified image can run. That may violate anti-circumvention law
in your jurisdiction even if you own the device. It is upstream research
documentation, not something this repository performs. Keep the images local,
do not commit them, and do not share them.
