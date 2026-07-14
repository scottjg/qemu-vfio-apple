#!/usr/bin/env bash
#
# Guest provisioning for the headless Docker image profile.
#
# Turns Ubuntu's arm64 server cloud image into the VM that backs
# `qemu-vfio-apple docker up`:
#
#   - Docker Engine (Ubuntu's docker.io + buildx + compose-v2) listening
#     on unix socket AND tcp://0.0.0.0:2375. Binding 0.0.0.0 *inside the
#     guest* is safe: the guest sits on a private slirp network and only
#     the host-side loopback hostfwd can reach it.
#   - NVIDIA driver (latest -open branch in the Ubuntu archive) +
#     nvidia-container-toolkit with both the `nvidia` runtime (for
#     `docker run --gpus all`) and a boot-time CDI spec generator (for
#     `--device nvidia.com/gpu=all`). CDI generation must happen at boot,
#     not here — the builder VM has no GPU passed through.
#   - Mesa Vulkan (RADV) + vulkan-tools for the AMD path: containers get
#     the GPU via `--device /dev/dri`.
#   - Optional experimental ROCm behind INSTALL_ROCM=1 (arm64 ROCm is
#     unsupported by AMD; Vulkan is the default AMD path).
#   - apple-dma DKMS module, same as the desktop image, so passthrough
#     DMA works.
#
# No desktop, no FEX/Steam. Stays on the cloud image's server networking
# stack (netplan + systemd-networkd).
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

INSTALL_NVIDIA="${INSTALL_NVIDIA:-1}"
INSTALL_APPLE_DMA="${INSTALL_APPLE_DMA:-1}"
INSTALL_ROCM="${INSTALL_ROCM:-0}"

DOCKER_TCP_PORT="${DOCKER_TCP_PORT:-2375}"

# See provision-desktop.sh for the rationale (page_poison=1 panic=10 to
# surface stale-DMA memory corruption loudly during development).
ENABLE_DEBUG_KERNEL_PARAMS="${ENABLE_DEBUG_KERNEL_PARAMS:-0}"

APPLE_DMA_VERSION="${APPLE_DMA_VERSION:-0.1.0}"
APPLE_DMA_SRC_TGZ="${APPLE_DMA_SRC_TGZ:-/var/cache/qemu-vfio/apple-dma-src.tgz}"

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
Before=multi-user.target ssh.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/qemu-vfio-firstboot-finalize.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload || true
    systemctl enable qemu-vfio-firstboot.service || true
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

NVIDIA_DRIVER_VERSION=""

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

install_docker_engine() {
    log "installing Docker Engine (docker.io + buildx + compose-v2)"
    enable_apt_component universe
    retry 3 apt-get install -y docker.io docker-buildx docker-compose-v2

    log "adding $LOGIN_USER to the docker group"
    usermod -aG docker "$LOGIN_USER" || warn "could not add $LOGIN_USER to docker group"

    # Enable Docker's CDI support up front. nvidia-ctk runtime configure
    # (below, when INSTALL_NVIDIA=1) merges its `runtimes` block into
    # this same file.
    log "writing /etc/docker/daemon.json (CDI enabled)"
    install -d -m 0755 /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "features": {
    "cdi": true
  }
}
EOF

    # Add the TCP listener by copying the packaged ExecStart and
    # appending -H tcp://. Editing ExecStart (rather than daemon.json
    # "hosts") keeps the packaged `-H fd://` socket activation working —
    # dockerd refuses to mix daemon.json hosts with -H flags, so the
    # drop-in must own the whole line.
    local orig_execstart
    orig_execstart="$(systemctl cat docker.service 2>/dev/null \
        | sed -n 's/^ExecStart=//p' | tail -n 1)"
    if [ -z "$orig_execstart" ]; then
        warn "could not read docker.service ExecStart"
        return 1
    fi
    log "enabling dockerd TCP listener on :$DOCKER_TCP_PORT"
    install -d -m 0755 /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/10-qemu-vfio-tcp.conf <<EOF
# Written by qemu-vfio image-builder (provision-docker.sh).
# Adds a TCP listener for the host-side loopback hostfwd. The guest's
# slirp network is private to the VM, so 0.0.0.0 here is not LAN-exposed.
[Service]
ExecStart=
ExecStart=$orig_execstart -H tcp://0.0.0.0:$DOCKER_TCP_PORT
EOF

    systemctl daemon-reload
    systemctl enable docker.service || true
    return 0
}

verify_docker_engine() {
    log "restarting docker and verifying the TCP endpoint"
    systemctl restart docker.service

    local i
    for ((i = 1; i <= 10; i++)); do
        if curl -fsS "http://127.0.0.1:$DOCKER_TCP_PORT/_ping" >/dev/null 2>&1; then
            log "docker API is answering on tcp :$DOCKER_TCP_PORT"
            docker version || true
            return 0
        fi
        sleep 2
    done
    warn "docker API did not answer on tcp :$DOCKER_TCP_PORT"
    journalctl -u docker.service --no-pager | tail -50 || true
    return 1
}

