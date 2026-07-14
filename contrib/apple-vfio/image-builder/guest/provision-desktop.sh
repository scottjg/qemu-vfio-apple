#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

INSTALL_FEX="${INSTALL_FEX:-1}"
INSTALL_STEAM="${INSTALL_STEAM:-1}"
INSTALL_NVIDIA="${INSTALL_NVIDIA:-1}"
INSTALL_APPLE_DMA="${INSTALL_APPLE_DMA:-1}"

# Debug kernel cmdline params.  Default on because this image is used for
# eGPU-passthrough development and we want any guest-side memory
# corruption (e.g. stale DMA writes from a leaked DART entry) to surface
# loudly instead of silently zeroing PTEs in freed pages.
#
#   page_poison=1   freed pages are filled with 0xAA; the page allocator
#                   verifies the pattern on the next alloc and triggers
#                   "BUG: Bad page state" if anything has scribbled in
#                   the meantime.  This is the key knob for catching the
#                   apple_dma "stale DART entry into freed page" failure
#                   mode that we've been chasing.
#   panic=10        auto-reboot 10s after a panic so we don't lose the
#                   guest console waiting for a manual reset.
ENABLE_DEBUG_KERNEL_PARAMS="${ENABLE_DEBUG_KERNEL_PARAMS:-0}"

APPLE_DMA_VERSION="${APPLE_DMA_VERSION:-0.1.0}"
APPLE_DMA_SRC_TGZ="${APPLE_DMA_SRC_TGZ:-/var/cache/qemu-vfio/apple-dma-src.tgz}"

NVIDIA_DRIVER_VERSION=""

LOGIN_USER="${LOGIN_USER:-ubuntu}"
LOGIN_PASSWORD="${LOGIN_PASSWORD:-ubuntu}"

log() {
    printf '[qemu-vfio-image] %s\n' "$*"
}

warn() {
    printf '[qemu-vfio-image] warning: %s\n' "$*" >&2
}

finish() {
    local rc="$?"

    if [ "$rc" -ne 0 ]; then
        warn "provisioning failed"
        mkdir -p /var/lib/qemu-vfio
        printf '{"ok": false}\n' > /var/lib/qemu-vfio/image-ready.json || true
        sync || true
        systemctl poweroff --no-block || true
        exit "$rc"
    fi
}

trap finish EXIT

retry() {
    local attempts="$1"
    shift
    local i
    for ((i = 1; i <= attempts; i++)); do
        if "$@"; then
            return 0
        fi
        if [ "$i" -lt "$attempts" ]; then
            sleep 5
        fi
    done
    return 1
}

install_first_boot_finalizer() {
    log "installing first-boot finalizer"

    cat > /usr/local/sbin/qemu-vfio-firstboot-finalize.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p /var/lib/qemu-vfio

if [ ! -s /etc/machine-id ]; then
    systemd-machine-id-setup
fi

if ! compgen -G '/etc/ssh/ssh_host_*' >/dev/null; then
    ssh-keygen -A
fi

touch /var/lib/qemu-vfio/first-boot-complete
systemctl try-restart ssh.service || true
EOF
    chmod 0755 /usr/local/sbin/qemu-vfio-firstboot-finalize.sh

    cat > /etc/systemd/system/qemu-vfio-firstboot.service <<'EOF'
[Unit]
Description=Finalize qemu-vfio image on first boot
ConditionPathExists=!/var/lib/qemu-vfio/first-boot-complete
After=local-fs.target systemd-machine-id-commit.service
Before=multi-user.target graphical.target ssh.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/qemu-vfio-firstboot-finalize.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
WantedBy=graphical.target
EOF

    systemctl daemon-reload || true
    systemctl enable qemu-vfio-firstboot.service || true
}

log "ensuring login user '$LOGIN_USER' exists with the requested password"
if ! id -u "$LOGIN_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$LOGIN_USER"
fi
usermod --shell /bin/bash "$LOGIN_USER"
printf '%s:%s\n' "$LOGIN_USER" "$LOGIN_PASSWORD" | chpasswd
passwd -u "$LOGIN_USER" || true
chage -E -1 -M -1 -I -1 "$LOGIN_USER" || true

mkdir -p /etc/sudoers.d
cat > "/etc/sudoers.d/90-qemu-vfio-${LOGIN_USER}" <<EOF
${LOGIN_USER} ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 "/etc/sudoers.d/90-qemu-vfio-${LOGIN_USER}"

log "updating apt metadata"
retry 5 apt-get update

