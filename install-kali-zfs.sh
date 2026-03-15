#!/usr/bin/env bash
###############################################################################
# Portable Kali Linux on ZFS — Full Installer
# Target: USB SSD (Samsung MZNLN128 in RTL9210 enclosure)
#
# Based on: OpenZFS "Debian Trixie Root on ZFS" guide (Dec 2025)
#           Adapted for Kali Linux (kali-rolling, Debian Testing/Trixie based)
#
# Layout:
#   Part 1 — 512 MiB  ESP  (FAT32, EFI System Partition)
#   Part 2 — 1 GiB    ZFS  boot pool (bpool, grub2-compatible)
#   Part 3 — 64 GiB   ZFS  root pool (rpool, native encryption)
#   Remaining ~53 GiB left unallocated for future use
#
# Features:
#   - ZFS native encryption (aes-256-gcm, passphrase)
#   - Secure Boot via Microsoft-trusted signed chain:
#       shimx64.efi  (signed by Microsoft UEFI 3rd-party CA)
#       grubx64.efi  (signed by Debian key, embedded in shim)
#       vmlinuz       (signed by Debian key, verified via shim protocol)
#   - Boots on password-locked BIOS (no MOK enrollment needed)
#   - Portable GRUB (--removable, writes EFI/BOOT/BOOTX64.EFI)
#   - KDE Plasma desktop
#   - NetworkManager for portable network handling
#   - Comprehensive firmware bundle for broad hardware compatibility
#   - hostid set in initramfs for portable pool imports
#
# Run from an Arch/CachyOS host that has ZFS loaded.
# Requires: zfs/zpool, unsquashfs, sgdisk, mkdosfs, chroot, internet (for ZFS packages)
#
# Usage: sudo ./install-kali-zfs.sh --iso=PATH [--debian-iso=PATH] [--resume] [--disk=/dev/sdX]
#   --iso=PATH       Path to Kali Linux live ISO (required)
#   --debian-iso=PATH  Path to Debian live ISO (optional, for offline signed GRUB)
#   --resume         Skip completed phases and continue from last checkpoint
#   --disk=PATH      Override disk detection (e.g. --disk=/dev/loop0 for VM testing)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/disk.sh"
source "$SCRIPT_DIR/lib/secureboot.sh"
source "$SCRIPT_DIR/lib/desktop.sh"

# ─── Logging ────────────────────────────────────────────────────────────────
setup_log_dir "$SCRIPT_DIR"
setup_transcript "kali-zfs" "$@"
setup_logging "kali-zfs"

# ─── Configuration ──────────────────────────────────────────────────────────
DISK_WWN="/dev/disk/by-id/wwn-0x5002538d006b1ef3"
DISK_ATA="/dev/disk/by-id/ata-SAMSUNG_MZNLN128HAHQ-000H1_S3T8NE1K664564"
DISK_USB="/dev/disk/by-id/usb-SAMSUNG_MZNLN128HAHQ-000_012345678999-0:0"
MNT="/mnt/kali"
HOSTNAME_KALI="kali-portable"
KALI_MIRROR="https://http.kali.org/kali"
KALI_SUITE="kali-rolling"
ESP_SIZE="512M"
BOOT_POOL_SIZE="1G"
ROOT_POOL_SIZE="65536M"              # 64 GiB exactly
SWAP_SIZE="4G"
DISTRO_NAME="kali"

# ─── Parse arguments ───────────────────────────────────────────────────────
DISK_OVERRIDE=""
ISO_PATH=""
DEBIAN_ISO_PATH=""
for arg in "$@"; do
    case "$arg" in
        --resume)        ;; # handled by init_resume
        --disk=*)        DISK_OVERRIDE="${arg#--disk=}" ;;
        --iso=*)         ISO_PATH="${arg#--iso=}" ;;
        --debian-iso=*)  DEBIAN_ISO_PATH="${arg#--debian-iso=}" ;;
    esac
done

init_resume "kali-zfs" "$@"

# ─── Preflight checks ──────────────────────────────────────────────────────
require_root

resolve_disk ${DISK_OVERRIDE:+--override="$DISK_OVERRIDE"} "$DISK_WWN" "$DISK_ATA" "$DISK_USB"

