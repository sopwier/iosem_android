# tools

Host-side helpers. They never download Apple firmware.

| script | purpose |
| --- | --- |
| `fetch_xnu.py` | Fetch Apple's APSL-2.0 XNU source tarball from the official mirror, with progress, SHA-256 and a license sanity check. |
| `verify_artifacts.py` | Inspect a directory of user-supplied n66 boot files (names, sizes, container magic, hashes). |

```bash
python3 tools/fetch_xnu.py --list-tags
python3 tools/fetch_xnu.py --tag xnu-4903.221.2 --out ~/Downloads/xnu.tar.gz
python3 tools/verify_artifacts.py host/firmware --strict
```

`verify_artifacts.py` expects the five-file contract used by
`host/boot-n66.sh` and the Android catalogue:

```
kernelcache.release.n66.out   required   decoded Mach-O kernel (iOS 12.1 16B92)
DeviceTree.n66ap.im4p.out     required   decoded Apple device tree
aleph_bdev_drv.bin            required   built from xnu-qemu-arm64-tools
hfs.main                      required   prepared HFS+ system volume
hfs.sec                       required   prepared HFS+ /private/var
048-32651-104.dmg.out         optional   decoded restore ramdisk
```

It reports the format of each file but cannot prove the set boots: the kernel
must be 16B92 and the driver and disk images must match it. Producing the
kernel and device tree is `host/prepare-artifacts.py`; the rest is documented
in `host/README.md` and `host/DISKS.md`.
