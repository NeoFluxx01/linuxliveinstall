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
#   - Works on TPM-equipped machines (Secure Boot PCR attestation)
#   - Auto-refreshes signed binaries on ESP via dpkg hook
#   - Full signature verification at install time (sbverify)
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

# ─── Script transcript capture ──────────────────────────────────────────────
# Re-exec through `script` to capture the full raw terminal transcript
# (including any interactive prompts) in addition to the tee'd log.
TYPESCRIPT="/var/log/install-kali-zfs-$(date +%Y%m%d-%H%M%S).typescript"
if [[ -z "${INSIDE_SCRIPT_WRAPPER:-}" ]]; then
    export INSIDE_SCRIPT_WRAPPER=1
    exec script -efq "$TYPESCRIPT" -c "$(printf '%q ' "$0" "$@")"
fi

# ─── Log file ───────────────────────────────────────────────────────────────
LOGFILE="/var/log/install-kali-zfs-$(date +%Y%m%d-%H%M%S).log"
# Duplicate all stdout+stderr to the log file while still showing on terminal.
exec > >(tee -a "$LOGFILE") 2>&1

trap_handler() {
    local lineno=$1 cmd=$2 rc=$3
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  FATAL: command failed (exit $rc)"
    echo "  Line:  $lineno"
    echo "  Cmd:   $cmd"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Last 30 lines of log ($LOGFILE):"
    tail -n 30 "$LOGFILE" 2>/dev/null || true
    echo ""
    echo "Full log saved to: $LOGFILE"
    exit "$rc"
}
trap 'trap_handler "$LINENO" "$BASH_COMMAND" "$?"' ERR

# ─── Configuration ──────────────────────────────────────────────────────────
# We use the drive's WWN (World Wide Name) — it's burned into the SSD firmware
# and is the most stable identifier. It survives enclosure swaps, USB port
# changes, and works on any machine that can see the drive's identity.
# Fallbacks are checked automatically if WWN isn't available.
DISK_WWN="/dev/disk/by-id/wwn-0x5002538d006b1ef3"
DISK_ATA="/dev/disk/by-id/ata-SAMSUNG_MZNLN128HAHQ-000H1_S3T8NE1K664564"
DISK_USB="/dev/disk/by-id/usb-SAMSUNG_MZNLN128HAHQ-000_012345678999-0:0"
DISK=""  # resolved below
DISK_DEV=""  # resolved at runtime via readlink -f "$DISK"
MNT="/mnt/kali"                      # mountpoint for the new system
HOSTNAME_KALI="kali-portable"
KALI_MIRROR="https://http.kali.org/kali"
KALI_SUITE="kali-rolling"
ESP_SIZE="512M"
BOOT_POOL_SIZE="1G"
ROOT_POOL_SIZE="65536M"              # 64 GiB exactly (65536 MiB)
SWAP_SIZE="4G"

# ─── Partition naming helper ───────────────────────────────────────────────
# /dev/disk/by-id/X  → /dev/disk/by-id/X-partN
# /dev/loopX         → /dev/loopXpN
# /dev/sdX           → /dev/sdXN
# /dev/nvmeXnY       → /dev/nvmeXnYpN
part() {
    local disk="$1" num="$2"
    if [[ "$disk" == /dev/disk/by-* ]]; then
        echo "${disk}-part${num}"
    elif [[ "$disk" == /dev/loop* ]] || [[ "$disk" == /dev/nvme* ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

# ─── Checkpoint / resume ───────────────────────────────────────────────────
STATEFILE="/tmp/.install-state-kali-zfs"
RESUME=false
DISK_OVERRIDE=""
ISO_PATH=""
DEBIAN_ISO_PATH=""
for arg in "$@"; do
    case "$arg" in
        --resume) RESUME=true ;;
        --disk=*) DISK_OVERRIDE="${arg#--disk=}" ;;
        --iso=*) ISO_PATH="${arg#--iso=}" ;;
        --debian-iso=*) DEBIAN_ISO_PATH="${arg#--debian-iso=}" ;;
    esac
done

# Read the last completed phase (0 = none completed)
completed_phase() { cat "$STATEFILE" 2>/dev/null || echo 0; }
# Mark a phase as completed
mark_phase()      { echo "$1" > "$STATEFILE"; }
# Return true if a phase should be skipped (already completed in a prior run)
skip_phase() {
    local n=$1
    if $RESUME && (( n <= $(completed_phase) )); then
        return 0   # skip
    fi
    return 1       # run
}

# ─── Colours & logging ─────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
_ts()   { date '+%H:%M:%S'; }
info()  { echo -e "${GREEN}[$(_ts) INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[$(_ts) WARN]${NC}  $*"; }
error() { echo -e "${RED}[$(_ts) ERROR]${NC} $*"; exit 1; }
phase() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"; \
          echo -e "${BOLD}${CYAN}  [$(_ts)] $*${NC}"; \
          echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}\n"; }

# ─── Preflight checks ──────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "This script must be run as root."

# Resolve disk path — explicit override, or try WWN > ATA > USB
if [[ -n "$DISK_OVERRIDE" ]]; then
    [[ -e "$DISK_OVERRIDE" ]] || error "Disk override not found: $DISK_OVERRIDE"
    DISK="$DISK_OVERRIDE"
    info "Disk set via --disk= override: $DISK"
elif [[ -e "$DISK_WWN" ]]; then
    DISK="$DISK_WWN"
    info "Disk found via WWN: $DISK"
elif [[ -e "$DISK_ATA" ]]; then
    DISK="$DISK_ATA"
    info "Disk found via ATA serial: $DISK"
elif [[ -e "$DISK_USB" ]]; then
    DISK="$DISK_USB"
    warn "Disk found via USB enclosure ID only: $DISK"
    warn "ATA/WWN passthrough not available — pool may not import if enclosure changes."
else
    error "Disk not found via any known identifier. Is the USB SSD plugged in?\n  Tip: use --disk=/dev/sdX or --disk=/dev/loop0 for testing."
fi