PART_ESP="$(part "$DISK" 1)"
PART_BOOT="$(part "$DISK" 2)"
PART_ROOT="$(part "$DISK" 3)"

require_zfs

# Auto-install missing tools on Arch/CachyOS
command -v sgdisk    &>/dev/null || host_install_package gptfdisk
command -v unsquashfs &>/dev/null || host_install_package squashfs-tools
require_commands sgdisk zpool zfs unsquashfs mkdosfs chroot blkdiscard partprobe

# ─── ISO validation ─────────────────────────────────────────────────────────
[[ -n "$ISO_PATH" ]] || error "--iso=PATH is required. Point it at a Kali Linux live ISO."
[[ -f "$ISO_PATH" ]] || error "ISO not found: $ISO_PATH"

ISO_MNT="/tmp/.kali-iso-$$"
mkdir -p "$ISO_MNT"
mount -o loop,ro "$ISO_PATH" "$ISO_MNT" || error "Failed to mount ISO: $ISO_PATH"

SQUASHFS_PATH="$ISO_MNT/live/filesystem.squashfs"
[[ -f "$SQUASHFS_PATH" ]] || { umount "$ISO_MNT" 2>/dev/null; rmdir "$ISO_MNT"; error "Not a Kali live ISO — missing live/filesystem.squashfs"; }
info "Kali ISO mounted: $ISO_PATH"
info "  Squashfs: $(du -h "$SQUASHFS_PATH" | cut -f1)"

# Mount Debian ISO if provided (for offline signed GRUB + shim)
DEBIAN_ISO_MNT=""
DEBIAN_SIGNED_GRUB_DEB=""
DEBIAN_SIGNED_SHIM_DEB=""
if [[ -n "$DEBIAN_ISO_PATH" ]]; then
    [[ -f "$DEBIAN_ISO_PATH" ]] || error "Debian ISO not found: $DEBIAN_ISO_PATH"
    DEBIAN_ISO_MNT="/tmp/.debian-iso-$$"
    mkdir -p "$DEBIAN_ISO_MNT"
    mount -o loop,ro "$DEBIAN_ISO_PATH" "$DEBIAN_ISO_MNT" || error "Failed to mount Debian ISO: $DEBIAN_ISO_PATH"
    DEBIAN_SIGNED_GRUB_DEB=$(find "$DEBIAN_ISO_MNT/pool/" -name "grub-efi-amd64-signed_*.deb" 2>/dev/null | head -1)
    DEBIAN_SIGNED_SHIM_DEB=$(find "$DEBIAN_ISO_MNT/pool/" -name "shim-signed_*.deb" 2>/dev/null | head -1)
    if [[ -n "$DEBIAN_SIGNED_GRUB_DEB" || -n "$DEBIAN_SIGNED_SHIM_DEB" ]]; then
        info "Debian ISO mounted: $DEBIAN_ISO_PATH"
        [[ -n "$DEBIAN_SIGNED_GRUB_DEB" ]] && info "  Found signed GRUB: $(basename "$DEBIAN_SIGNED_GRUB_DEB")"
        [[ -n "$DEBIAN_SIGNED_SHIM_DEB" ]] && info "  Found signed shim: $(basename "$DEBIAN_SIGNED_SHIM_DEB")"
    else
        warn "Debian ISO mounted but signed packages not found — will download from internet."
    fi
fi

# ─── Confirmation ───────────────────────────────────────────────────────────
info "Target disk: $DISK -> $DISK_DEV"
info "Kali ISO:    $ISO_PATH"
[[ -n "$DEBIAN_ISO_PATH" ]] && info "Debian ISO:  $DEBIAN_ISO_PATH"
info "Log file:    $LOGFILE"
info "Transcript:  $TYPESCRIPT"
if $RESUME; then
    info "Resume mode: ON — last completed phase: $(completed_phase)"
else
    info "Resume mode: OFF (use --resume to continue a failed run)"
fi
info "This will DESTROY ALL DATA on the disk."
info ""
info "Partition plan:"
info "  Part 1: ${ESP_SIZE}  ESP (FAT32)"
info "  Part 2: ${BOOT_POOL_SIZE}  ZFS boot pool (bpool)"
info "  Part 3: ${ROOT_POOL_SIZE}  ZFS root pool (rpool, encrypted)"
info "  Rest:   unallocated"

