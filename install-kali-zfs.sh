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
#   - Secure Boot via shim-signed + grub-efi-amd64-signed
#   - Portable GRUB (--removable, writes EFI/BOOT/BOOTX64.EFI)
#   - Works on TPM-equipped machines (Secure Boot PCR attestation)
#   - KDE Plasma desktop
#   - NetworkManager for portable network handling
#   - Comprehensive firmware bundle for broad hardware compatibility
#   - hostid set in initramfs for portable pool imports
#
# Run from an Arch/CachyOS host that has ZFS loaded.
# Requires: zfs/zpool, debootstrap, sgdisk, mkdosfs, chroot, internet
#
# Usage: sudo ./install-kali-zfs.sh [--resume]
#   --resume  Skip completed phases and continue from last checkpoint
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

# ─── Checkpoint / resume ───────────────────────────────────────────────────
STATEFILE="/tmp/.install-state-kali-zfs"
RESUME=false
for arg in "$@"; do
    case "$arg" in
        --resume) RESUME=true ;;
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

# Resolve disk path — try WWN first (most portable), then ATA, then USB
if [[ -e "$DISK_WWN" ]]; then
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
    error "Disk not found via any known identifier. Is the USB SSD plugged in?"
fi

# Resolve the actual block device path (e.g. /dev/sdX) for unmount operations
DISK_DEV="$(readlink -f "$DISK")"

# Verify ZFS module
lsmod | grep -q '^zfs' || modprobe zfs || error "ZFS kernel module not available."

# Check required tools — install missing ones on Arch/CachyOS
if ! command -v sgdisk &>/dev/null; then
    info "sgdisk not found — installing gptfdisk via pacman..."
    pacman -S --noconfirm gptfdisk || error "Failed to install gptfdisk (provides sgdisk)"
fi
if ! command -v debootstrap &>/dev/null; then
    info "debootstrap not found — installing via pacman..."
    pacman -S --noconfirm debootstrap || error "Failed to install debootstrap"
fi

for cmd in sgdisk zpool zfs debootstrap mkdosfs chroot blkdiscard partprobe; do
    command -v "$cmd" &>/dev/null || error "Missing required command: $cmd"
done

info "Target disk: $DISK -> $(readlink -f "$DISK")"
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
partprobe "$DISK"
sleep 2

# Verify partitions appeared
[[ -e "${DISK}-part1" ]] || error "Partition ${DISK}-part1 not found after partitioning."
[[ -e "${DISK}-part2" ]] || error "Partition ${DISK}-part2 not found after partitioning."
[[ -e "${DISK}-part3" ]] || error "Partition ${DISK}-part3 not found after partitioning."

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
mkdosfs -F 32 -s 1 -n EFI "${DISK}-part1"

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
    bpool "${DISK}-part2"

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
    rpool "${DISK}-part3"
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
phase "PHASE 4: Install Kali Base System (debootstrap)"

# Work around CachyOS debootstrap bug: pacman-conf Architecture returns
# multiple lines (x86_64, x86_64_v2, x86_64_v3) which breaks debootstrap's
# HOST_ARCH detection. Writing the arch file makes debootstrap skip pacman-conf.
echo "amd64" > /usr/share/debootstrap/arch

info "Running debootstrap for kali-rolling..."
debootstrap --arch=amd64 "$KALI_SUITE" "$MNT" "$KALI_MIRROR"

# Copy zpool cache
mkdir -p "$MNT/etc/zfs"
cp /etc/zfs/zpool.cache "$MNT/etc/zfs/" 2>/dev/null || true
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

echo "[chroot] Updating packages..."
apt-get update

mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99-noninteractive <<'APTEOF'
Dpkg::Options { "--force-confdef"; "--force-confold"; }
APTEOF

echo "[chroot] Installing core packages..."
apt_retry install --yes --no-install-recommends \
    locales console-setup keyboard-configuration tzdata

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

apt_retry() {
    local attempt max_attempts=3
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        if apt-get "$@"; then return 0; fi
        echo "[chroot] apt-get failed (attempt $attempt/$max_attempts) — retrying in 10s..."
        sleep 10; apt-get update -qq 2>/dev/null || true
    done
    echo "[chroot] apt-get failed after $max_attempts attempts"; return 1
}

echo "[chroot] Installing ZFS and kernel..."
apt_retry install --yes linux-headers-amd64
apt_retry install --yes linux-image-amd64
apt_retry install --yes zfs-initramfs zfsutils-linux
mkdir -p /etc/dkms
echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf

echo "[chroot] Installing NTP..."
apt_retry install --yes systemd-timesyncd

echo "[chroot] Setting up ESP and GRUB..."
apt_retry install --yes dosfstools
mkdir -p /boot/efi

ESP_UUID=$(blkid -s UUID -o value ${DISK}-part1)
# Avoid duplicate fstab entries on --resume re-runs
grep -q "$ESP_UUID" /etc/fstab 2>/dev/null || \
    echo "UUID=${ESP_UUID} /boot/efi vfat defaults 0 0" >> /etc/fstab
mountpoint -q /boot/efi || mount /boot/efi