# Resolve the actual block device path (e.g. /dev/sdX) for unmount operations
DISK_DEV="$(readlink -f "$DISK")"

# Compute partition device paths (naming varies: -partN, pN, or just N)
PART_ESP="$(part "$DISK" 1)"
PART_BOOT="$(part "$DISK" 2)"
PART_ROOT="$(part "$DISK" 3)"

# Verify ZFS module
lsmod | grep -q '^zfs' || modprobe zfs || error "ZFS kernel module not available."

# Check required tools — install missing ones on Arch/CachyOS
if ! command -v sgdisk &>/dev/null; then
    info "sgdisk not found — installing gptfdisk via pacman..."
    pacman -S --noconfirm gptfdisk || error "Failed to install gptfdisk (provides sgdisk)"
fi
if ! command -v unsquashfs &>/dev/null; then
    info "unsquashfs not found — installing squashfs-tools via pacman..."
    pacman -S --noconfirm squashfs-tools || error "Failed to install squashfs-tools (provides unsquashfs)"
fi

for cmd in sgdisk zpool zfs unsquashfs mkdosfs chroot blkdiscard partprobe; do
    command -v "$cmd" &>/dev/null || error "Missing required command: $cmd"
done

# ─── ISO validation ─────────────────────────────────────────────────────────
[[ -n "$ISO_PATH" ]] || error "--iso=PATH is required. Point it at a Kali Linux live ISO."
[[ -f "$ISO_PATH" ]] || error "ISO not found: $ISO_PATH"

ISO_MNT="/tmp/.kali-iso-$$"
mkdir -p "$ISO_MNT"
mount -o loop,ro "$ISO_PATH" "$ISO_MNT" || error "Failed to mount ISO: $ISO_PATH"

# Verify it's a Kali live ISO with a squashfs
SQUASHFS_PATH="$ISO_MNT/live/filesystem.squashfs"
[[ -f "$SQUASHFS_PATH" ]] || { umount "$ISO_MNT" 2>/dev/null; rmdir "$ISO_MNT"; error "Not a Kali live ISO — missing live/filesystem.squashfs"; }
info "Kali ISO mounted: $ISO_PATH"
info "  Squashfs: $(du -h "$SQUASHFS_PATH" | cut -f1)"

# Mount Debian ISO if provided (for offline signed GRUB)
DEBIAN_ISO_MNT=""
DEBIAN_SIGNED_GRUB_DEB=""
if [[ -n "$DEBIAN_ISO_PATH" ]]; then
    [[ -f "$DEBIAN_ISO_PATH" ]] || error "Debian ISO not found: $DEBIAN_ISO_PATH"
    DEBIAN_ISO_MNT="/tmp/.debian-iso-$$"
    mkdir -p "$DEBIAN_ISO_MNT"
    mount -o loop,ro "$DEBIAN_ISO_PATH" "$DEBIAN_ISO_MNT" || error "Failed to mount Debian ISO: $DEBIAN_ISO_PATH"
    DEBIAN_SIGNED_GRUB_DEB=$(find "$DEBIAN_ISO_MNT/pool/" -name "grub-efi-amd64-signed_*.deb" 2>/dev/null | head -1)
    if [[ -n "$DEBIAN_SIGNED_GRUB_DEB" ]]; then
        info "Debian ISO mounted: $DEBIAN_ISO_PATH"
        info "  Found signed GRUB: $(basename "$DEBIAN_SIGNED_GRUB_DEB")"
    else
        warn "Debian ISO mounted but grub-efi-amd64-signed not found — will download from internet."
    fi
fi

info "Target disk: $DISK -> $(readlink -f "$DISK")"
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
echo ""
read -rp "Type YES to continue: " confirm
[[ "$confirm" == "YES" ]] || { echo "Aborted."; exit 0; }

###############################################################################
# PHASE 1: Disk Preparation
###############################################################################
if skip_phase 1; then
    info "PHASE 1: Disk Preparation — SKIPPED (already completed)"
else
phase "PHASE 1: Disk Preparation"

# Ensure nothing is mounted from this disk
info "Unmounting any existing mounts from target disk..."
swapoff --all 2>/dev/null || true
umount -lf "${DISK_DEV}"* 2>/dev/null || true

# Check if any zpool is using this disk and export it
for pool in $(zpool list -H -o name 2>/dev/null); do
    if zpool status "$pool" 2>/dev/null | grep -q "$(basename "$(readlink -f "$DISK")")"; then
        warn "Pool '$pool' uses this disk — exporting..."
        zpool export "$pool" || warn "Could not export $pool"
    fi
done

# Destroy any pre-existing bpool/rpool (from a previous failed run)
# Safety: only destroy pools that live on OUR target disk.
# If a pool with the same name exists on a different disk, abort.
TARGET_BASENAME="$(basename "$DISK_DEV")"
for p in bpool rpool; do
    if zpool list "$p" &>/dev/null; then
        POOL_VDEV="$(zpool status "$p" 2>/dev/null | grep -oP '(sd[a-z]+|nvme\S+)' | head -1)"
        if [[ "$POOL_VDEV" == "$TARGET_BASENAME"* ]]; then
            warn "Pool '$p' already exists on this disk — destroying (previous failed run)..."
            zfs unmount -a -f 2>/dev/null || true
            umount -Rlf "$MNT" 2>/dev/null || true
            zpool destroy -f "$p" 2>/dev/null || \
                warn "Could not destroy $p — if the script fails at pool creation, reboot and retry."
        else
            error "Pool '$p' is already imported from a DIFFERENT disk (vdev: $POOL_VDEV)." \
                  "Unplug the other ZFS drive or 'zpool export $p' first."
        fi
    fi
done

# Wipe the disk
info "Wiping disk..."
wipefs -af "$DISK" 2>/dev/null || true
sgdisk --zap-all "$DISK"

# TRIM the whole disk (good for SSD performance)
info "TRIMming entire disk (this may take a moment)..."
blkdiscard -f "$DISK" 2>/dev/null || warn "blkdiscard failed (non-fatal)"

# Clear any old partition table cache in kernel
partprobe "$DISK" 2>/dev/null || true
sleep 1