confirm_destructive

###############################################################################
# PHASE 1: Disk Preparation
###############################################################################
if skip_phase 1; then
    info "PHASE 1: Disk Preparation — SKIPPED (already completed)"
else
    phase "PHASE 1: Disk Preparation"
    safe_destroy_pools_on_disk "$DISK_DEV" "$MNT"
    partition_disk "$DISK" "$ESP_SIZE" "$BOOT_POOL_SIZE" "$ROOT_POOL_SIZE"
    mark_phase 1
fi

###############################################################################
# PHASE 2: Create ZFS Pools
###############################################################################
if skip_phase 2; then
    info "PHASE 2: Create ZFS Pools — SKIPPED (already completed)"
    reimport_pools "$MNT" "$DISTRO_NAME"
else
    phase "PHASE 2: Create ZFS Pools"
    create_zfs_pools "$DISK" "$MNT"
    mark_phase 2
fi

###############################################################################
# PHASE 3: Create ZFS Datasets
###############################################################################
if skip_phase 3; then
    info "PHASE 3: Create ZFS Datasets — SKIPPED (already completed)"
    zfs mount "rpool/ROOT/$DISTRO_NAME" 2>/dev/null || true
    zfs mount -a 2>/dev/null || true
    mkdir -p "$MNT/run"
    mountpoint -q "$MNT/run" || mount -t tmpfs tmpfs "$MNT/run"
    mkdir -p "$MNT/run/lock"
else
    phase "PHASE 3: Create ZFS Datasets"
    create_zfs_datasets "$MNT" "$DISTRO_NAME" "$SWAP_SIZE"
    mark_phase 3
fi

###############################################################################
# PHASE 4: Install Kali Base System (ISO squashfs extraction)
###############################################################################
if skip_phase 4; then
    info "PHASE 4: Install Kali Base System — SKIPPED (already completed)"
else
    phase "PHASE 4: Install Kali Base System (ISO squashfs extraction)"

    info "Extracting squashfs from Kali ISO to ZFS root..."
    info "Source: $SQUASHFS_PATH"
    info "Target: $MNT"
    unsquashfs -f -d "$MNT" "$SQUASHFS_PATH"

    # Clean up live-system artifacts
    info "Cleaning up live-system artifacts..."
    rm -f "$MNT/etc/hostname" 2>/dev/null || true
    rm -rf "$MNT/etc/live" 2>/dev/null || true
    rm -f "$MNT/etc/lightdm/lightdm.conf" 2>/dev/null || true
    chroot "$MNT" userdel -r kali 2>/dev/null || true
    : > "$MNT/etc/machine-id"

    # Copy zpool cache
    mkdir -p "$MNT/etc/zfs"
    cp /etc/zfs/zpool.cache "$MNT/etc/zfs/" 2>/dev/null || true

    # Copy ISO's local apt repo into chroot for offline package installs
    if [[ -d "$ISO_MNT/pool" && -d "$ISO_MNT/dists" ]]; then
        info "Copying ISO apt repo into chroot for offline installs..."
        mkdir -p "$MNT/opt/iso-repo"
        cp -a "$ISO_MNT/pool" "$MNT/opt/iso-repo/"
        cp -a "$ISO_MNT/dists" "$MNT/opt/iso-repo/"
        info "  ISO repo copied to /opt/iso-repo/ ($(du -sh "$MNT/opt/iso-repo" | cut -f1))"
    fi

    # Copy Debian signed debs if available
    if [[ -n "$DEBIAN_SIGNED_GRUB_DEB" || -n "$DEBIAN_SIGNED_SHIM_DEB" ]]; then
        info "Copying Debian signed packages into chroot..."
        mkdir -p "$MNT/opt/iso-repo/debian-signed"
        [[ -n "$DEBIAN_SIGNED_GRUB_DEB" ]] && cp "$DEBIAN_SIGNED_GRUB_DEB" "$MNT/opt/iso-repo/debian-signed/"
        [[ -n "$DEBIAN_SIGNED_SHIM_DEB" ]] && cp "$DEBIAN_SIGNED_SHIM_DEB" "$MNT/opt/iso-repo/debian-signed/"
    fi
    mark_phase 4