log "installing Ubuntu Desktop"
#
# linux-firmware is not present in the cloud image and is not pulled in by
# ubuntu-desktop.  Without it amdgpu fails early_init for every IP block that
# needs a blob (psp, smu, gfx, sdma, vcn) with -ENOENT and the passed-through
# GPU never comes up.
#
retry 3 apt-get install -y \
    ubuntu-desktop \
    linux-firmware-amd-graphics linux-firmware-intel-graphics \
    qemu-guest-agent \
    spice-vdagent \
    mesa-utils \
    software-properties-common \
    ubuntu-drivers-common \
    curl \
    wget

log "switching to NetworkManager"
rm -f /etc/netplan/50-cloud-init.yaml /etc/netplan/00-installer-config*.yaml
cat > /etc/netplan/01-network-manager-all.yaml <<'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
netplan generate || true
systemctl enable NetworkManager.service || true
systemctl disable systemd-networkd.service systemd-networkd.socket \
    systemd-networkd-wait-online.service || true
systemctl mask systemd-networkd.service systemd-networkd.socket \
    systemd-networkd-wait-online.service || true

log "setting graphical target and splash boot"
systemctl set-default graphical.target || true

#
# Set the kernel cmdline via a /etc/default/grub.d/ drop-in so we win
# against the cloud-image's /etc/default/grub.d/50-cloudimg-settings.cfg,
# which is sourced after /etc/default/grub and would otherwise clobber any
# edit we make there.  Files in /etc/default/grub.d/ are sourced in
# alphabetical order; 99-qemu-vfio-cmdline.cfg sorts last and wins.
#
# Keep console=ttyS0 in addition to tty1: when a kernel panic happens we
# want the trace on the QEMU serial port, not just the in-VM framebuffer.
#
KERNEL_CMDLINE_DEFAULT="console=tty1 console=ttyS0 quiet splash"
if [ "$ENABLE_DEBUG_KERNEL_PARAMS" = "1" ]; then
    KERNEL_CMDLINE_DEFAULT="$KERNEL_CMDLINE_DEFAULT page_poison=1 panic=10"
fi
log "setting kernel cmdline via grub.d drop-in: $KERNEL_CMDLINE_DEFAULT"
install -d -m 0755 /etc/default/grub.d
cat > /etc/default/grub.d/99-qemu-vfio-cmdline.cfg <<EOF
# Written by qemu-vfio image-builder (provision-desktop.sh).
# Sources later than 50-cloudimg-settings.cfg, so this wins.
GRUB_CMDLINE_LINUX_DEFAULT="${KERNEL_CMDLINE_DEFAULT}"
EOF
update-grub || true

log "removing clearly server-specific packages"
apt-get remove -y \
    ubuntu-server \
    ubuntu-server-minimal \
    byobu \
    landscape-common \
    lxd-agent-loader \
    motd-news-config || true
apt-get autoremove -y || true

purge_older_kernels() {
    set +e
    local running_kver all_kvers latest kv candidates installed
    running_kver="$(uname -r)"
    all_kvers="$(dpkg-query -W -f='${Package}\n' \
        'linux-image-[0-9]*-generic' \
        'linux-image-unsigned-[0-9]*-generic' \
        2>/dev/null \
        | sed -E 's/^linux-image-(unsigned-)?//' \
        | sort -u)"
    if [ -z "$all_kvers" ]; then
        warn "no linux-image-*-generic packages found; nothing to prune"
        set -e
        return 0
    fi
    latest="$(printf '%s\n' "$all_kvers" | sort -V | tail -1)"
    log "kernels installed: $(printf '%s' "$all_kvers" | tr '\n' ' '); latest=$latest, running=$running_kver"
    for kv in $all_kvers; do
        if [ "$kv" = "$latest" ]; then
            continue
        fi
        if [ "$kv" = "$running_kver" ]; then
            log "purging running kernel $kv (safe here: all installs are done, reboot will land on $latest)"
        fi
        candidates="linux-image-$kv linux-image-unsigned-$kv linux-modules-$kv linux-modules-extra-$kv linux-headers-$kv linux-tools-$kv linux-cloud-tools-$kv linux-buildinfo-$kv"
        installed="$(dpkg-query -W -f='${Package}\n' $candidates 2>/dev/null | tr '\n' ' ')"
        if [ -z "$installed" ]; then
            log "kernel $kv: no matching packages installed, skipping"
            continue
        fi
        log "purging older kernel $kv: $installed"
        update-initramfs -d -k "$kv" >/dev/null 2>&1
        apt-get purge -y $installed
        if [ "$?" -ne 0 ]; then
            warn "apt-get purge failed for kernel $kv"
        fi
        rm -rf "/lib/modules/$kv" "/var/lib/dkms/"*"/$kv" 2>/dev/null
        rm -f "/boot/vmlinuz-$kv" "/boot/initrd.img-$kv" \
            "/boot/System.map-$kv" "/boot/config-$kv" \
            "/var/lib/initramfs-tools/$kv" 2>/dev/null
    done
    apt-get autoremove -y --purge
    log "post-prune /lib/modules: $(ls /lib/modules 2>/dev/null | tr '\n' ' ')"
    set -e
}