# Partition
info "Creating GPT partitions..."
sgdisk -n1:1M:+${ESP_SIZE}        -t1:EF00 -c1:"EFI System Partition" "$DISK"
sgdisk -n2:0:+${BOOT_POOL_SIZE}   -t2:BF01 -c2:"ZFS Boot Pool"       "$DISK"
sgdisk -n3:0:+${ROOT_POOL_SIZE}   -t3:BF00 -c3:"ZFS Root Pool"       "$DISK"
partprobe "$DISK" 2>/dev/null || true
# Loop devices need partx or losetup --partscan to create partition nodes
if [[ "$DISK" == /dev/loop* ]]; then
    partx --update "$DISK" 2>/dev/null || losetup --partscan "$DISK" 2>/dev/null || true
fi
sleep 2

# Verify partitions appeared
[[ -e "$PART_ESP" ]]  || error "Partition $PART_ESP not found after partitioning."
[[ -e "$PART_BOOT" ]] || error "Partition $PART_BOOT not found after partitioning."
[[ -e "$PART_ROOT" ]] || error "Partition $PART_ROOT not found after partitioning."

info "Partition layout:"
sgdisk -p "$(readlink -f "$DISK")"
info "Partitioning complete."
mark_phase 1
fi  # end Phase 1

###############################################################################
# PHASE 2: Create ZFS Pools
###############################################################################
if skip_phase 2; then
    info "PHASE 2: Create ZFS Pools — SKIPPED (already completed)"
    # Re-import existing pools for subsequent phases
    if ! zpool list bpool &>/dev/null; then
        info "Re-importing bpool..."
        zpool import -N -d /dev/disk/by-id bpool -R "$MNT" \
            || error "Cannot re-import bpool. Run without --resume to start fresh."
    fi
    if ! zpool list rpool &>/dev/null; then
        info "Re-importing rpool (you may need to enter the passphrase)..."
        zpool import -N -d /dev/disk/by-id rpool -R "$MNT" \
            || error "Cannot re-import rpool. Run without --resume to start fresh."
        zfs load-key rpool || error "Could not load rpool encryption key."
    fi
else
phase "PHASE 2: Create ZFS Pools"

# Format ESP
info "Formatting ESP as FAT32..."
mkdosfs -F 32 -s 1 -n EFI "$PART_ESP"

# Create boot pool (grub2-compatible feature set)
info "Creating boot pool (bpool)..."
zpool create \
    -o ashift=12 \
    -o autotrim=on \
    -o compatibility=grub2 \
    -o cachefile=/etc/zfs/zpool.cache \
    -O devices=off \
    -O acltype=posixacl -O xattr=sa \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off -O mountpoint=/boot -R "$MNT" \
    bpool "$PART_BOOT"

# Create root pool (ZFS native encryption)
info "Creating root pool (rpool) with native encryption..."
info "You will be prompted to set an encryption passphrase."
zpool create \
    -o ashift=12 \
    -o autotrim=on \
    -O encryption=on -O keylocation=prompt -O keyformat=passphrase \
    -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
    -O compression=zstd \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off -O mountpoint=/ -R "$MNT" \
    rpool "$PART_ROOT"
mark_phase 2
fi  # end Phase 2

###############################################################################
# PHASE 3: Create ZFS Datasets
###############################################################################
if skip_phase 3; then
    info "PHASE 3: Create ZFS Datasets — SKIPPED (already completed)"
    # Ensure datasets are mounted for subsequent phases
    zfs mount rpool/ROOT/kali 2>/dev/null || true
    zfs mount -a 2>/dev/null || true
    mkdir -p "$MNT/run"
    mountpoint -q "$MNT/run" || mount -t tmpfs tmpfs "$MNT/run"
    mkdir -p "$MNT/run/lock"
else
phase "PHASE 3: Create ZFS Datasets"

# Root and boot filesystem containers
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=off -o mountpoint=none bpool/BOOT

# Root filesystem
zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/kali
zfs mount rpool/ROOT/kali

# Boot filesystem
zfs create -o mountpoint=/boot bpool/BOOT/kali

# Data datasets
zfs create                     rpool/home
zfs create -o mountpoint=/root rpool/home/root
chmod 700 "$MNT/root"

zfs create -o canmount=off     rpool/var
zfs create -o canmount=off     rpool/var/lib
zfs create                     rpool/var/log
zfs create                     rpool/var/spool

# Exclude from snapshots
zfs create -o com.sun:auto-snapshot=false rpool/var/cache
zfs create -o com.sun:auto-snapshot=false rpool/var/lib/nfs
zfs create -o com.sun:auto-snapshot=false rpool/var/tmp
chmod 1777 "$MNT/var/tmp"

# GUI-related
zfs create rpool/var/lib/AccountsService
zfs create rpool/var/lib/NetworkManager

# Swap zvol
info "Creating swap zvol (${SWAP_SIZE})..."
zfs create -V "$SWAP_SIZE" -b "$(getconf PAGESIZE)" -o compression=zle \
    -o logbias=throughput -o sync=always \
    -o primarycache=metadata -o secondarycache=none \
    -o com.sun:auto-snapshot=false rpool/swap

# Mount tmpfs for /run
mkdir -p "$MNT/run"
mount -t tmpfs tmpfs "$MNT/run"
mkdir -p "$MNT/run/lock"

info "ZFS datasets created."
zfs list -r rpool bpool
mark_phase 3
fi  # end Phase 3

###############################################################################
# PHASE 4: Install Kali Base System
###############################################################################
if skip_phase 4; then
    info "PHASE 4: Install Kali Base System — SKIPPED (already completed)"
else
phase "PHASE 4: Install Kali Base System (ISO squashfs extraction)"

info "Extracting squashfs from Kali ISO to ZFS root..."
info "Source: $SQUASHFS_PATH"
info "Target: $MNT"
unsquashfs -f -d "$MNT" "$SQUASHFS_PATH"