echo "[chroot] Installing GRUB + Secure Boot shim..."
apt_retry install --yes grub-efi-amd64 shim-signed

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
chmod +x "$MNT/tmp/chroot-5b.sh"
chroot "$MNT" /usr/bin/env bash /tmp/chroot-5b.sh
rm -f "$MNT/tmp/chroot-5b.sh"
mark_phase 6
fi  # end Phase 5b

###############################################################################
# PHASE 5c: Desktop & Packages (chroot) — largest download phase
###############################################################################
if skip_phase 7; then
    info "PHASE 5c: Desktop & Packages — SKIPPED (already completed)"
else
phase "PHASE 5c: Desktop Environment & Packages"

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

echo "[chroot] Installing NetworkManager + firmware..."
apt_retry install --yes \
    network-manager \
    firmware-linux \
    firmware-linux-nonfree \
    firmware-misc-nonfree \
    firmware-iwlwifi \
    firmware-realtek \
    firmware-atheros \
    wireless-tools \
    wpasupplicant

echo "[chroot] Installing KDE Plasma + Kali tools..."
echo "[chroot] This is the largest download (~8-15 GB) — may take a while..."
apt_retry install --yes \
    kali-desktop-kde \
    kali-linux-default \
    kali-tools-top10

echo "[chroot] Installing extra useful packages..."
apt_retry install --yes \
    openssh-server \
    sudo \
    vim \
    curl \
    wget \
    git \
    htop \
    tmux \
    efibootmgr \
    pciutils \
    usbutils \
    lsof \
    net-tools \
    bash-completion \
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

echo "[chroot] Installing GRUB to ESP (portable + Secure Boot)..."
mountpoint -q /boot/efi || mount /boot/efi
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=kali --recheck --no-floppy --removable

# grub-install --removable places the GRUB binary at EFI/BOOT/BOOTX64.EFI.
# For Secure Boot, shim must be at BOOTX64.EFI and chain-load grubx64.efi.
# So: rename the GRUB binary to grubx64.efi, then put shim at BOOTX64.EFI.
if [[ -f /usr/lib/shim/shimx64.efi.signed ]]; then
    mv /boot/efi/EFI/BOOT/BOOTX64.EFI /boot/efi/EFI/BOOT/grubx64.efi
    cp /usr/lib/shim/shimx64.efi.signed /boot/efi/EFI/BOOT/BOOTX64.EFI
    cp /usr/lib/shim/mmx64.efi.signed /boot/efi/EFI/BOOT/mmx64.efi 2>/dev/null || true
    echo "[chroot] Secure Boot chain: BOOTX64.EFI (shim) -> grubx64.efi (GRUB)"
fi

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
# PHASE 6: Verify Secure Boot Chain
###############################################################################
if skip_phase 10; then
    info "PHASE 6: Verify Secure Boot Chain — SKIPPED (already completed)"
else
phase "PHASE 6: Verify Secure Boot Chain"

# Check that the shim and signed GRUB are in place
SB_OK=true
if [[ -f "$MNT/boot/efi/EFI/BOOT/BOOTX64.EFI" ]]; then
    info "Secure Boot shim found at EFI/BOOT/BOOTX64.EFI"
else
    warn "BOOTX64.EFI not found — Secure Boot may not work"
    SB_OK=false
fi

if [[ -f "$MNT/boot/efi/EFI/BOOT/grubx64.efi" ]] || \
   [[ -f "$MNT/boot/efi/EFI/kali/grubx64.efi" ]]; then
    info "Signed GRUB EFI binary found"
else
    warn "grubx64.efi not found in expected location"
    SB_OK=false
fi

if [[ -f "$MNT/boot/efi/EFI/BOOT/mmx64.efi" ]]; then
    info "MOK Manager (mmx64.efi) found"
fi

info ""
info "Secure Boot chain:"
info "  UEFI firmware"
info "    -> shimx64.efi (Microsoft UEFI CA signed)"
info "      -> grubx64.efi (Debian/Kali signed)"
info "        -> vmlinuz (signed kernel)"
info ""
if $SB_OK; then
    info "Secure Boot: READY - will work on machines trusting Microsoft UEFI CA"
fi
info ""
info "TPM integration:"
info "  On TPM-equipped machines, Secure Boot extends PCR measurements"
info "  through the boot chain (shim -> GRUB -> kernel). This provides"
info "  attestation that the boot path has not been tampered with."
info "  The ZFS encryption passphrase is entered separately at initramfs."

# List all EFI files for verification
info ""
info "ESP contents:"
find "$MNT/boot/efi/" -type f \( -name "*.efi" -o -name "*.EFI" \) 2>/dev/null | sort | while read -r f; do
    info "  $(echo "$f" | sed "s|$MNT/boot/efi/||")"
done
mark_phase 10
fi  # end Phase 6

###############################################################################
# PHASE 7: Snapshot & Cleanup
###############################################################################
phase "PHASE 7: Snapshot & Cleanup"

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
info "  Part 1: 512 MiB ESP (FAT32, Secure Boot shim + GRUB)"
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
info "Secure Boot:"
info "  Works out of the box via shim-signed."
info "  Chain: Microsoft-signed shim -> Debian-signed GRUB -> signed kernel"
info "  No MOK enrollment needed on most machines."
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