user_home_dir() {
    getent passwd "$1" | cut -d: -f6
}

install_fex_rootfs_for_user() {
    local target_user="$1"
    local home_dir
    home_dir="$(user_home_dir "$target_user")"
    if [ -z "$home_dir" ] || [ ! -d "$home_dir" ]; then
        warn "FEX RootFS skipped: home dir for '$target_user' not found"
        return 1
    fi

    local fex_share_dir="$home_dir/.local/share/fex-emu"
    local rootfs_dir="$fex_share_dir/RootFS"
    local config_dir="$home_dir/.config/fex-emu"
    local appconfig_dir="$config_dir/AppConfig"
    local sqsh_path="$rootfs_dir/Ubuntu_24_04.sqsh"
    local extracted_dir="$rootfs_dir/Ubuntu_24_04"
    local sqsh_url="https://rootfs.fex-emu.gg/Ubuntu_24_04/2025-12-27/Ubuntu_24_04.sqsh"

    install -d -o "$target_user" -g "$target_user" -m 0755 \
        "$home_dir/.config" \
        "$home_dir/.local" \
        "$home_dir/.local/share" \
        "$fex_share_dir" \
        "$rootfs_dir" "$config_dir" "$appconfig_dir" \
        "$fex_share_dir/Server" \
        "$fex_share_dir/Telemetry"

    log "downloading FEX Ubuntu 24.04 RootFS for $target_user"
    if ! curl -fL --retry 5 --retry-delay 5 --progress-bar \
            -o "$sqsh_path.tmp" "$sqsh_url"; then
        rm -f "$sqsh_path.tmp"
        warn "FEX RootFS download failed; FEX will not be preconfigured"
        return 1
    fi
    mv "$sqsh_path.tmp" "$sqsh_path"

    log "extracting FEX RootFS to $extracted_dir"
    rm -rf "$extracted_dir"
    if ! unsquashfs -d "$extracted_dir" "$sqsh_path" >/dev/null; then
        warn "unsquashfs failed; FEX RootFS will be left as a squashfs"
        chown -R "$target_user":"$target_user" "$config_dir" "$fex_share_dir"
        return 1
    fi
    rm -f "$sqsh_path"

    log "writing minimal FEX Config.json for $target_user"
    cat > "$config_dir/Config.json" <<'JSON'
{"Config":{"RootFS":"Ubuntu_24_04"},"ThunksDB":{"GL":1,"Vulkan":1}}
JSON

    log "writing FEX AppConfig overrides for steamwebhelper and client"
    cat > "$appconfig_dir/steamwebhelper.json" <<'JSON'
{"Config":{"HideHypervisorBit":"1","Multiblock":"0"}}
JSON
    cat > "$appconfig_dir/client.json" <<'JSON'
{"Comment":"Bypasses libGL's glX and instead sends GLX requests directly via xcb","ThunksDB":{"GL":0}}
JSON

    chown -R "$target_user":"$target_user" "$config_dir" "$fex_share_dir"
    return 0
}

enable_apt_component() {
    local component="$1"
    local sources_d="/etc/apt/sources.list.d"
    local f
    for f in "$sources_d"/*.sources; do
        [ -f "$f" ] || continue
        if grep -q '^Components:' "$f" && \
                ! grep -E "^Components:[^#]*\b${component}\b" "$f" >/dev/null; then
            sed -i -E "s/^(Components:.*)$/\1 ${component}/" "$f"
        fi
    done
    if [ -f /etc/apt/sources.list ] && \
            grep -E '^deb[[:space:]]' /etc/apt/sources.list >/dev/null 2>&1; then
        if ! grep -E "^deb[[:space:]].*\b${component}\b" /etc/apt/sources.list \
                >/dev/null; then
            add-apt-repository -y --component "$component" >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

install_latest_nvidia_driver_aarch64() {
    log "enabling restricted/multiverse for nvidia packages"
    enable_apt_component restricted
    enable_apt_component multiverse
    retry 5 apt-get update

    log "looking up latest nvidia-driver-XXX in apt"
    local latest_branch
    latest_branch="$(apt-cache search '^nvidia-driver-[0-9]+-open$' 2>/dev/null \
        | awk '{print $1}' \
        | sed -E 's/nvidia-driver-([0-9]+)-open/\1/' \
        | sort -n | tail -1)"
    local pkg=""
    if [ -n "$latest_branch" ]; then
        pkg="nvidia-driver-${latest_branch}-open"
    else
        latest_branch="$(apt-cache search '^nvidia-driver-[0-9]+$' 2>/dev/null \
            | awk '{print $1}' \
            | sed -E 's/nvidia-driver-([0-9]+)/\1/' \
            | sort -n | tail -1)"
        if [ -n "$latest_branch" ]; then
            pkg="nvidia-driver-${latest_branch}"
        fi
    fi
    if [ -z "$pkg" ]; then
        warn "no nvidia-driver-XXX package available; skipping nvidia install"
        return 1
    fi

    log "installing $pkg (this triggers the dkms build)"
    if ! retry 3 apt-get install -y "$pkg"; then
        warn "failed to install $pkg"
        return 1
    fi

    local installed
    installed="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null \
        | sed -E 's/^[0-9]+://; s/-.*//')"
    if [ -z "$installed" ]; then
        warn "could not determine installed nvidia driver version"
        return 1
    fi
    NVIDIA_DRIVER_VERSION="$installed"
    log "installed nvidia driver version $NVIDIA_DRIVER_VERSION"
    return 0
}