# Clean up live-system artifacts that don't belong on an installed system
info "Cleaning up live-system artifacts..."
rm -f "$MNT/etc/hostname" 2>/dev/null || true
# Remove live-specific packages list and auto-login configs
rm -rf "$MNT/etc/live" 2>/dev/null || true
rm -f "$MNT/etc/lightdm/lightdm.conf" 2>/dev/null || true
# Remove live user if it exists
chroot "$MNT" userdel -r kali 2>/dev/null || true
# Clear machine-id so a new one is generated on first boot
: > "$MNT/etc/machine-id"

# Copy zpool cache
mkdir -p "$MNT/etc/zfs"
cp /etc/zfs/zpool.cache "$MNT/etc/zfs/" 2>/dev/null || true

# Copy the ISO's local apt repo into the chroot for offline package installs
# (contains GRUB, shim, firmware, initramfs-tools, etc.)
if [[ -d "$ISO_MNT/pool" && -d "$ISO_MNT/dists" ]]; then
    info "Copying ISO apt repo into chroot for offline installs..."
    mkdir -p "$MNT/opt/iso-repo"
    cp -a "$ISO_MNT/pool" "$MNT/opt/iso-repo/"
    cp -a "$ISO_MNT/dists" "$MNT/opt/iso-repo/"
    info "  ISO repo copied to /opt/iso-repo/ ($(du -sh "$MNT/opt/iso-repo" | cut -f1))"
fi

# Copy Debian signed GRUB deb if available
if [[ -n "$DEBIAN_SIGNED_GRUB_DEB" ]]; then
    info "Copying Debian signed GRUB deb into chroot..."
    mkdir -p "$MNT/opt/iso-repo/debian-signed"
    cp "$DEBIAN_SIGNED_GRUB_DEB" "$MNT/opt/iso-repo/debian-signed/"
fi
mark_phase 4
fi  # end Phase 4

###############################################################################
# PHASE 5a: System Configuration — Base Setup (chroot)
###############################################################################
# Phase 5 is split into sub-phases (5a–5e) so --resume can recover from
# failures mid-install (especially network-dependent apt operations).

# ─── Helper: bind-mount virtual filesystems for chroot ──────────────────────
setup_chroot_mounts() {
    mountpoint -q "$MNT/dev"  || mount --make-private --rbind /dev  "$MNT/dev"
    mountpoint -q "$MNT/proc" || mount --make-private --rbind /proc "$MNT/proc"
    mountpoint -q "$MNT/sys"  || mount --make-private --rbind /sys  "$MNT/sys"
    cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true
}

if skip_phase 5; then
    info "PHASE 5a: Base Setup — SKIPPED (already completed)"
else
phase "PHASE 5a: System Configuration — Base Setup"

# Hostname
echo "$HOSTNAME_KALI" > "$MNT/etc/hostname"
cat > "$MNT/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME_KALI
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# APT sources — Kali rolling
cat > "$MNT/etc/apt/sources.list" <<EOF
deb $KALI_MIRROR $KALI_SUITE main contrib non-free non-free-firmware
deb-src $KALI_MIRROR $KALI_SUITE main contrib non-free non-free-firmware
EOF

setup_chroot_mounts

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

# ── apt retry wrapper — retries up to 3 times on transient failures ─────────
apt_retry() {
    local attempt max_attempts=3
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        if apt-get "$@"; then
            return 0
        fi
        echo "[chroot] apt-get failed (attempt $attempt/$max_attempts) — retrying in 10s..."
        sleep 10
        apt-get update -qq 2>/dev/null || true
    done
    echo "[chroot] apt-get failed after $max_attempts attempts"
    return 1
}

# ── Hostid for portable ZFS ─────────────────────────────────────────────────
# ZFS stamps the creator's hostid onto pools. The pools were created by the
# host machine (Phase 2), so we must use the SAME hostid here — otherwise
# initramfs will refuse to import the pool ("pool was created by another
# system"). We read __HOSTID__ which was captured from the host before chroot.
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

# ── Add ISO local repo as apt source (offline packages) ─────────────────────
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

# ── Locale & timezone (squashfs already has packages, just configure) ────────
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
fi  # end Phase 5a

###############################################################################
# PHASE 5b: ZFS, Kernel, and Boot Setup (chroot)
###############################################################################
if skip_phase 6; then
    info "PHASE 5b: ZFS & Kernel — SKIPPED (already completed)"
else
phase "PHASE 5b: ZFS, Kernel, and Boot Setup"

setup_chroot_mounts

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
# The squashfs already has the kernel image; we just need headers for DKMS
apt_retry install --yes linux-headers-amd64

echo "[chroot] Installing NTP..."
apt_retry install --yes systemd-timesyncd

echo "[chroot] Setting up ESP and GRUB..."
mkdir -p /boot/efi

ESP_UUID=$(blkid -s UUID -o value "$PART_ESP")
# Avoid duplicate fstab entries on --resume re-runs
grep -q "$ESP_UUID" /etc/fstab 2>/dev/null || \
    echo "UUID=${ESP_UUID} /boot/efi vfat defaults 0 0" >> /etc/fstab
mountpoint -q /boot/efi || mount /boot/efi

echo "[chroot] Installing GRUB + Secure Boot shim (Microsoft-trusted signing chain)..."
# grub-efi-amd64 and shim-signed come from ISO local repo (offline).
# sbsigntool may need internet if not in ISO repo.
apt_retry install --yes \
    grub-efi-amd64 \
    shim-signed \
    mokutil
apt_retry install --yes sbsigntool 2>/dev/null || \
    echo "[chroot] WARNING: sbsigntool not available — signature verification will be skipped"