fi

###############################################################################
# PHASE 5a: System Configuration — Base Setup (chroot)
###############################################################################
if skip_phase 5; then
    info "PHASE 5a: Base Setup — SKIPPED (already completed)"
else
    phase "PHASE 5a: System Configuration — Base Setup"

    echo "$HOSTNAME_KALI" > "$MNT/etc/hostname"
    cat > "$MNT/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME_KALI
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

    cat > "$MNT/etc/apt/sources.list" <<EOF
deb $KALI_MIRROR $KALI_SUITE main contrib non-free non-free-firmware
deb-src $KALI_MIRROR $KALI_SUITE main contrib non-free non-free-firmware
EOF

    setup_chroot_mounts "$MNT"

    info "Entering chroot for base setup..."
    cat > "$MNT/tmp/chroot-5a.sh" <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo ""; echo "[chroot] FATAL: command failed (exit $?) at line $LINENO: $BASH_COMMAND"; exit 1' ERR

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export DISK="__DISK__"

apt_retry() {
    local attempt max_attempts=3
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        if apt-get "$@"; then return 0; fi
        echo "[chroot] apt-get failed (attempt $attempt/$max_attempts) — retrying in 10s..."
        sleep 10; apt-get update -qq 2>/dev/null || true
    done
    echo "[chroot] apt-get failed after $max_attempts attempts"; return 1
}

# ── Hostid for portable ZFS ─────────────────────────────────────────────────
echo "[chroot] Setting up stable hostid for portable ZFS..."
HOSTID="__HOSTID__"
printf "\\x${HOSTID:6:2}\\x${HOSTID:4:2}\\x${HOSTID:2:2}\\x${HOSTID:0:2}" > /etc/hostid

mkdir -p /etc/initramfs-tools/hooks
cat > /etc/initramfs-tools/hooks/zfs-hostid <<'HOOKEOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in prereqs) prereqs; exit 0;; esac
if [ -f /etc/hostid ]; then
    mkdir -p "$DESTDIR/etc"
    cp /etc/hostid "$DESTDIR/etc/hostid"
fi
HOOKEOF
chmod +x /etc/initramfs-tools/hooks/zfs-hostid

# ── ISO local repo ──────────────────────────────────────────────────────────
if [[ -d /opt/iso-repo/pool ]]; then
    echo "[chroot] Configuring ISO local repo as apt source..."
    echo "deb [trusted=yes] file:///opt/iso-repo kali-rolling main contrib non-free non-free-firmware" \
        > /etc/apt/sources.list.d/iso-local.list
fi

echo "[chroot] Updating package lists..."
apt-get update

mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99-noninteractive <<'APTEOF'
Dpkg::Options { "--force-confdef"; "--force-confold"; }
APTEOF

# ── Locale & timezone ───────────────────────────────────────────────────────
echo "[chroot] Configuring locale and timezone..."
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
dpkg-reconfigure -f noninteractive tzdata

echo "[chroot] Phase 5a complete."
CHROOT_EOF

    sed -i "s|__DISK__|${DISK}|g" "$MNT/tmp/chroot-5a.sh"
    sed -i "s|__HOSTID__|$(hostid)|g" "$MNT/tmp/chroot-5a.sh"
    chmod +x "$MNT/tmp/chroot-5a.sh"
    chroot "$MNT" /usr/bin/env bash /tmp/chroot-5a.sh
    rm -f "$MNT/tmp/chroot-5a.sh"
    mark_phase 5
fi

###############################################################################
# PHASE 5b: ZFS, Kernel, and Boot Setup (chroot)
###############################################################################
if skip_phase 6; then
    info "PHASE 5b: ZFS & Kernel — SKIPPED (already completed)"
else
    phase "PHASE 5b: ZFS, Kernel, and Boot Setup"

    setup_chroot_mounts "$MNT"

    cat > "$MNT/tmp/chroot-5b.sh" <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo ""; echo "[chroot] FATAL: command failed (exit $?) at line $LINENO: $BASH_COMMAND"; exit 1' ERR

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export DISK="__DISK__"
export PART_ESP="__PART_ESP__"