install_nvidia_ngx_into_fex_rootfs() {
    local target_user="$1"
    local nvidia_ver="$2"

    if [ -z "$nvidia_ver" ]; then
        warn "no nvidia driver version; skipping NGX/DLSS install"
        return 0
    fi

    local home_dir
    home_dir="$(user_home_dir "$target_user")"
    if [ -z "$home_dir" ] || [ ! -d "$home_dir" ]; then
        warn "NGX install skipped: home dir for '$target_user' not found"
        return 0
    fi

    local rootfs_dir="$home_dir/.local/share/fex-emu/RootFS/Ubuntu_24_04"
    if [ ! -d "$rootfs_dir" ]; then
        warn "NGX install skipped: extracted FEX rootfs not found at $rootfs_dir"
        return 0
    fi

    local tmp
    tmp="$(mktemp -d)"
    pushd "$tmp" >/dev/null

    local runfile="NVIDIA-Linux-x86_64-${nvidia_ver}.run"
    local url="https://download.nvidia.com/XFree86/Linux-x86_64/${nvidia_ver}/${runfile}"

    log "downloading NVIDIA $nvidia_ver x86_64 runfile for NGX/DLSS"
    if ! curl -fL --retry 5 --retry-delay 5 --progress-bar -o "$runfile" "$url"; then
        warn "NVIDIA $nvidia_ver runfile download failed; DLSS setup skipped"
        popd >/dev/null
        rm -rf "$tmp"
        return 0
    fi

    log "extracting NVIDIA runfile"
    if ! sh "$runfile" -x >/dev/null; then
        warn "NVIDIA runfile extraction failed; DLSS setup skipped"
        popd >/dev/null
        rm -rf "$tmp"
        return 0
    fi

    pushd "${runfile%.run}" >/dev/null

    install -d -o "$target_user" -g "$target_user" \
        "$rootfs_dir/usr/lib/x86_64-linux-gnu/nvidia/wine" \
        "$rootfs_dir/lib/x86_64-linux-gnu" \
        "$rootfs_dir/lib/i386-linux-gnu"

    log "copying NGX DLLs into FEX rootfs (Proton DLSS path)"
    local dll_count=0
    shopt -s nullglob
    for dll in *.dll; do
        cp -f "$dll" "$rootfs_dir/usr/lib/x86_64-linux-gnu/nvidia/wine/"
        dll_count=$((dll_count + 1))
    done
    shopt -u nullglob
    log "copied $dll_count NGX dlls"

    log "copying 64-bit nvidia .so files into FEX rootfs"
    local dso base
    shopt -s nullglob
    for dso in *.so."${nvidia_ver}"; do
        cp -f "$dso" "$rootfs_dir/lib/x86_64-linux-gnu/$dso"
        base="$(printf '%s' "$dso" | cut -d. -f1-2)"
        ln -sf "$dso" "$rootfs_dir/lib/x86_64-linux-gnu/${base}.0"
        ln -sf "$dso" "$rootfs_dir/lib/x86_64-linux-gnu/${base}.1"
        ln -sf "$dso" "$rootfs_dir/lib/x86_64-linux-gnu/${base}.2"
    done
    shopt -u nullglob

    if [ -d 32 ]; then
        log "copying 32-bit nvidia .so files into FEX rootfs"
        pushd 32 >/dev/null
        shopt -s nullglob
        for dso in *.so."${nvidia_ver}"; do
            cp -f "$dso" "$rootfs_dir/lib/i386-linux-gnu/$dso"
            base="$(printf '%s' "$dso" | cut -d. -f1-2)"
            ln -sf "$dso" "$rootfs_dir/lib/i386-linux-gnu/${base}.0"
            ln -sf "$dso" "$rootfs_dir/lib/i386-linux-gnu/${base}.1"
            ln -sf "$dso" "$rootfs_dir/lib/i386-linux-gnu/${base}.2"
        done
        shopt -u nullglob
        popd >/dev/null
    fi

    popd >/dev/null
    popd >/dev/null
    rm -rf "$tmp"

    chown -R "$target_user":"$target_user" "$home_dir/.local/share/fex-emu"
    log "NGX/DLSS install into FEX rootfs complete"
}