install_nvidia_container_toolkit() {
    log "adding the NVIDIA container toolkit apt repo"
    install -d -m 0755 /usr/share/keyrings
    if ! curl -fsSL --retry 5 --retry-delay 5 \
            https://nvidia.github.io/libnvidia-container/gpgkey \
            | gpg --dearmor --yes \
                -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg; then
        warn "failed to fetch nvidia container toolkit gpg key"
        return 1
    fi
    if ! curl -fsSL --retry 5 --retry-delay 5 \
            https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            > /etc/apt/sources.list.d/nvidia-container-toolkit.list; then
        warn "failed to fetch nvidia container toolkit apt list"
        return 1
    fi

    retry 5 apt-get update
    if ! retry 3 apt-get install -y nvidia-container-toolkit; then
        warn "failed to install nvidia-container-toolkit"
        return 1
    fi

    # Registers the `nvidia` runtime in /etc/docker/daemon.json so
    # `docker run --gpus all` works (the legacy/runtime path).
    log "registering the nvidia runtime with docker"
    nvidia-ctk runtime configure --runtime=docker

    # The CDI spec enumerates the actual GPU, which is only present when
    # the sealed image boots with passthrough — never in this builder VM.
    # Generate it on every boot, before docker, and tolerate absence of
    # a GPU so the image still boots cleanly without passthrough.
    log "installing boot-time NVIDIA CDI spec generator"
    cat > /etc/systemd/system/qemu-vfio-nvidia-cdi.service <<'EOF'
[Unit]
Description=Generate NVIDIA CDI spec for container GPU access
After=systemd-modules-load.service
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '/usr/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml || echo "no NVIDIA GPU; skipping CDI spec"'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable qemu-vfio-nvidia-cdi.service || true
    return 0
}

install_rocm_experimental() {
    # AMD does not support aarch64 hosts for ROCm; Ubuntu's arm64 rocm
    # packages exist but KFD-queue issues show up in the wild. This is
    # strictly best-effort and off by default — Vulkan via /dev/dri is
    # the supported AMD path for this image.
    log "installing ROCm (experimental on arm64)"
    if ! retry 3 apt-get install -y rocm; then
        warn "ROCm install failed; AMD Vulkan path is unaffected"
        return 1
    fi
    return 0
}

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

# ---------------------------------------------------------------------------

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

log "installing base packages"
#
# linux-firmware-*-graphics: the cloud image ships no GPU firmware, and
# amdgpu fails early_init for every IP block that needs a blob (psp,
# smu, gfx, sdma, vcn) without it — the passed-through GPU never comes
# up. Same rationale as the desktop image.
#
# mesa-vulkan-drivers + vulkan-tools: guest-side Vulkan (RADV for AMD,
# also covers vulkaninfo smoke tests); containers reach the GPU via
# `--device /dev/dri` device mounts.
#
retry 3 apt-get install -y \
    linux-firmware-amd-graphics linux-firmware-intel-graphics \
    qemu-guest-agent \
    software-properties-common \
    mesa-vulkan-drivers vulkan-tools \
    curl \
    wget \
    gnupg \
    ca-certificates

# Keep console output on the QEMU serial port — this image is headless
# and console.log is the only window into a wedged boot. No quiet/splash.
KERNEL_CMDLINE_DEFAULT="console=tty1 console=ttyS0"
if [ "$ENABLE_DEBUG_KERNEL_PARAMS" = "1" ]; then
    KERNEL_CMDLINE_DEFAULT="$KERNEL_CMDLINE_DEFAULT page_poison=1 panic=10"
fi
log "setting kernel cmdline via grub.d drop-in: $KERNEL_CMDLINE_DEFAULT"
install -d -m 0755 /etc/default/grub.d
cat > /etc/default/grub.d/99-qemu-vfio-cmdline.cfg <<EOF
# Written by qemu-vfio image-builder (provision-docker.sh).
# Sources later than 50-cloudimg-settings.cfg, so this wins.
GRUB_CMDLINE_LINUX_DEFAULT="${KERNEL_CMDLINE_DEFAULT}"
EOF
update-grub || true

# Docker Engine is the point of this image — a failure here fails the
# whole build rather than emitting an artifact that can't serve 2375.
install_docker_engine

if [ "$INSTALL_NVIDIA" = "1" ]; then
    log "installing latest aarch64 NVIDIA driver"
    if install_latest_nvidia_driver_aarch64; then
        install_nvidia_container_toolkit || \
            warn "nvidia container toolkit install incomplete; --gpus all will not work"
    else
        warn "nvidia driver install failed; container GPU support skipped"
    fi
fi

if [ "$INSTALL_ROCM" = "1" ]; then
    install_rocm_experimental || warn "ROCm install incomplete"
fi

verify_docker_engine

# /dev/dri render nodes are group `render` (and card nodes `video`);
# membership lets the login user run vulkaninfo etc. without sudo.
usermod -aG video,render "$LOGIN_USER" || true

if [ "$INSTALL_APPLE_DMA" = "1" ]; then
    log "installing apple-dma kernel module via dkms"
    if ! install_apple_dma_dkms; then
        warn "apple-dma install incomplete"
    fi
fi

install_first_boot_finalizer

log "pruning superseded kernels now that all dkms builds are complete"
purge_older_kernels

log "autoremoving orphaned packages before final cleanup"
apt-get autoremove -y --purge || true

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

log "running fstrim to discard freed blocks"
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
  "docker": true,
  "docker_tcp_port": $DOCKER_TCP_PORT,
  "nvidia": $([ "$INSTALL_NVIDIA" = "1" ] && printf true || printf false),
  "vulkan": true,
  "rocm": $([ "$INSTALL_ROCM" = "1" ] && printf true || printf false),
  "apple_dma": $([ "$INSTALL_APPLE_DMA" = "1" ] && printf true || printf false)
}
EOF

sync
log "provisioning complete, powering off"
systemctl poweroff --no-block