apt_retry() {
    local attempt max_attempts=3
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        if apt-get "$@"; then return 0; fi
        echo "[chroot] apt-get failed (attempt $attempt/$max_attempts) — retrying in 10s..."
        sleep 10; apt-get update -qq 2>/dev/null || true
    done
    echo "[chroot] apt-get failed after $max_attempts attempts"; return 1
}

echo "[chroot] Installing ZFS packages (requires internet)..."
apt_retry install --yes zfs-initramfs zfsutils-linux
mkdir -p /etc/dkms
echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf

echo "[chroot] Ensuring kernel headers are installed (needed for ZFS DKMS)..."
apt_retry install --yes --allow-change-held-packages linux-headers-amd64

echo "[chroot] Installing NTP..."
apt_retry install --yes systemd-timesyncd

echo "[chroot] Setting up ESP and GRUB..."
mkdir -p /boot/efi

ESP_UUID=$(blkid -s UUID -o value "$PART_ESP")
grep -q "$ESP_UUID" /etc/fstab 2>/dev/null || \
    echo "UUID=${ESP_UUID} /boot/efi vfat defaults 0 0" >> /etc/fstab
mountpoint -q /boot/efi || mount /boot/efi

echo "[chroot] Installing GRUB + Secure Boot shim (Microsoft-trusted signing chain)..."

apt_retry install --yes grub-efi-amd64 mokutil
apt_retry install --yes sbsigntool 2>/dev/null || \
    echo "[chroot] WARNING: sbsigntool not available — signature verification will be skipped"