install_userns_apparmor_profiles() {
    # On Ubuntu 24.04+ (including 26.04 resolute) the kernel refuses
    # unshare(CLONE_NEWUSER) from binaries without an AppArmor profile
    # granting `userns`. Every hop in our Steam/FEX chain uses user
    # namespaces:
    #   - FEXBash  unshare()s to stand up its rootfs chroot
    #   - bwrap    unshare()s for Steam runtime + Proton sandboxing
    #   - /usr/bin/steam runs briefly before our bin_steam.sh patch
    #     re-execs it via FEXBash
    # Drop minimum-confinement AppArmor profiles that explicitly grant
    # `userns,` to these three binaries. This mirrors the profiles
    # installed by MitchellAugustin/fex_autoinstall_poc.sh.
    log "installing AppArmor userns profiles for FEXBash/steam/bwrap"
    install -d -m 0755 /etc/apparmor.d

    cat > /etc/apparmor.d/FEXBash <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile FEXBash /usr/bin/FEXBash flags=(unconfined) {
  userns,

  # Site-specific additions and overrides. See local/README for details.
  include if exists <local/FEXBash>
}
EOF

    cat > /etc/apparmor.d/steam <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile steam /usr/bin/steam flags=(unconfined) {
  userns,

  include if exists <local/steam>
}
EOF

    cat > /etc/apparmor.d/bwrap <<'EOF'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /{usr/,}/bin/bwrap flags=(unconfined) {
  userns,

  include if exists <local/bwrap>
}
EOF

    # Pre-parse so we don't depend on the apparmor.service boot reload.
    # Harmless if apparmor isn't running in this chroot-ish builder VM
    # state -- next real boot reloads /etc/apparmor.d/* via
    # apparmor.service anyway.
    local profile
    for profile in FEXBash steam bwrap; do
        apparmor_parser -Tr "/etc/apparmor.d/$profile" 2>/dev/null || true
    done
}

if [ "$INSTALL_FEX" = "1" ]; then
    log "installing FEX"
    if add-apt-repository -y ppa:fex-emu/fex; then
        retry 5 apt-get update
        if retry 3 apt-get install -y \
                fex-emu-armv8.4 fex-emu-binfmt64 \
                squashfuse squashfs-tools jq; then
            install_fex_rootfs_for_user "$LOGIN_USER" || \
                warn "FEX RootFS install incomplete"
            install_userns_apparmor_profiles
        else
            warn "FEX install failed"
        fi
    else
        warn "failed to add the FEX PPA"
    fi
fi

patch_steam_bin_for_arm64() {
    # Steam's bootstrap is a chain of shell scripts (bin_steam.sh ->
    # steam.sh -> steamdeps, etc.) before any x86_64 ELF is exec'd. The
    # arm64 host bash would fail Steam's arch sanity checks (HOSTTYPE,
    # arch, uname -m) long before binfmt_misc ever has a chance to fire.
    # MitchellAugustin's fex_autoinstall patches bin_steam.sh to re-exec
    # itself under FEXBash so the whole shell chain runs as emulated
    # x86_64 from the very first line. Mirror that patch here.
    # See: https://github.com/MitchellAugustin/fex_autoinstall/blob/main/patch_steam_for_arm64.patch
    #
    # While we are in here we also prepend a small zenity+xdotool splash
    # block, because the FEX cold-start (JIT-translating the Steam
    # bootstrap + steamwebhelper) is visibly slow (~60s cold, ~10-15s
    # with a warm AOT cache) and GNOME gives no feedback during that
    # gap. The splash runs on native arm64 so the dialog pops up
    # instantly; the backgrounded subshell survives the FEXBash
    # re-exec below.
    local bin_steam="/usr/lib/steam/bin_steam.sh"
    if [ ! -f "$bin_steam" ]; then
        warn "$bin_steam missing; cannot patch Steam for FEX"
        return 1
    fi
    if grep -q 'FEXBash $0' "$bin_steam"; then
        log "Steam bin_steam.sh already patched for FEX (arm64)"
        return 0
    fi
    log "patching $bin_steam to re-exec under FEXBash on aarch64 (+ splash)"
    python3 - "$bin_steam" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)
