# QEMU + apple-vfio

This is a fork of QEMU that adds **PCI passthrough on Apple Silicon Macs**
via a DriverKit system extension, packaged as a single macOS app
that bundles QEMU and the dext together.

The upstream QEMU README is preserved at [`README.upstream.rst`](README.upstream.rst).

This document covers building the macOS host app from source. Since, we have
not yet received the necessary entitlements from Apple, we cannot release
binaries of this project yet.

---

## Prerequisites

- **Apple Silicon Mac** running macOS 26 (Tahoe) or newer
- **Xcode 26.3+** with the macOS installed
- **An Apple Developer account**
- **A non-TB5 Thunderbolt device** like an eGPU enclosure. Keep in mind that newer Thunderbolt 5 enclosures **DO NOT WORK** correctly with Apple Silicon. Best to stick to an older Thunderbolt 4 or 3 enclosure.

## Configure the Xcode project for your Apple Developer team

Open the project:

```bash
open contrib/apple-vfio/VFIOUserHostApp.xcodeproj
```

Before building anything, make sure you've logged into Xcode with your Apple Developer account (Xcode -> Settings -> Apple Accounts), and that your computer is authorized


Then for **each** of the three targets — `VFIOUserHostApp`,
`VFIOUserPCIDriver`, and `qemu-vfio-apple`:

1. Select the target in the project navigator.
2. Go to **Signing & Capabilities**.
3. Change **Team** to your own team in the dropdown. Leave
   **Automatically manage signing** checked.
4. Update **Bundle Identifier**, replacing the `scottjg.` prefix with one
   registered to your team (e.g. `com.example.`). Keep the suffixes intact
   so the parent/child relationship between the app and dext is preserved:
   - `com.example.VFIOUserHostApp`
   - `com.example.VFIOUserHostApp.VFIOUserPCIDriver`
   - `com.example.VFIOUserHostApp.qemu-vfio-apple`

Build with **Product → Build** (⌘B). The app lands in
`~/Library/Developer/Xcode/DerivedData/VFIOUserHostApp-*/Build/Products/Debug/VFIOUserHostApp.app`

---

## Copy the app to /Applications

**This step is required.** macOS will not stage a DriverKit extension
unless its host app lives under `/Applications` (or another
system-managed location). The app contains an at-launch helper that
offers to move itself, but it deliberately skips that prompt for builds
running out of `DerivedData` so developers don't get nagged on every
rebuild.

So, after building in Xcode, manually copy the app:

1. In Xcode, right-click `VFIOUserHostApp.app` under **Products** and
   choose **Show in Finder**.
2. Drag `VFIOUserHostApp.app` into `/Applications`.
3. Launch it from `/Applications` (not from DerivedData).

If you skip this step, the dext won't load and the app's "Install
System Extension" button will fail silently or report an activation
error.

---

## First launch

On first launch from `/Applications`:

1. Select the option to install the system extension.
2. macOS shows a notification: **"System Extension Blocked"**. Open
   **System Settings → Privacy & Security**, scroll to the bottom, and
   click **Allow** next to the entry for `VFIOUserPCIDriver`.
3. Select the option to install the CLI tools.
4. You can quit the app.
5. Open a new terminal and run `qemu-vfio-apple driver-status` to verify the driver is installed
6. Run `qemu-vfio-apple list-devices` to confirm that your eGPU is recognized and the driver attached.
7. Run `qemu-vfio-apple run` to start the VM with your eGPU.
8. Sign into the Ubuntu user with the password 'ubuntu'

## Code layout

```
contrib/
├── apple-vfio/                          # macOS host app + dext + CLI launcher
│   ├── VFIOUserHostApp.xcodeproj/       # the Xcode project
│   ├── VFIOUserHostApp/                 # SwiftUI host app
│   ├── VFIOUserPCIDriver/               # DriverKit dext (C++/IIG)
│   ├── qemu-vfio-apple/                 # Swift CLI launcher embedded in the app
│   ├── scripts/                         # build-phase scripts and dist tooling
│   └── image-builder/                   # prebaked Ubuntu guest image pipeline
└── apple-dma/                           # guest-side DMA companion device driver
    ├── linux/                           # apple_dma Linux kernel module (DKMS)
```

QEMU-side changes for the Apple VFIO backend live under `hw/vfio/`
(`apple-device.c`, `container-apple.c`, `apple-dma.c`, etc.) and are
gated by `host_os == 'darwin'` in `hw/vfio/meson.build`.

`contrib/apple-dma/linux/` is required in the guest. Only the dext
can program the DART (Apple's IOMMU), so we ship a paravirtual PCI
device (`hw/vfio/apple-dma.c`) plus a matching DKMS kmod that hooks
`dma_map_ops` for passthrough devices and forwards each map/unmap to
QEMU over a doorbell-driven shared-memory ring; QEMU asks the dext to
update the DART. The prebaked image installs the kmod automatically;
BYO guests need to build and load it.