# Install shim-signed (with Debian ISO offline fallback)
if ! dpkg -s shim-signed &>/dev/null; then
    echo "[chroot] shim-signed not installed — attempting apt install..."
    if apt_retry install --yes shim-signed 2>/dev/null; then
        echo "[chroot] shim-signed installed from repository."
    elif [[ -d /opt/iso-repo/debian-signed ]] && ls /opt/iso-repo/debian-signed/shim-signed_*.deb &>/dev/null; then
        echo "[chroot] Extracting shim-signed from Debian ISO (offline)..."
        mkdir -p /tmp/shim-signed-extract
        dpkg-deb --extract /opt/iso-repo/debian-signed/shim-signed_*.deb /tmp/shim-signed-extract
        mkdir -p /usr/lib/shim
        cp /tmp/shim-signed-extract/usr/lib/shim/* /usr/lib/shim/ 2>/dev/null || true
        rm -rf /tmp/shim-signed-extract
        echo "[chroot] shim-signed binaries extracted from Debian ISO."
    else
        echo "FATAL: shim-signed not available from repos or Debian ISO. Secure Boot will not work."
        echo "  Provide --debian-iso=PATH pointing to a Debian live ISO for offline fallback."
        exit 1
    fi
else
    echo "[chroot] shim-signed already installed."
fi

# Fetch Debian's signed GRUB binary
if [[ ! -f /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed ]]; then
    if [[ -d /opt/iso-repo/debian-signed ]] && ls /opt/iso-repo/debian-signed/grub-efi-amd64-signed_*.deb &>/dev/null; then
        echo "[chroot] Extracting grub-efi-amd64-signed from Debian ISO (offline)..."
        mkdir -p /tmp/grub-signed-extract
        dpkg-deb --extract /opt/iso-repo/debian-signed/grub-efi-amd64-signed_*.deb /tmp/grub-signed-extract
        mkdir -p /usr/lib/grub/x86_64-efi-signed
        cp /tmp/grub-signed-extract/usr/lib/grub/x86_64-efi-signed/* /usr/lib/grub/x86_64-efi-signed/
        rm -rf /tmp/grub-signed-extract
        echo "[chroot] Signed GRUB binary extracted from Debian ISO."
    else
        echo "[chroot] Downloading grub-efi-amd64-signed from Debian Trixie..."
        echo "deb http://deb.debian.org/debian trixie main" > /etc/apt/sources.list.d/debian-trixie.list
        cat > /etc/apt/preferences.d/debian-trixie.pref <<'PINEOF'
Package: *
Pin: release o=Debian,n=trixie
Pin-Priority: 100
PINEOF
        apt-get update -qq
        cd /tmp
        apt-get download grub-efi-amd64-signed
        mkdir -p /tmp/grub-signed-extract
        dpkg-deb --extract grub-efi-amd64-signed_*.deb /tmp/grub-signed-extract
        mkdir -p /usr/lib/grub/x86_64-efi-signed
        cp /tmp/grub-signed-extract/usr/lib/grub/x86_64-efi-signed/* /usr/lib/grub/x86_64-efi-signed/
        rm -rf /tmp/grub-signed-extract /tmp/grub-efi-amd64-signed_*.deb
        rm -f /etc/apt/sources.list.d/debian-trixie.list /etc/apt/preferences.d/debian-trixie.pref
        apt-get update -qq
        echo "[chroot] Signed GRUB binary downloaded and extracted."
    fi
fi

# Final verification — all signed binaries must be present
echo "[chroot] Verifying signed binary availability..."
SB_READY=true
for sb_check in \
    "/usr/lib/shim/shimx64.efi.signed:shim-signed" \
    "/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed:grub-efi-amd64-signed"; do
    sb_path="${sb_check%%:*}"
    sb_pkg="${sb_check#*:}"
    if [[ -f "$sb_path" ]]; then
        sb_size=$(stat -c%s "$sb_path")
        echo "[chroot]   OK: $sb_pkg — $(basename "$sb_path") ($sb_size bytes)"
    else
        echo "[chroot]   MISSING: $sb_pkg — $sb_path not found!"
        SB_READY=false
    fi
done
if ! $SB_READY; then
    echo "FATAL: Signed binaries missing. Secure Boot chain cannot be built."
    exit 1
fi

echo "[chroot] Removing os-prober (not needed)..."
apt-get purge --yes os-prober 2>/dev/null || true

echo "[chroot] Configuring swap..."
mkswap -f /dev/zvol/rpool/swap
grep -q 'rpool/swap' /etc/fstab 2>/dev/null || \
    echo "/dev/zvol/rpool/swap none swap discard 0 0" >> /etc/fstab
echo "RESUME=none" > /etc/initramfs-tools/conf.d/resume

echo "[chroot] Creating bpool import service..."
cat > /etc/systemd/system/zfs-import-bpool.service <<'SVCEOF'
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/zpool import -N -o cachefile=none -d /dev/disk/by-id bpool
ExecStartPre=-/bin/mv /etc/zfs/zpool.cache /etc/zfs/preboot_zpool.cache
ExecStartPost=-/bin/mv /etc/zfs/preboot_zpool.cache /etc/zfs/zpool.cache

[Install]
WantedBy=zfs-import.target
SVCEOF
systemctl enable zfs-import-bpool.service

echo "[chroot] Phase 5b complete."
CHROOT_EOF

    sed -i "s|__DISK__|${DISK}|g" "$MNT/tmp/chroot-5b.sh"
    sed -i "s|__PART_ESP__|${PART_ESP}|g" "$MNT/tmp/chroot-5b.sh"
    chmod +x "$MNT/tmp/chroot-5b.sh"
    chroot "$MNT" /usr/bin/env bash /tmp/chroot-5b.sh
    rm -f "$MNT/tmp/chroot-5b.sh"
    mark_phase 6
fi

###############################################################################
# PHASE 5c: KDE Plasma Desktop (chroot) — upgrade from XFCE
###############################################################################
if skip_phase 7; then
    info "PHASE 5c: KDE Plasma Desktop — SKIPPED (already completed)"
else
    phase "PHASE 5c: KDE Plasma Desktop (upgrade from ISO's XFCE)"
    setup_chroot_mounts "$MNT"
    generate_desktop_chroot_script > "$MNT/tmp/chroot-5c.sh"
    chmod +x "$MNT/tmp/chroot-5c.sh"
    chroot "$MNT" /usr/bin/env bash /tmp/chroot-5c.sh
    rm -f "$MNT/tmp/chroot-5c.sh"
    mark_phase 7
fi

###############################################################################
# PHASE 5d: GRUB, Initramfs & Boot Finalization (chroot)
###############################################################################
if skip_phase 8; then
    info "PHASE 5d: Boot Finalization — SKIPPED (already completed)"
else
    phase "PHASE 5d: GRUB, Initramfs & Boot Finalization"
    setup_chroot_mounts "$MNT"

    # Build the chroot script: GRUB config + Secure Boot chain install
    cat > "$MNT/tmp/chroot-5d.sh" <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo ""; echo "[chroot] FATAL: command failed (exit $?) at line $LINENO: $BASH_COMMAND"; exit 1' ERR

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

echo "[chroot] Configuring GRUB..."
cat > /etc/default/grub <<'GRUBEOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Kali"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT/kali"
GRUB_TERMINAL=console
GRUB_DISABLE_OS_PROBER=true
GRUBEOF

rm -f /etc/zfs/zpool.cache

echo "[chroot] Updating initramfs..."
update-initramfs -c -k all
CHROOT_EOF

    # Append the Secure Boot chain install code from lib/secureboot.sh
    generate_secureboot_chroot_script >> "$MNT/tmp/chroot-5d.sh"

    # Append GRUB update + ZED + service enablement
    cat >> "$MNT/tmp/chroot-5d.sh" <<'CHROOT_TAIL'

update-grub

echo "[chroot] Setting up ZFS mount ordering (zfs-mount-generator)..."
mkdir -p /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/bpool
touch /etc/zfs/zfs-list.cache/rpool

zed -F &
ZED_PID=$!
sleep 3

zfs set canmount=on     bpool/BOOT/kali 2>/dev/null || true
zfs set canmount=noauto rpool/ROOT/kali 2>/dev/null || true
sleep 2

kill "$ZED_PID" 2>/dev/null || true
wait "$ZED_PID" 2>/dev/null || true

sed -Ei "s|/mnt/kali/?|/|" /etc/zfs/zfs-list.cache/* 2>/dev/null || true

echo "[chroot] Enabling essential services..."
systemctl enable NetworkManager
systemctl enable ssh
systemctl enable zfs-import-cache
systemctl enable zfs-import.target
systemctl enable zfs-mount
systemctl enable zfs.target
systemctl enable zfs-zed

echo "[chroot] Cleaning apt cache to save space..."
apt-get clean

echo "[chroot] Phase 5d complete."
CHROOT_TAIL

    # Replace __DISTRO_NAME__ placeholder in generated secureboot code
    sed -i "s|__DISTRO_NAME__|${DISTRO_NAME}|g" "$MNT/tmp/chroot-5d.sh"
    chmod +x "$MNT/tmp/chroot-5d.sh"
    chroot "$MNT" /usr/bin/env bash /tmp/chroot-5d.sh
    rm -f "$MNT/tmp/chroot-5d.sh"
    mark_phase 8
fi

###############################################################################
# PHASE 5e: User Account Setup (interactive, chroot)
###############################################################################
if skip_phase 9; then
    info "PHASE 5e: User Setup — SKIPPED (already completed)"
else
    phase "PHASE 5e: User Account Setup"
    setup_chroot_mounts "$MNT"

    cat > "$MNT/tmp/chroot-5e.sh" <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo ""; echo "[chroot] FATAL: command failed (exit $?) at line $LINENO: $BASH_COMMAND"; exit 1' ERR

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "[chroot] Setting root password..."
echo "Set the root password for your Kali installation:"
passwd

echo "[chroot] Creating user account..."
echo "Create a regular user account:"
read -rp "Username: " USERNAME
adduser "$USERNAME"
usermod -aG sudo,audio,cdrom,dip,floppy,netdev,plugdev,video "$USERNAME"
zfs create "rpool/home/$USERNAME" 2>/dev/null || true
cp -a /etc/skel/. "/home/$USERNAME/"
mkdir -p "/home/$USERNAME"/{Desktop,Documents,Downloads,Music,Pictures,Videos,Public,Templates}
mkdir -p "/home/$USERNAME/.config"
cat > "/home/$USERNAME/.config/user-dirs.dirs" <<'XDGEOF'
XDG_DESKTOP_DIR="$HOME/Desktop"
XDG_DOWNLOAD_DIR="$HOME/Downloads"
XDG_TEMPLATES_DIR="$HOME/Templates"
XDG_PUBLICSHARE_DIR="$HOME/Public"
XDG_DOCUMENTS_DIR="$HOME/Documents"
XDG_MUSIC_DIR="$HOME/Music"
XDG_PICTURES_DIR="$HOME/Pictures"
XDG_VIDEOS_DIR="$HOME/Videos"
XDGEOF
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
update-desktop-database /usr/share/applications 2>/dev/null || true
echo "[chroot] Configuration complete!"
CHROOT_EOF

    chmod +x "$MNT/tmp/chroot-5e.sh"
    chroot "$MNT" /usr/bin/env bash /tmp/chroot-5e.sh
    rm -f "$MNT/tmp/chroot-5e.sh"
    mark_phase 9
fi

###############################################################################
# PHASE 6: Verify Secure Boot Chain
###############################################################################
if skip_phase 10; then
    info "PHASE 6: Verify Secure Boot Chain — SKIPPED (already completed)"
else
    phase "PHASE 6: Verify Secure Boot Chain"
    verify_secureboot_chain "$MNT"

    info ""
    info "TPM integration:"
    info "  On TPM-equipped machines, Secure Boot extends PCR measurements"
    info "  through the full chain (shim → GRUB → kernel). This provides"
    info "  attestation that the boot path has not been tampered with."
    info "  ZFS decryption uses your passphrase (not TPM-bound)."
    mark_phase 10
fi

###############################################################################
# PHASE 7: Snapshot & Cleanup
###############################################################################
phase "PHASE 7: Snapshot & Cleanup"

# Remove ISO local repo from installed system
info "Cleaning up ISO local repo from installed system..."
rm -rf "$MNT/opt/iso-repo" 2>/dev/null || true
rm -f "$MNT/etc/apt/sources.list.d/iso-local.list" 2>/dev/null || true

# Take initial snapshots
info "Creating initial snapshots..."
zfs snapshot "bpool/BOOT/$DISTRO_NAME@install"
zfs snapshot "rpool/ROOT/$DISTRO_NAME@install"

# Unmount everything (correct order: bind mounts first, then pools)
info "Unmounting filesystems..."
cleanup_mounts "$MNT"

# Export pools
export_pools bpool rpool

# Unmount ISOs
info "Unmounting ISOs..."
[[ -n "${ISO_MNT:-}" ]] && umount "$ISO_MNT" 2>/dev/null && rmdir "$ISO_MNT" 2>/dev/null || true
[[ -n "${DEBIAN_ISO_MNT:-}" ]] && umount "$DEBIAN_ISO_MNT" 2>/dev/null && rmdir "$DEBIAN_ISO_MNT" 2>/dev/null || true

# Clean finish
mark_phase 11
rm -f "$STATEFILE"

###############################################################################
# Done!
###############################################################################
echo ""
phase "Installation Complete!"
echo ""
info "Your portable Kali Linux is installed on: $DISK"
info ""
info "Partition layout:"
info "  Part 1: 512 MiB ESP (FAT32, Microsoft-trusted Secure Boot chain)"
info "  Part 2: 1 GiB   ZFS boot pool (bpool)"
info "  Part 3: 64 GiB  ZFS root pool (rpool, encrypted)"
info "  Rest:   ~53 GiB unallocated (available for future use)"
info ""
info "To boot:"
info "  1. Plug the USB SSD into any UEFI machine"
info "  2. Enter BIOS/UEFI boot menu (usually F12, F2, or Del)"
info "  3. Select the USB drive (shows as '$DISTRO_NAME' or 'UEFI: SAMSUNG')"
info "  4. Enter your ZFS encryption passphrase when prompted"
info ""
info "Secure Boot (password-locked BIOS compatible):"
info "  The entire boot chain is signed with Microsoft-trusted keys."
info "  No BIOS access, key enrollment, or MOK management needed."
info "  Chain: shimx64.efi (MS-signed) → grubx64.efi (Debian-signed) → vmlinuz (signed)"
info ""
info "Snapshots: bpool/BOOT/$DISTRO_NAME@install, rpool/ROOT/$DISTRO_NAME@install"
info "Full install log: $LOGFILE"
echo ""