marker = "set -e\n"
injection = (
    "\n"
    "# FEX splash (aarch64/FEX only): show a GTK dialog while FEX\n"
    "# JIT-translates the Steam bootstrap + steamwebhelper. Dismisses\n"
    "# when any Steam window appears (polled via xdotool -- Steam runs\n"
    "# under XWayland even on GNOME/Wayland) or after zenity's 3min\n"
    "# timeout, whichever fires first. Runs on native arm64 so the\n"
    "# dialog pops up instantly; the backgrounded subshell survives\n"
    "# the FEXBash re-exec below. STEAM_FEX_SPLASH_ACTIVE keeps the\n"
    "# x86 re-entry from spawning a second dialog on top of the first.\n"
    "# Disable entirely with STEAM_FEX_SPLASH=0.\n"
    "if [ \"${STEAM_FEX_SPLASH:-1}\" = \"1\" ] \\\n"
    "        && [ -z \"${STEAM_FEX_SPLASH_ACTIVE:-}\" ] \\\n"
    "        && [ -n \"${DISPLAY:-}${WAYLAND_DISPLAY:-}\" ] \\\n"
    "        && command -v zenity >/dev/null 2>&1; then\n"
    "    # Second-launch guard: if Steam is already running, this\n"
    "    # invocation just refocuses the existing window. Showing +\n"
    "    # auto-dismissing the splash would cause a ~1s flicker.\n"
    "    # Use the same size-gated detection as the dismissal loop\n"
    "    # below so transient bootstrap windows are not misread as\n"
    "    # an already-running main UI.\n"
    "    __steam_main_up() {\n"
    "        command -v xdotool >/dev/null 2>&1 || return 1\n"
    "        local wid geom\n"
    "        for wid in $(xdotool search --onlyvisible --class Steam 2>/dev/null); do\n"
    "            geom=$(xdotool getwindowgeometry --shell \"$wid\" 2>/dev/null) || continue\n"
    "            eval \"$geom\"\n"
    "            if [ \"${WIDTH:-0}\" -ge 500 ] && [ \"${HEIGHT:-0}\" -ge 400 ]; then\n"
    "                return 0\n"
    "            fi\n"
    "        done\n"
    "        return 1\n"
    "    }\n"
    "    if __steam_main_up; then\n"
    "        :\n"
    "    else\n"
    "        export STEAM_FEX_SPLASH_ACTIVE=1\n"
    "        (\n"
    "            zenity --info --title=\"Steam\" --no-wrap --width=420 --timeout=180 \\\n"
    "                --text=$'<b>Starting Steam...</b>\\n\\nFirst launch after boot warms FEX\\'s x86 translation\\ncache and can take up to a minute. Subsequent\\nlaunches are much faster.' \\\n"
    "                >/dev/null 2>&1 &\n"
    "            splash_pid=$!\n"
    "            # Wait for Steam's main library UI, identified by a\n"
    "            # minimum window size -- Steam opens a few small\n"
    "            # bootstrap / updater / sign-in dialogs first that\n"
    "            # also carry WM_CLASS=Steam but are not the main UI.\n"
    "            while kill -0 \"$splash_pid\" 2>/dev/null; do\n"
    "                if __steam_main_up; then\n"
    "                    break\n"
    "                fi\n"
    "                sleep 1\n"
    "            done\n"
    "            kill \"$splash_pid\" 2>/dev/null || true\n"
    "        ) >/dev/null 2>&1 &\n"
    "        disown 2>/dev/null || true\n"
    "    fi\n"
    "fi\n"
    "\n"
    "ARCH=$(arch)\n"
    "\n"
    "if [ \"$HOSTTYPE\" = \"aarch64\" ]; then\n"
    "  echo \"System architecture is aarch64 (ARM64). Launching with FEXBash\"\n"
    "  FEXBash -c $0 \"$@\"\n"
    "  exit\n"
    "else\n"
    "  echo \"System architecture is not aarch64. It is: $ARCH\"\n"
    "fi\n"
    "\n"
)
for i, line in enumerate(lines):
    if line == marker:
        lines.insert(i + 1, injection)
        break
else:
    sys.exit("marker 'set -e' not found in bin_steam.sh; refusing to patch blindly")
path.write_text("".join(lines))
PY
}

