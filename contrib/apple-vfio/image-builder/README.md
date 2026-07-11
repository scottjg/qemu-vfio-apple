# Ubuntu Image Builder

This directory contains the prebaked guest-image pipeline for `apple-vfio`.

The goal is to produce versioned Ubuntu `qcow2` artifacts that can be
downloaded by the launcher CLI and booted with the QEMU runtime already
bundled into `VFIOUserHostApp`.

`build-image.sh` drives the pipeline and takes a profile:

```bash
./contrib/apple-vfio/image-builder/build-image.sh desktop   # the original desktop/gaming image
./contrib/apple-vfio/image-builder/build-image.sh docker    # headless Docker image
```

- **desktop** — Ubuntu Desktop + FEX/Steam + NVIDIA gaming stack
  (`build-ubuntu-desktop-image.sh` is a back-compat wrapper for this profile).
- **docker** — headless server image backing `qemu-vfio-apple docker up`:
  Docker Engine listening on unix socket + `tcp://0.0.0.0:2375` (safe:
  the guest sits on a private slirp network; only the host-side loopback
  hostfwd reaches it), NVIDIA driver + `nvidia-container-toolkit` (both
  the `nvidia` runtime for `--gpus all` and a boot-time CDI spec
  generator), Mesa Vulkan (RADV) + `vulkan-tools` for the AMD
  `--device /dev/dri` path, optional experimental ROCm behind
  `INSTALL_ROCM=1`, and the `apple-dma` DKMS module. Docker profile
  knobs: `INSTALL_NVIDIA` (default 1), `INSTALL_APPLE_DMA` (default 1),
  `INSTALL_ROCM` (default 0), `DISK_SIZE` (default `64G`).

Each profile embeds its own guest provisioning script
(`guest/provision-desktop.sh` / `guest/provision-docker.sh`) into the
cloud-init seed. `RENDER_ONLY=1 ./build-image.sh <profile>` renders the
seed and stops — useful when iterating on a guest script or the
template. When publishing a docker-profile artifact with
`scripts/publish-to-ghcr.sh`, pass the docker artifacts dir and
`ALSO_TAG_LATEST=0` so `:latest` keeps pointing at the desktop image.

## Current approach

This first iteration uses Ubuntu's official arm64 **cloud image** as the base
and then provisions it into a desktop image on first boot.

The current default target is Ubuntu 26.04 LTS (`resolute`, Resolute Raccoon)
for arm64.

That is a deliberate compromise:

- it matches the existing repo workflow in `scripts/make-geekbench-vm.sh`
- it is straightforward to automate under QEMU/HVF on macOS
- it preserves a UEFI/GPT bootable image layout
- it gives us a reproducible starting point for desktop customization

The long-term product can still switch to a Desktop-ISO-derived image if we
decide that provenance matters more than automation simplicity. For now, the
priority is to start generating a working prebaked image.

## What the builder does

`build-ubuntu-desktop-image.sh`:

1. downloads the official Ubuntu arm64 cloud image
2. creates a writable build disk on top of it
3. boots that disk under QEMU/HVF with a `cloud-init` seed
4. installs `ubuntu-desktop` and desktop-adjacent runtime packages
5. optionally enables extra provisioning hooks for FEX / Steam / NVIDIA /
   `apple-dma`
6. powers the guest off when provisioning completes
7. flattens the resulting disk into a compressed release-ready `qcow2`
8. writes a small JSON manifest next to the artifact

## Current scope

The initial provisioning flow is intentionally conservative:

- `ubuntu-desktop` is installed and configured as the default target
- `qemu-guest-agent` and a few desktop-friendly packages are added
- image cleanup is performed so the result behaves like a reusable golden image
- FEX is wired by default and ships with:
  - the official Ubuntu 24.04 RootFS extracted into a directory tree
  - a minimal `Config.json` enabling only the GL and Vulkan thunks
  - per-app overrides for the Steam `client` and `steamwebhelper`
- NVIDIA is wired by default: the latest `nvidia-driver-XXX(-open)` package is
  installed in the guest, and the matching x86_64 `.run` file is unpacked into
  the FEX RootFS so DLSS / NGX work for x86 binaries (Proton, etc.)
- `apple-dma` is wired by default: the kernel module sources from
  `contrib/apple-dma/linux/` are bundled into the cloud-init seed and
  registered with DKMS in the guest so the module gets rebuilt automatically
  on every kernel upgrade, with the upstream `modprobe.d` / `modules-load.d`
  configs installed for autoload at boot
- Steam is installed by default from Valve's official `steam_latest.deb`
  (`dpkg -i --force-all`) — the launcher runs natively on arm64 and FEX-Emu
  transparently emulates the x86_64 Steam bootstrap + steamwebhelper using
  the Ubuntu 24.04 FEX RootFS

This lets us start producing a real desktop artifact before we lock down the
rest of the guest stack.

## Requirements

- built QEMU binaries at either `dist/` or `build/`
- working arm64 firmware blobs in `build/pc-bios/`
- `python3`
- `curl`
- `hdiutil` (macOS)
- network access for Ubuntu packages during provisioning
- a QEMU build with `slirp` / `-netdev user` support for guest networking during the build

## Usage

From the repository root:

```bash
./contrib/apple-vfio/image-builder/build-ubuntu-desktop-image.sh
```

