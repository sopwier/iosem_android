# Architecture

## Shape

The repository has two halves:

- `app/` — the Android artifact manager and UI. No machine backend is linked.
- `host/` — a working Linux harness for the public n66 QEMU machine. It is the reference
  implementation of the file contract an Android backend must reuse.

```
┌──────────────────────────── Android app (Kotlin / Compose) ────────────────────────────┐
│                                                                                        │
│  LegalStore ──► LegalScreen ──► IosemRoot ──► Files / Console / About                  │
│                                    │                                                   │
│                                    ▼                                                   │
│                              SetupViewModel                                            │
│                        ┌───────────┴────────────┐                                       │
│                        ▼                        ▼                                       │
│                  Catalog (assets)         ArtifactStore (filesDir/artifacts)           │
│                        │                        ▲                                       │
│          ┌─────────────┴─────────────┐          │                                       │
│          ▼                           ▼          │                                       │
│   DownloadWorker (WorkManager)   Document picker ──► import copy ──► adopt()            │
│   open-source archives only                                             │              │
│                                                                         ▼              │
│                                                              index.json (hashes)       │
│                                                                                        │
│  NativeCore (JNI) ◄── Files/Console ──► libiosem_core.so (probe only)                  │
└────────────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼  (future, not linked)
                              QEMU aarch64-softmmu + n66 machine model
```

The host harness bypasses the Android app:

```
host/build-qemu.sh ──► pinned xnu-qemu-arm64 ──► qemu-system-aarch64
                                                        │
host/prepare-artifacts.py ──► host/firmware/ ───────────┤
  kernelcache.release.n66.out                           │
  DeviceTree.n66ap.im4p.out                             │
  aleph_bdev_drv.bin (user built)                       │
  hfs.main, hfs.sec (user prepared)                     ▼
                                              iPhone6splus-n66-s8000
                                              (direct kernel load; launchd + bash
                                               over serial or the SSH tunnel)
```

## Components

### `data/Catalog`
Reads `assets/catalog.json`. A catalogue entry is either a `Download` (upstream open-source
archive) or a `UserImport` (a slot the user must fill). Adding an artifact is a data change,
not a UI change.

### `data/ArtifactStore`
Flat directory plus an `index.json`. Stable file names are the contract with any future
backend. `adopt()` moves a temp file in, hashes it and records provenance. `remove()`
deletes both the file and the index entry.

### `data/DownloadWorker`
A `CoroutineWorker` that streams a URL to app cache, reports percentage progress, verifies
an optional SHA-256, then adopts the file. It enters the foreground with `dataSync` when
allowed. Network is constrained to `CONNECTED`. It refuses non-2xx responses and empty
bodies.

### `ui/SetupViewModel`
Owns the `UIState` list and the state machine:

```
MISSING ──download──► DOWNLOADING ──success──► READY
   │                       └──failure──► FAILED
   ├──import──► IMPORTING ──success──► READY
   │                       └──failure──► FAILED
   └──remove──────────────────────────► MISSING
```

`refresh()` reconciles the store with the UI, so an artifact that survives a process death
appears as `READY` on the next launch. WorkManager flows drive progress without polling.

### `core/NativeCore`
Three JNI calls: `version`, `capabilities`, `probeBoot`. It exists to prove the NDK path and
to make the device constraints visible (ABI, page size, RAM, KVM absence). It never executes
guest code.

### Legal gate
`LegalStore` stores one boolean. The gate is deliberately explicit: the app says what it
does not contain before it shows the file list. It is not a licence click-wrap and does not
pretend to be legal cover.

## Artifact catalogue schema

```json
{
  "id": "kernelcache",
  "name": "Kernelcache (decoded)",
  "summary": "kernelcache.release.n66.out from your iOS 12.1 IPSW.",
  "detail": "longer explanation shown in the card",
  "kind": "kernelcache",
  "required": true,
  "fileName": "kernelcache.release.n66.out",
  "license": "Apple copyright — user supplied",
  "approxBytes": 40000000,
  "source": {
    "type": "import",
    "mimeTypes": ["*/*"],
    "hint": "Output of host/prepare-artifacts.py"
  }
}
```

For a download, `source` is:

```json
{ "type": "download", "url": "https://…", "sha256": "optional lowercase hex" }
```

`fileName` is the on-disk name. Keep it stable: the probe and any future machine model look
files up by name.

## Storage

```
filesDir/artifacts/
  index.json                 provenance: fileName, size, addedAt, origin, sha256
  kernelcache.release.n66.out
  DeviceTree.n66ap.im4p.out
  aleph_bdev_drv.bin
  hfs.main
  hfs.sec
  048-32651-104.dmg.out     (optional ramdisk)
  xnu-<tag>.tar.gz
  xnu-qemu-arm64-<sha>.tar.gz
```

The host harness uses the same file names under `host/firmware/`.

Nothing leaves the app's private directory. There is no shared-storage permission, no
network upload path and no analytics dependency.

## Backend contract (future)

`core/README.md` defines the intended JNI surface:

```kotlin
external fun start(configJson: String): Int
external fun stop()
external fun logFd(): Int
```

`configJson` should carry artifact paths, board id, kernel command line, RAM size and a
framebuffer request. Keep firmware bytes out of logs and crash reports. A backend must never
shell out to an external binary: everything runs inside the app sandbox.

## Failure modes to design for

- **Wrong board or build.** The n66 machine is hard-coded for iOS 12.1 16B92. A kernel or
  device tree from another build will not hit the patch addresses. The UI cannot validate
  pairing; say so instead of implying success.
- **Truncated import.** Hashing on adopt catches most of it; the probe reports size.
- **Process death during download.** WorkManager restarts the unique work; the temp file is
  discarded and re-fetched.
- **Storage pressure.** A root filesystem image can be several GB. Check free space before
  adopting and fail with a clear message.
- **Thermals.** Any TCG run will throttle. Surface elapsed time and CPU state rather than
  hiding it.
- **Overclaiming.** The single most important failure mode for this project is implying that
  a filled checklist means iOS boots. It does not.