install_steam_from_official_deb() {
    local steam_deb="/tmp/steam-launcher_latest_all.deb"
    # Valve ships TWO steam launcher .debs at this URL prefix:
    #   - steam_latest.deb              -> Architecture: amd64, hard-depends
    #                                      on apt:amd64, libc6:amd64, etc.
    #                                      Unusable on arm64 without either
    #                                      full multi-arch amd64 sources or
    #                                      `dpkg -i --force-all` (which
    #                                      permanently breaks the apt
    #                                      resolver for every later call).
    #   - steam-launcher_latest_all.deb -> Architecture: all, deps are
    #                                      plain `apt`, `python3`, `xterm`
    #                                      etc. which are all installable on
    #                                      arm64. Installs cleanly via apt
    #                                      with no --force-all, apt stays
    #                                      healthy afterward. This is what
    #                                      MitchellAugustin/fex_autoinstall
    #                                      uses on arm64 too.
    # We want the second one. FEX-Emu handles the x86_64 Steam ELF
    # bootstrap + steamwebhelper at runtime via its Ubuntu 24.04 RootFS.
    local steam_url="https://repo.steampowered.com/steam/archive/stable/steam-launcher_latest_all.deb"

    log "downloading arch-all Steam launcher .deb from Valve"
    if ! curl -fL --retry 5 --retry-delay 5 --progress-bar \
            -o "$steam_deb" "$steam_url"; then
        warn "failed to download $steam_url"
        rm -f "$steam_deb"
        return 1
    fi

    log "installing Steam launcher via apt (resolves arm64 deps cleanly)"
    if ! retry 3 apt-get install -y "$steam_deb"; then
        warn "apt-get install of Steam .deb failed"
        rm -f "$steam_deb"
        return 1
    fi
    rm -f "$steam_deb"

    if [ ! -x /usr/bin/steam ] && [ ! -x /usr/games/steam ]; then
        warn "Steam install did not produce a steam launcher"
        return 1
    fi

    patch_steam_bin_for_arm64 || warn "Steam arm64 bin_steam.sh patch failed"

    log "Steam launcher installed at $(command -v steam || echo /usr/games/steam)"
    return 0
}

if [ "$INSTALL_NVIDIA" = "1" ]; then
    log "installing latest aarch64 NVIDIA driver"
    if install_latest_nvidia_driver_aarch64; then
        if [ "$INSTALL_FEX" = "1" ]; then
            install_nvidia_ngx_into_fex_rootfs "$LOGIN_USER" "$NVIDIA_DRIVER_VERSION"
        fi
    else
        warn "nvidia driver install failed; NGX/DLSS dance skipped"
    fi
fi

install_apple_dma_dkms() {
    if [ ! -f "$APPLE_DMA_SRC_TGZ" ]; then
        warn "apple-dma source tarball not found at $APPLE_DMA_SRC_TGZ"
        return 1
    fi

    log "installing dkms + headers for apple-dma"
    if ! retry 3 apt-get install -y dkms build-essential \
            linux-headers-generic; then
        warn "failed to install dkms/build-essential/headers"
        return 1
    fi

    local src_dir="/usr/src/apple-dma-${APPLE_DMA_VERSION}"
    log "extracting apple-dma source to $src_dir"
    rm -rf "$src_dir"
    install -d -m 0755 "$src_dir"
    if ! tar -xzf "$APPLE_DMA_SRC_TGZ" -C "$src_dir"; then
        warn "failed to extract apple-dma source"
        return 1
    fi

    if [ ! -f "$src_dir/dkms.conf" ]; then
        warn "apple-dma source does not contain dkms.conf"
        return 1
    fi

    log "registering apple-dma with dkms"
    dkms remove "apple-dma/${APPLE_DMA_VERSION}" --all >/dev/null 2>&1 || true
    if ! dkms add "apple-dma/${APPLE_DMA_VERSION}"; then
        warn "dkms add failed for apple-dma"
        return 1
    fi

    local kver any_built=0
    for kver in $(ls /lib/modules); do
        [ -d "/lib/modules/$kver/build" ] || continue
        log "building apple-dma for kernel $kver"
        if dkms install --force "apple-dma/${APPLE_DMA_VERSION}" -k "$kver"; then
            any_built=1
        else
            warn "dkms install failed for kernel $kver"
        fi
    done
    if [ "$any_built" = "0" ]; then
        warn "apple-dma was not built for any installed kernel"
        return 1
    fi

    log "installing apple-dma modprobe configuration"
    install -d -m 0755 /etc/modprobe.d /etc/modules-load.d
    install -m 0644 "$src_dir/apple-dma-options.conf" \
        /etc/modprobe.d/apple-dma-options.conf
    install -m 0644 "$src_dir/apple-dma-load.conf" \
        /etc/modules-load.d/apple-dma-load.conf

    depmod -a || true
    update-initramfs -u -k all || true
    return 0
}

if [ "$INSTALL_APPLE_DMA" = "1" ]; then
    log "installing apple-dma kernel module via dkms"
    if ! install_apple_dma_dkms; then
        warn "apple-dma install incomplete"
    fi
fi

install_first_boot_finalizer