The default output directory is intended to be reused across runs. Re-running
the builder in `contrib/apple-vfio/image-builder/out/ubuntu-desktop-image`
replaces the transient work files and refreshes the default artifact in place.

To override defaults:

```bash
IMAGE_NAME=ubuntu-desktop-resolute-arm64 \
INSTALL_FEX=1 \
INSTALL_STEAM=1 \
INSTALL_NVIDIA=1 \
INSTALL_APPLE_DMA=1 \
./contrib/apple-vfio/image-builder/build-ubuntu-desktop-image.sh \
  contrib/apple-vfio/image-builder/out/ubuntu-desktop-image
```

Useful knobs:

- `IMAGE_NAME`: artifact basename
- `DISK_SIZE`: writable build disk size, default `96G`
- `CPUS`: builder vCPU count, default `8`
- `MEMORY`: builder RAM, default `12G`
- `BUILD_USER`: guest username, default `ubuntu`
- `BUILD_PASSWORD`: plaintext password set for `BUILD_USER` inside the guest
  during provisioning, default `ubuntu`
- `QEMU_DATA_DIR`: override the QEMU firmware/data directory passed via `-L`
- `EFI_CODE_SRC`: override path to `edk2-aarch64-code.fd`
- `EFI_VARS_SRC`: override path to `edk2-arm-vars.fd` or another arm64 vars file
- by default the builder now also checks `build/qemu-bundle/usr/local/share/qemu/`
  for those firmware blobs
- `INSTALL_FEX`: `1` by default
- `INSTALL_STEAM`: `1` by default
- `INSTALL_NVIDIA`: `1` by default
- `INSTALL_APPLE_DMA`: `1` by default
- `APPLE_DMA_SRC_DIR`: source dir tarred into the guest, default
  `contrib/apple-dma/linux`
- `APPLE_DMA_VERSION`: DKMS package version, default `0.1.0`

## Output

The output directory contains:

- `cache/`: downloaded base image
- `work/`: transient build artifacts and logs
- `artifacts/<image-name>.qcow2`: the flattened prebaked image
- `artifacts/<image-name>.manifest.json`: image metadata for the launcher

## Editing / re-sealing the finished image

Some first-run setup is GUI-only and not worth scripting — signing into
Steam the first time, right-clicking the desktop launcher and choosing
"Allow Launching", accepting a GNOME prompt, etc. Two helper scripts
let you do that manually and then turn the result back into a reusable
golden image:

```bash
./contrib/apple-vfio/image-builder/edit-image.sh
# click / type whatever you need; shut down from inside the VM.
./contrib/apple-vfio/image-builder/seal-image.sh
```

What each step does:

- `edit-image.sh`
  - One-time copy of `artifacts/<name>.qcow2` into
    `work/<name>.edit.qcow2` (re-run reuses the same scratch disk so
    iterative editing is cheap)
  - Boots the scratch disk under QEMU/HVF with a cocoa window,
    virtio-gpu, USB keyboard/mouse/tablet, and ssh forwarded to
    `127.0.0.1:2233` for convenience
  - Leaves the released artifact untouched — if an edit session goes
    wrong, delete `work/<name>.edit.qcow2` and start over
- `seal-image.sh`
  - Boots the same scratch disk headless
  - SSH'es in (password auth driven by `expect`, so no `sshpass`
    dependency) and runs `guest/seal-desktop.sh`, which wipes
    machine-specific state (ssh host keys, `/etc/machine-id`,
    cloud-init state, DHCP/NM leases, systemd random seed),
    clears caches (apt, journal, per-user `~/.cache` / history),
    runs `fstrim -av`, and issues `systemctl poweroff`
  - Waits for the guest to power off cleanly
  - `qemu-img convert -c -O qcow2` recompresses the scratch disk
    back into `artifacts/<name>.qcow2`, overwriting the original
  - Refreshes `artifacts/<name>.manifest.json` with the new
    sha256 / size_bytes and sets `"sealed": true`

The scratch disk is kept in `work/` after sealing, so the next
`edit-image.sh` run resumes from the sealed artifact unless you
delete it.

User-visible state that is deliberately preserved (edits you made
are the whole point of the workflow): Steam installs / logins, game
libraries, desktop launcher trust flags, GNOME/dconf tweaks, and
anything else under `/home/<BUILD_USER>` that isn't a cache or shell
history. `~/.cache/fex-emu/` is also preserved — it holds FEX's AOT
/ object cache, and keeping it means that if you launch Steam once
during an edit session (just enough to warm the JIT, then quit), the
sealed image ships with the warm cache and subsequent cold Steam
launches drop from ~60s to ~10-15s. If you want a strictly anonymous
snapshot, manually delete `~/.local/share/Steam` (or whatever else)
inside the edit session before you seal.

Useful knobs (on top of the ones documented above):

- `EDIT_SSH_PORT`: host port forwarded to guest sshd, default `2233`
- `SEAL_TIMEOUT`: seconds to wait for sshd-up and guest poweroff,
  default `600`
- `BUILD_USER` / `BUILD_PASSWORD`: must match whatever was set during
  the original build (defaults to `ubuntu` / `ubuntu`)

## Next steps

The next rounds of work should focus on:

- teaching the future launcher how to download and cache the published artifact