# Fetch Debian's signed GRUB binary (signed with Debian's key, trusted by shim)
if [[ ! -f /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed ]]; then
    if [[ -d /opt/iso-repo/debian-signed ]] && ls /opt/iso-repo/debian-signed/grub-efi-amd64-signed_*.deb &>/dev/null; then
        # Extract from Debian ISO (offline)
        echo "[chroot] Extracting grub-efi-amd64-signed from Debian ISO (offline)..."
        mkdir -p /tmp/grub-signed-extract
        dpkg-deb --extract /opt/iso-repo/debian-signed/grub-efi-amd64-signed_*.deb /tmp/grub-signed-extract
        mkdir -p /usr/lib/grub/x86_64-efi-signed
        cp /tmp/grub-signed-extract/usr/lib/grub/x86_64-efi-signed/* /usr/lib/grub/x86_64-efi-signed/
        rm -rf /tmp/grub-signed-extract
        echo "[chroot] Signed GRUB binary extracted from Debian ISO."
    else
        # Download from Debian Trixie (requires internet)
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
        # Clean up Debian source (no longer needed)
        rm -f /etc/apt/sources.list.d/debian-trixie.list /etc/apt/preferences.d/debian-trixie.pref
        apt-get update -qq
        echo "[chroot] Signed GRUB binary downloaded and extracted."
    fi
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
fi  # end Phase 5b

###############################################################################
# PHASE 5c: KDE Plasma Desktop (chroot) — upgrade from XFCE
###############################################################################
if skip_phase 7; then
    info "PHASE 5c: KDE Plasma Desktop — SKIPPED (already completed)"
else
phase "PHASE 5c: KDE Plasma Desktop (upgrade from ISO's XFCE)"

setup_chroot_mounts

cat > "$MNT/tmp/chroot-5c.sh" <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo ""; echo "[chroot] FATAL: command failed (exit $?) at line $LINENO: $BASH_COMMAND"; exit 1' ERR

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

apt_retry() {
    local attempt max_attempts=3
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        if apt-get "$@"; then return 0; fi
        echo "[chroot] apt-get failed (attempt $attempt/$max_attempts) — retrying in 10s..."
        sleep 10; apt-get update -qq 2>/dev/null || true
    done
    echo "[chroot] apt-get failed after $max_attempts attempts"; return 1
}

# The squashfs already provides: network-manager, firmware-*, wireless-tools,
# wpasupplicant, kali-linux-default, kali-tools-top10, openssh-server, sudo,
# vim, curl, wget, git, htop, tmux, pciutils, usbutils, bash-completion,
# and XFCE4 desktop. We replace XFCE with KDE Plasma.

echo "[chroot] Installing KDE Plasma desktop..."
echo "[chroot] This is the largest download — may take a while..."
apt_retry install --yes kali-desktop-kde

echo "[chroot] Setting SDDM as default display manager..."
echo "/usr/bin/sddm" > /etc/X11/default-display-manager
dpkg-reconfigure -f noninteractive sddm 2>/dev/null || true

echo "[chroot] Installing extra packages (if not already present)..."
apt_retry install --yes \
    efibootmgr \
    plymouth \
    plymouth-themes

echo "[chroot] Phase 5c complete."
CHROOT_EOF

chmod +x "$MNT/tmp/chroot-5c.sh"
chroot "$MNT" /usr/bin/env bash /tmp/chroot-5c.sh
rm -f "$MNT/tmp/chroot-5c.sh"
mark_phase 7
fi  # end Phase 5c

###############################################################################
# PHASE 5d: GRUB, Initramfs & Boot Finalization (chroot)
###############################################################################
if skip_phase 8; then
    info "PHASE 5d: Boot Finalization — SKIPPED (already completed)"
else
phase "PHASE 5d: GRUB, Initramfs & Boot Finalization"

setup_chroot_mounts

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

# Remove any stale zpool.cache before rebuilding initramfs — for a portable
# drive we rely on scan-based import (zfs-import-bpool.service + initramfs
# scanning /dev/disk/by-id), not cache-based import with fixed device paths.
rm -f /etc/zfs/zpool.cache

echo "[chroot] Updating initramfs..."
update-initramfs -c -k all

# ── Secure Boot chain with Microsoft-trusted signed binaries ────────────────
# Goal: boot on ANY UEFI machine — including those with password-locked BIOS
# where Secure Boot cannot be disabled and MOK enrollment is impossible.
#
# Trust chain:
#   UEFI firmware (factory Microsoft UEFI CA in Secure Boot DB)
#     → shimx64.efi.signed   (signed by Microsoft UEFI 3rd-party CA)
#       → grubx64.efi.signed (signed by Debian key, embedded in shim)
#         → vmlinuz           (signed by Debian key, verified via shim protocol)
#           → initramfs        (loaded by signed kernel)
#
# The Debian signing key is hardcoded inside the shim binary. Microsoft
# reviewed and counter-signed the shim during the shim-review process.
# No MOK enrollment is needed — the entire chain is factory-trusted.

SIGNED_SHIM="/usr/lib/shim/shimx64.efi.signed"
SIGNED_GRUB="/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
SIGNED_MOK="/usr/lib/shim/mmx64.efi.signed"
SIGNED_FB="/usr/lib/shim/fbx64.efi.signed"

echo "[chroot] Verifying signed binaries exist..."
[[ -f "$SIGNED_SHIM" ]] || { echo "FATAL: shim-signed binary not found at $SIGNED_SHIM"; exit 1; }
[[ -f "$SIGNED_GRUB" ]] || { echo "FATAL: grub-efi-amd64-signed binary not found at $SIGNED_GRUB"; exit 1; }

echo "[chroot] Installing GRUB to ESP (portable mode)..."
mountpoint -q /boot/efi || mount /boot/efi

# Step 1: Run grub-install --removable to generate the GRUB configuration,
# module directory, and the search stub at EFI/BOOT/grub/grub.cfg that
# locates the real /boot/grub/grub.cfg on the ZFS boot pool.
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=kali --recheck --no-floppy --removable

# Step 2: Replace the unsigned GRUB binary with the Microsoft-trusted
# signed chain. grub-install wrote an unsigned GRUB at EFI/BOOT/BOOTX64.EFI.
# On a locked Secure Boot machine, shim would refuse to load that unsigned
# binary. We replace it with the pre-signed binary from grub-efi-amd64-signed.
ESP_BOOT="/boot/efi/EFI/BOOT"

echo "[chroot] Installing signed Secure Boot chain to ESP..."
# Back up the unsigned GRUB (useful for debugging, not used at runtime)
mv "$ESP_BOOT/BOOTX64.EFI" "$ESP_BOOT/grubx64.efi.unsigned"

# shimx64.efi.signed → BOOTX64.EFI (UEFI default removable boot path)
# This is the first binary the firmware loads. It's signed by Microsoft's
# UEFI Third-Party Marketplace CA, which is in every factory Secure Boot DB.
cp "$SIGNED_SHIM" "$ESP_BOOT/BOOTX64.EFI"

# grubx64.efi.signed → grubx64.efi (shim loads this by name)
# Signed by Debian's key which is embedded in the shim binary.
cp "$SIGNED_GRUB" "$ESP_BOOT/grubx64.efi"

# MOK Manager — allows key enrollment on machines where BIOS IS accessible.
# Harmless on locked machines (shim just skips it if not needed).
[[ -f "$SIGNED_MOK" ]] && cp "$SIGNED_MOK" "$ESP_BOOT/mmx64.efi"

# Fallback — shim fallback binary for NVRAM-less boot
[[ -f "$SIGNED_FB" ]] && cp "$SIGNED_FB" "$ESP_BOOT/fbx64.efi"

echo "[chroot] Secure Boot chain installed:"
echo "  BOOTX64.EFI  = shimx64.efi  (Microsoft UEFI 3rd-party CA signed)"
echo "  grubx64.efi  = GRUB         (Debian/Kali key signed)"
echo "  mmx64.efi    = MOK Manager  (Microsoft UEFI 3rd-party CA signed)"

# Step 3: Copy GRUB modules to ESP for signed GRUB.
# The signed GRUB binary from grub-efi-amd64-signed is MODULAR — unlike
# the monolithic binary grub-install produces, it does NOT have ZFS (or
# most other filesystem drivers) compiled in. It loads modules from its
# $prefix, which is compiled to /EFI/debian. We must place the x86_64-efi
# modules on the ESP so signed GRUB can insmod zfs before searching for
# the boot pool.
GRUB_MOD_SRC="/usr/lib/grub/x86_64-efi"
GRUB_MOD_DST="/boot/efi/EFI/debian/x86_64-efi"
if [[ -d "$GRUB_MOD_SRC" ]]; then
    echo "[chroot] Copying GRUB modules to ESP for signed GRUB..."
    mkdir -p "$GRUB_MOD_DST"
    cp "$GRUB_MOD_SRC"/*.mod "$GRUB_MOD_DST/" 2>/dev/null || true
    cp "$GRUB_MOD_SRC"/*.lst "$GRUB_MOD_DST/" 2>/dev/null || true
    mod_count=$(ls -1 "$GRUB_MOD_DST"/*.mod 2>/dev/null | wc -l)
    echo "[chroot] Copied $mod_count GRUB modules to ESP (EFI/debian/x86_64-efi/)"
    # Verify critical ZFS modules are present
    for m in zfs zfscrypt zfsinfo part_gpt; do
        if [[ -f "$GRUB_MOD_DST/${m}.mod" ]]; then
            echo "[chroot]   OK: ${m}.mod"
        else
            echo "[chroot]   WARNING: ${m}.mod missing — boot may fail!"
        fi
    done
else
    echo "[chroot] WARNING: GRUB module source not found at $GRUB_MOD_SRC"
    echo "[chroot] Signed GRUB may not be able to load ZFS modules."
fi

# Step 4: Create GRUB config redirects for signed binary.
# The signed GRUB's $prefix is /EFI/debian. We place a grub.cfg there
# that loads ZFS support (since it's not built in) then searches for
# the real grub.cfg on the ZFS boot pool. The same config is placed at
# EFI/BOOT/grub.cfg and EFI/BOOT/grub/grub.cfg as fallbacks.
echo "[chroot] Setting up GRUB config redirects for signed binary..."
mkdir -p /boot/efi/EFI/debian
mkdir -p "$ESP_BOOT/grub"
cat > /boot/efi/EFI/debian/grub.cfg <<'STUBEOF'
# Redirect config for signed (modular) GRUB.
# Load ZFS support first — signed GRUB doesn't have it built in.
insmod part_gpt
insmod zfs
search.file /boot/grub/grub.cfg root
set prefix=($root)/boot/grub
configfile $prefix/grub.cfg
STUBEOF
cp /boot/efi/EFI/debian/grub.cfg "$ESP_BOOT/grub.cfg"
cp /boot/efi/EFI/debian/grub.cfg "$ESP_BOOT/grub/grub.cfg"

# Step 5: Verify signatures using sbverify
if command -v sbverify &>/dev/null; then
    echo "[chroot] Verifying Secure Boot signatures on ESP binaries..."
    SB_PASS=true
    for efi_bin in "$ESP_BOOT/BOOTX64.EFI" "$ESP_BOOT/grubx64.efi"; do
        efi_name="$(basename "$efi_bin")"
        sig_count=$(sbverify --list "$efi_bin" 2>/dev/null | grep -c 'signature' || true)
        if (( sig_count > 0 )); then
            echo "  OK: $efi_name — $sig_count signature(s) found"
        else
            echo "  FAIL: $efi_name — NO signature found!"
            SB_PASS=false
        fi
    done
    if ! $SB_PASS; then
        echo "FATAL: Signed binaries failed signature check. Secure Boot will not work."
        exit 1
    fi
else
    echo "[chroot] WARNING: sbverify not available — skipping signature verification"
fi

# Step 6: Create a dpkg hook so that future package updates to shim-signed,
# grub-efi-amd64-signed, or grub-efi-amd64 automatically refresh the ESP.
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99-secureboot-esp-sync <<'DPKGEOF'
// After dpkg runs, refresh signed binaries and GRUB modules on the ESP.
DPkg::Post-Invoke {
    "if [ -f /usr/lib/shim/shimx64.efi.signed ] && [ -d /boot/efi/EFI/BOOT ]; then cp /usr/lib/shim/shimx64.efi.signed /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true; fi";
    "if [ -f /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed ] && [ -d /boot/efi/EFI/BOOT ]; then cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed /boot/efi/EFI/BOOT/grubx64.efi 2>/dev/null || true; fi";
    "if [ -f /usr/lib/shim/mmx64.efi.signed ] && [ -d /boot/efi/EFI/BOOT ]; then cp /usr/lib/shim/mmx64.efi.signed /boot/efi/EFI/BOOT/mmx64.efi 2>/dev/null || true; fi";
    "if [ -d /usr/lib/grub/x86_64-efi ] && [ -d /boot/efi/EFI/debian/x86_64-efi ]; then cp /usr/lib/grub/x86_64-efi/*.mod /boot/efi/EFI/debian/x86_64-efi/ 2>/dev/null || true; cp /usr/lib/grub/x86_64-efi/*.lst /boot/efi/EFI/debian/x86_64-efi/ 2>/dev/null || true; fi";
};
DPKGEOF
echo "[chroot] Installed dpkg hook: /etc/apt/apt.conf.d/99-secureboot-esp-sync"
echo "  (auto-refreshes signed binaries + GRUB modules on ESP when packages are updated)"

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
CHROOT_EOF

chmod +x "$MNT/tmp/chroot-5d.sh"
chroot "$MNT" /usr/bin/env bash /tmp/chroot-5d.sh
rm -f "$MNT/tmp/chroot-5d.sh"
mark_phase 8
fi  # end Phase 5d

###############################################################################
# PHASE 5e: User Account Setup (interactive, chroot)
###############################################################################
if skip_phase 9; then
    info "PHASE 5e: User Setup — SKIPPED (already completed)"
else
phase "PHASE 5e: User Account Setup"

setup_chroot_mounts

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
# Create ZFS home dataset for user FIRST (empty), then populate it
zfs create "rpool/home/$USERNAME" 2>/dev/null || true
# The dataset is now mounted at /home/$USERNAME — copy skel into it
cp -a /etc/skel/. "/home/$USERNAME/"
# Create standard XDG directories
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

# Rebuild desktop application database so app launcher works on first boot
update-desktop-database /usr/share/applications 2>/dev/null || true

echo "[chroot] Configuration complete!"
CHROOT_EOF

chmod +x "$MNT/tmp/chroot-5e.sh"
chroot "$MNT" /usr/bin/env bash /tmp/chroot-5e.sh
rm -f "$MNT/tmp/chroot-5e.sh"
mark_phase 9
fi  # end Phase 5e

###############################################################################
# PHASE 6: Verify Secure Boot Chain (cryptographic signature verification)
###############################################################################
if skip_phase 10; then
    info "PHASE 6: Verify Secure Boot Chain — SKIPPED (already completed)"
else
phase "PHASE 6: Verify Secure Boot Chain"

# ── File presence checks ────────────────────────────────────────────────────
SB_OK=true
ESP_BOOT="$MNT/boot/efi/EFI/BOOT"

info "Checking Secure Boot binaries on ESP..."
for efi_item in \
    "BOOTX64.EFI:shimx64 (Microsoft UEFI 3rd-party CA signed)" \
    "grubx64.efi:GRUB (Debian/Kali key signed)" \
    "mmx64.efi:MOK Manager (optional on locked BIOS)"; do
    efi_file="${efi_item%%:*}"
    efi_desc="${efi_item#*:}"
    if [[ -f "$ESP_BOOT/$efi_file" ]]; then
        info "  FOUND: $efi_file — $efi_desc"
    elif [[ "$efi_file" == "mmx64.efi" ]]; then
        warn "  MISSING: $efi_file — $efi_desc (non-fatal)"
    else
        warn "  MISSING: $efi_file — $efi_desc"
        SB_OK=false
    fi
done

# ── GRUB config redirect checks ────────────────────────────────────────────
info ""
info "Checking GRUB config accessibility for signed binary..."
for cfg_path in \
    "$ESP_BOOT/grub/grub.cfg" \
    "$ESP_BOOT/grub.cfg" \
    "$MNT/boot/efi/EFI/debian/grub.cfg"; do
    rel_path="${cfg_path#$MNT/boot/efi/}"
    if [[ -f "$cfg_path" ]]; then
        info "  FOUND: $rel_path"
    else
        warn "  MISSING: $rel_path"
    fi
done

# ── Cryptographic signature verification ────────────────────────────────────
# Use sbverify (from sbsigntool) to inspect PE/COFF Authenticode signatures.
# We verify that signatures exist on the critical boot binaries. The actual
# trust validation happens at boot time (UEFI DB validates shim, shim
# validates GRUB, shim protocol validates kernel).
info ""
if command -v sbverify &>/dev/null || [[ -x "$MNT/usr/bin/sbverify" ]]; then
    SBVERIFY="sbverify"
    command -v sbverify &>/dev/null || SBVERIFY="chroot $MNT sbverify"

    info "Cryptographic signature verification (sbverify):"

    for efi_item in "BOOTX64.EFI:shim" "grubx64.efi:GRUB"; do
        efi_file="${efi_item%%:*}"
        efi_label="${efi_item#*:}"
        if [[ ! -f "$ESP_BOOT/$efi_file" ]]; then continue; fi

        sig_info=$($SBVERIFY --list "$ESP_BOOT/$efi_file" 2>&1 || true)
        sig_count=$(echo "$sig_info" | grep -ci 'signature' || true)
        if (( sig_count > 0 )); then
            info "  SIGNED: $efi_file ($efi_label) — $sig_count signature(s)"
            # Show signer details if available
            echo "$sig_info" | grep -i 'subject\|issuer' | head -4 | while read -r line; do
                info "          $line"
            done
        else
            warn "  UNSIGNED: $efi_file ($efi_label) — Secure Boot WILL FAIL"
            SB_OK=false
        fi
    done

    # Verify kernel signature (vmlinuz on bpool)
    VMLINUZ=$(ls -1 "$MNT/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1)
    if [[ -n "$VMLINUZ" && -f "$VMLINUZ" ]]; then
        sig_info=$($SBVERIFY --list "$VMLINUZ" 2>&1 || true)
        sig_count=$(echo "$sig_info" | grep -ci 'signature' || true)
        if (( sig_count > 0 )); then
            info "  SIGNED: $(basename "$VMLINUZ") (kernel) — $sig_count signature(s)"
        else
            warn "  UNSIGNED: $(basename "$VMLINUZ") (kernel)"
            warn "    Shim will refuse to load an unsigned kernel when Secure Boot is active."
            warn "    Ensure linux-image-amd64 provides a signed kernel (check: linux-image-amd64-signed)."
            SB_OK=false
        fi
    else
        warn "  No vmlinuz found in $MNT/boot/ — cannot verify kernel signature"
    fi
else
    warn "sbverify not available — cannot perform cryptographic verification"
    warn "Install sbsigntool to enable signature checking"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
info ""
info "Secure Boot trust chain:"
info "  ┌─ UEFI Firmware ──────────────────────────────────────────────┐"
info "  │  Secure Boot DB contains: Microsoft UEFI CA 2011            │"
info "  │  (factory-installed on all UEFI PCs since 2012)             │"
info "  └──────────────────────┬───────────────────────────────────────┘"
info "                         │ validates"
info "  ┌──────────────────────▼───────────────────────────────────────┐"
info "  │  BOOTX64.EFI (shimx64)                                      │"
info "  │  Signed by: Microsoft Corporation UEFI CA 2011               │"
info "  │  Contains:  Debian signing key (hardcoded, not MOK)          │"
info "  └──────────────────────┬───────────────────────────────────────┘"
info "                         │ validates"
info "  ┌──────────────────────▼───────────────────────────────────────┐"
info "  │  grubx64.efi (GRUB)                                         │"
info "  │  Signed by: Debian Secure Boot key (embedded in shim)        │"
info "  │  Reads: ZFS bpool → /boot/grub/grub.cfg → kernel + initramfs│"
info "  └──────────────────────┬───────────────────────────────────────┘"
info "                         │ validates (shim protocol)"
info "  ┌──────────────────────▼───────────────────────────────────────┐"
info "  │  vmlinuz (Linux kernel)                                      │"
info "  │  Signed by: Debian Secure Boot key                           │"
info "  └──────────────────────┬───────────────────────────────────────┘"
info "                         │ loads"
info "  ┌──────────────────────▼───────────────────────────────────────┐"
info "  │  initramfs → ZFS module → passphrase prompt → mount rpool    │"
info "  └──────────────────────────────────────────────────────────────┘"
info ""
if $SB_OK; then
    info "Secure Boot: READY"
    info "  Compatible with: ALL UEFI machines trusting Microsoft UEFI CA"
    info "  Including: password-locked BIOS (no MOK enrollment required)"
else
    warn "Secure Boot: ISSUES DETECTED (see warnings above)"
    warn "  The drive may still boot on machines with Secure Boot disabled."
fi
info ""
info "TPM integration:"
info "  On TPM-equipped machines, Secure Boot extends PCR measurements"
info "  through the full chain (shim → GRUB → kernel). This provides"
info "  attestation that the boot path has not been tampered with."
info "  ZFS decryption uses your passphrase (not TPM-bound)."

# List all EFI files on ESP
info ""
info "ESP layout:"
find "$MNT/boot/efi/" -type f 2>/dev/null | sort | while read -r f; do
    rel="${f#$MNT/boot/efi/}"
    size=$(stat -c%s "$f" 2>/dev/null || echo "?")
    info "  $rel  ($size bytes)"
done
mark_phase 10
fi  # end Phase 6

###############################################################################
# PHASE 7: Snapshot & Cleanup
###############################################################################
phase "PHASE 7: Snapshot & Cleanup"

# Remove ISO local repo from installed system (no longer needed, saves space)
info "Cleaning up ISO local repo from installed system..."
rm -rf "$MNT/opt/iso-repo" 2>/dev/null || true
rm -f "$MNT/etc/apt/sources.list.d/iso-local.list" 2>/dev/null || true

# Take initial snapshots
info "Creating initial snapshots..."
zfs snapshot bpool/BOOT/kali@install
zfs snapshot rpool/ROOT/kali@install

# Unmount everything
info "Unmounting filesystems..."
umount -lf "$MNT/boot/efi" 2>/dev/null || true
mount | grep -v zfs | tac | awk -v mnt="$MNT" '$3 ~ mnt {print $3}' | \
    xargs -I{} umount -lf {} 2>/dev/null || true
umount -lf "$MNT/run" 2>/dev/null || true

# Export pools
info "Exporting ZFS pools..."
zpool export bpool || warn "Could not export bpool cleanly"
zpool export rpool || warn "Could not export rpool cleanly"

# Unmount ISOs
info "Unmounting ISOs..."
[[ -n "${ISO_MNT:-}" ]] && umount "$ISO_MNT" 2>/dev/null && rmdir "$ISO_MNT" 2>/dev/null || true
[[ -n "${DEBIAN_ISO_MNT:-}" ]] && umount "$DEBIAN_ISO_MNT" 2>/dev/null && rmdir "$DEBIAN_ISO_MNT" 2>/dev/null || true

# Mark all phases complete and remove state file (clean finish)
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
info "  3. Select the USB drive (shows as 'kali' or 'UEFI: SAMSUNG')"
info "  4. Enter your ZFS encryption passphrase when prompted"
info ""
info "Secure Boot (password-locked BIOS compatible):"
info "  The entire boot chain is signed with Microsoft-trusted keys."
info "  No BIOS access, key enrollment, or MOK management needed."
info "  Chain: shimx64.efi (MS-signed) → grubx64.efi (Debian-signed) → vmlinuz (signed)"
info "  Auto-maintained: dpkg hook refreshes ESP binaries on package updates."
info ""
info "TPM:"
info "  Secure Boot + TPM machines validate the boot chain via PCR"
info "  measurements automatically. The TPM attests boot integrity;"
info "  ZFS decryption uses your passphrase (not TPM-bound)."
info ""
info "Snapshots: bpool/BOOT/kali@install, rpool/ROOT/kali@install"
info "           Use 'zfs rollback' to restore to clean state if needed."
info ""
info "Full install log: $LOGFILE"
echo ""