configure_gnome_dconf_defaults() {
    log "writing GNOME dconf system defaults"

    install -d -m 0755 /etc/dconf/profile /etc/dconf/db/local.d

    # Make dconf merge /etc/dconf/db/local on top of each user's db.
    cat > /etc/dconf/profile/user <<'EOF'
user-db:user
system-db:local
EOF

    # FEX-emulated x86 apps (Steam, steamwebhelper, Proton) routinely
    # block the main thread for longer than mutter's default 5s
    # check-alive-timeout during JIT warmup and init, so GNOME pops the
    # "Application is not responding - Wait / Force Quit" dialog
    # mid-launch. Setting the timeout to 0 disables that nag entirely
    # (window still closable, app still killable from System Monitor).
    #
    # The `uint32` type prefix is load-bearing: the mutter schema
    # declares check-alive-timeout as `u` (uint32), but dconf keyfile
    # values without an explicit type are parsed as int32 by
    # `dconf update`. GSettings then rejects the stored value at read
    # time due to the type mismatch and falls back to the schema
    # default (5000ms) — so `dconf read` would show `0` while mutter
    # keeps nagging. Writing `uint32 0` makes the compiled value type
    # match the schema.
    cat > /etc/dconf/db/local.d/00-qemu-vfio <<'EOF'
[org/gnome/mutter]
check-alive-timeout=uint32 0
EOF

    if command -v dconf >/dev/null 2>&1; then
        dconf update || warn "dconf update failed"
    else
        warn "dconf not found; system defaults will be compiled on next boot"
    fi
}

configure_gnome_dconf_defaults

if id -u "$LOGIN_USER" >/dev/null 2>&1; then
    login_home="$(getent passwd "$LOGIN_USER" | cut -d: -f6)"
    if [ -n "$login_home" ] && [ -d "$login_home" ]; then
        log "ensuring $login_home is fully owned by $LOGIN_USER (defensive sweep)"
        chown -R "$LOGIN_USER":"$LOGIN_USER" "$login_home" || true
    fi
fi

log "pruning superseded kernels now that all dkms builds are complete"
purge_older_kernels

log "autoremoving orphaned packages before final cleanup"
apt-get autoremove -y --purge || true

if [ "$INSTALL_STEAM" = "1" ]; then
    log "installing Steam (Valve arch-all launcher .deb via apt)"
    # Runtime deps for the FEX splash our bin_steam.sh patch injects:
    # zenity for the dialog, xdotool to poll for Steam's main window so
    # the splash dismisses itself once Steam is actually up. Non-fatal
    # if either is missing -- the splash block probes with `command -v`
    # before using them, so Steam still launches (just silently) if the
    # install fails.
    if ! retry 3 apt-get install -y zenity xdotool; then
        warn "failed to install splash deps (zenity/xdotool); Steam will launch without a loading dialog"
    fi
    if ! install_steam_from_official_deb; then
        warn "Steam install failed"
    fi
fi

log "trimming caches to shrink the shipped image"
apt-get clean || true
rm -rf /var/cache/apt/archives/partial/* \
    /var/cache/apt/archives/*.deb \
    /var/cache/apt/archives/lock \
    /var/lib/apt/lists/* \
    /var/cache/debconf/*-old \
    /var/lib/dpkg/*-old \
    /var/log/apt/*.gz \
    /var/log/dpkg.log.* \
    /var/log/installer \
    /var/log/journal/* \
    /var/log/unattended-upgrades/*.gz \
    /var/log/qemu-vfio-provision.log.* \
    /var/cache/qemu-vfio/apple-dma-src.tgz \
    /tmp/* /var/tmp/* \
    /root/.cache 2>/dev/null || true
if command -v snap >/dev/null 2>&1; then
    snap set system refresh.retain=2 2>/dev/null || true
    snap list --all 2>/dev/null \
        | awk '/disabled/{print $1, $3}' \
        | while read -r name rev; do
            [ -n "$name" ] && [ -n "$rev" ] && \
                snap remove --revision="$rev" "$name" || true
        done
fi
journalctl --rotate --vacuum-time=1s >/dev/null 2>&1 || true

log "running fstrim to discard freed blocks (should punch holes in qcow2 now that builder VM drive has discard=unmap)"
fstrim -av || warn "fstrim failed (non-fatal)"

log "disabling cloud-init for shipped image reuse"
cloud-init clean --logs || true
touch /etc/cloud/cloud-init.disabled

log "resetting machine identity for first real boot"
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*

log "writing readiness marker"
mkdir -p /var/lib/qemu-vfio
cat > /var/lib/qemu-vfio/image-ready.json <<EOF
{
  "desktop": true,
  "fex": $([ "$INSTALL_FEX" = "1" ] && printf true || printf false),
  "steam": $([ "$INSTALL_STEAM" = "1" ] && printf true || printf false),
  "nvidia": $([ "$INSTALL_NVIDIA" = "1" ] && printf true || printf false),
  "apple_dma": $([ "$INSTALL_APPLE_DMA" = "1" ] && printf true || printf false)
}
EOF

sync
log "provisioning complete, powering off"
systemctl poweroff --no-block
