#!/usr/bin/env bash
###############################################################################
# Portable Fedora Linux on ZFS — Full Installer
# Target: USB SSD /dev/sdb (Samsung MZNLN128 in USB enclosure)
#
# Based on: OpenZFS documentation + Fedora ZFS community guides
#           Adapted for portable USB SSD use
#
# Layout:
#   Part 1 — 512 MiB  ESP  (FAT32, EFI System Partition)
#   Part 2 — 1 GiB    ZFS  boot pool (bpool, grub2-compatible)
#   Part 3 — 64 GiB   ZFS  root pool (rpool, native encryption)
#   Remaining ~53 GiB left unallocated for future use
#
# Features:
#   - ZFS native encryption (aes-256-gcm, passphrase)
#   - Secure Boot via shim-signed + grub2-efi-x64
#   - Portable GRUB (--removable, writes EFI/BOOT/BOOTX64.EFI)
#   - Works on TPM-equipped machines (Secure Boot PCR attestation)
#   - KDE Plasma desktop
#   - NetworkManager (Fedora default)
#   - Comprehensive firmware bundle for broad hardware compatibility
#   - hostid set in initramfs for portable pool imports
#
# Run from an Arch/CachyOS host that has ZFS loaded.
# Requires: zfs/zpool, dnf or an extracted Fedora rootfs, sgdisk, mkdosfs,
#           chroot, internet
#
# Usage: sudo ./install-fedora-zfs.sh [--resume]
#   --resume  Skip completed phases and continue from last checkpoint
###############################################################################
set -euo pipefail

# ─── Script transcript capture ──────────────────────────────────────────────
# Re-exec through `script` to capture the full raw terminal transcript
# (including any interactive prompts) in addition to the tee'd log.
TYPESCRIPT="/var/log/install-fedora-zfs-$(date +%Y%m%d-%H%M%S).typescript"
if [[ -z "${INSIDE_SCRIPT_WRAPPER:-}" ]]; then
    export INSIDE_SCRIPT_WRAPPER=1
    exec script -efq "$TYPESCRIPT" -c "$(printf '%q ' "$0" "$@")"
fi

# ─── Log file ───────────────────────────────────────────────────────────────
LOGFILE="/var/log/install-fedora-zfs-$(date +%Y%m%d-%H%M%S).log"
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
DISK_SHORT="/dev/sdb"                # for display only
MNT="/mnt/fedora"                    # mountpoint for the new system
HOSTNAME_FEDORA="fedora-portable"
FEDORA_VERSION="43"
FEDORA_MIRROR="https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-${FEDORA_VERSION}&arch=x86_64"
FEDORA_UPDATES_MIRROR="https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f${FEDORA_VERSION}&arch=x86_64"
FEDORA_ISO=""                        # resolved below
ESP_SIZE="512M"
BOOT_POOL_SIZE="1G"
ROOT_POOL_SIZE="65536M"              # 64 GiB exactly (65536 MiB)
SWAP_SIZE="4G"

# ─── Checkpoint / resume ───────────────────────────────────────────────────
STATEFILE="/tmp/.install-state-fedora-zfs"
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

# Verify ZFS module
lsmod | grep -q '^zfs' || modprobe zfs || error "ZFS kernel module not available."

# Check for Fedora ISO
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEDORA_ISO="$(ls -1 "$SCRIPT_DIR"/Fedora-*-${FEDORA_VERSION}*.iso 2>/dev/null | head -1)"
if [[ -z "$FEDORA_ISO" ]]; then
    # Try any Fedora ISO
    FEDORA_ISO="$(ls -1 "$SCRIPT_DIR"/Fedora-*.iso 2>/dev/null | head -1)"
fi
if [[ -n "$FEDORA_ISO" && -f "$FEDORA_ISO" ]]; then
    info "Found Fedora ISO: $(basename "$FEDORA_ISO")"
else
    warn "No Fedora ISO found in $SCRIPT_DIR — will bootstrap via dnf directly"
    FEDORA_ISO=""
fi

# Install required host tools if missing
if ! command -v dnf &>/dev/null; then
    info "dnf not found — will use ISO extraction or install dnf..."
    # On Arch, we can use the Fedora ISO rootfs directly
fi

for cmd in sgdisk zpool zfs mkdosfs chroot blkdiscard partprobe; do
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
umount -lf "${DISK_SHORT}"* 2>/dev/null || true

# Check if any zpool is using this disk and export it
for pool in $(zpool list -H -o name 2>/dev/null); do
    if zpool status "$pool" 2>/dev/null | grep -q "$(basename "$(readlink -f "$DISK")")"; then
        warn "Pool '$pool' uses this disk — exporting..."
        zpool export "$pool" || warn "Could not export $pool"
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
    zfs mount rpool/ROOT/fedora 2>/dev/null || true
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
zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/fedora
zfs mount rpool/ROOT/fedora

# Boot filesystem
zfs create -o mountpoint=/boot bpool/BOOT/fedora

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
# PHASE 4: Install Fedora Base System
###############################################################################
if skip_phase 4; then
    info "PHASE 4: Install Fedora Base System — SKIPPED (already completed)"
else
phase "PHASE 4: Install Fedora Base System"

# Strategy: Extract rootfs from the Fedora Live ISO squashfs, or use dnf.
# The ISO approach is faster and doesn't require dnf on the host.

if [[ -n "$FEDORA_ISO" && -f "$FEDORA_ISO" ]]; then
    info "Extracting Fedora rootfs from ISO: $(basename "$FEDORA_ISO")"

    ISO_MNT="/tmp/fedora-iso-$$"
    SQFS_MNT="/tmp/fedora-sqfs-$$"
    ROOTFS_IMG=""

    mkdir -p "$ISO_MNT" "$SQFS_MNT"

    mount -o loop,ro "$FEDORA_ISO" "$ISO_MNT"

    # Fedora Live ISOs contain a squashfs with a rootfs image inside
    SQFS_FILE="$(find "$ISO_MNT" -name 'squashfs.img' -o -name '*.squashfs' 2>/dev/null | head -1)"
    if [[ -z "$SQFS_FILE" ]]; then
        # Some Fedora ISOs put it under LiveOS/
        SQFS_FILE="$(find "$ISO_MNT/LiveOS" -name 'squashfs.img' 2>/dev/null | head -1)"
    fi

    if [[ -n "$SQFS_FILE" ]]; then
        info "Found squashfs: $SQFS_FILE"
        mount -o loop,ro "$SQFS_FILE" "$SQFS_MNT"

        # Inside squashfs, Fedora has LiveOS/rootfs.img (ext4 image)
        ROOTFS_IMG="$(find "$SQFS_MNT" -name 'rootfs.img' 2>/dev/null | head -1)"
        if [[ -n "$ROOTFS_IMG" ]]; then
            info "Found rootfs.img: $ROOTFS_IMG"
            ROOTFS_LOOPMNT="/tmp/fedora-rootfs-$$"
            mkdir -p "$ROOTFS_LOOPMNT"
            mount -o loop,ro "$ROOTFS_IMG" "$ROOTFS_LOOPMNT"

            info "Copying Fedora rootfs to ZFS (this takes a few minutes)..."
            rsync -aAXH --info=progress2 \
                --exclude='/dev/*' \
                --exclude='/proc/*' \
                --exclude='/sys/*' \
                --exclude='/run/*' \
                --exclude='/tmp/*' \
                --exclude='/mnt/*' \
                --exclude='/media/*' \
                --exclude='/lost+found' \
                "$ROOTFS_LOOPMNT/" "$MNT/"

            umount "$ROOTFS_LOOPMNT"
            rmdir "$ROOTFS_LOOPMNT"
        else
            error "rootfs.img not found inside squashfs"
        fi

        umount "$SQFS_MNT"
    else
        error "squashfs.img not found in ISO"
    fi

    umount "$ISO_MNT"
    rmdir "$ISO_MNT" "$SQFS_MNT" 2>/dev/null || true

    info "Fedora rootfs extracted successfully."

else
    # Fallback: use dnf to bootstrap (requires dnf on host or installing it)
    info "No ISO found — bootstrapping Fedora ${FEDORA_VERSION} via dnf..."

    if ! command -v dnf &>/dev/null; then
        # On Arch, install dnf from AUR or use dnf4 if available
        if command -v pacman &>/dev/null; then
            info "Installing dnf via pacman..."
            pacman -S --noconfirm dnf 2>/dev/null || \
                error "Cannot install dnf. Please provide a Fedora ISO instead."
        fi
    fi

    # Create minimal dnf config for Fedora
    mkdir -p "$MNT/etc/yum.repos.d"
    cat > /tmp/fedora-bootstrap.repo <<EOF
[fedora]
name=Fedora ${FEDORA_VERSION} - x86_64
metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-${FEDORA_VERSION}&arch=x86_64
enabled=1
gpgcheck=1
gpgkey=https://getfedora.org/static/fedora.gpg

[fedora-updates]
name=Fedora ${FEDORA_VERSION} - Updates - x86_64
metalink=https://mirrors.fedoraproject.org/metalink?repo=updates-released-f${FEDORA_VERSION}&arch=x86_64
enabled=1
gpgcheck=1
gpgkey=https://getfedora.org/static/fedora.gpg
EOF

    dnf --installroot="$MNT" \
        --releasever="$FEDORA_VERSION" \
        --setopt=reposdir=/tmp \
        --setopt=cachedir=/tmp/dnf-cache \
        -c /tmp/fedora-bootstrap.repo \
        install -y \
        @core \
        glibc-langpack-en \
        kernel \
        kernel-devel \
        kernel-headers

    info "Fedora base system bootstrapped via dnf."
fi

# Ensure critical directories exist
mkdir -p "$MNT"/{dev,proc,sys,run,tmp,boot,boot/efi,etc/zfs}

# Copy zpool cache
cp /etc/zfs/zpool.cache "$MNT/etc/zfs/" 2>/dev/null || true
mark_phase 4
fi  # end Phase 4

###############################################################################
# PHASE 5: System Configuration (chroot)
###############################################################################
if skip_phase 5; then
    info "PHASE 5: System Configuration — SKIPPED (already completed)"
else
phase "PHASE 5: System Configuration"

# Hostname
echo "$HOSTNAME_FEDORA" > "$MNT/etc/hostname"
cat > "$MNT/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME_FEDORA
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# DNF repos — ensure Fedora repos are correct inside the chroot
cat > "$MNT/etc/yum.repos.d/fedora.repo" <<EOF
[fedora]
name=Fedora \$releasever - \$basearch
metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-\$releasever&arch=\$basearch
enabled=1
countme=1
metadata_expire=7d
repo_gpgcheck=0
type=rpm
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-\$releasever-\$basearch
skip_if_unavailable=False
EOF

cat > "$MNT/etc/yum.repos.d/fedora-updates.repo" <<EOF
[updates]
name=Fedora \$releasever - \$basearch - Updates
metalink=https://mirrors.fedoraproject.org/metalink?repo=updates-released-f\$releasever&arch=\$basearch
enabled=1
countme=1
repo_gpgcheck=0
type=rpm
gpgcheck=1
metadata_expire=6h
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-\$releasever-\$basearch
skip_if_unavailable=False
EOF

# Bind mount virtual filesystems
mount --make-private --rbind /dev  "$MNT/dev"
mount --make-private --rbind /proc "$MNT/proc"
mount --make-private --rbind /sys  "$MNT/sys"

# Ensure resolv.conf is available in chroot
cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true

# ─── Enter chroot ───────────────────────────────────────────────────────────
info "Entering chroot to configure system..."

# Create the chroot configuration script
cat > "$MNT/tmp/chroot-setup.sh" <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo ""; echo "[chroot] FATAL: command failed (exit $?) at line $LINENO: $BASH_COMMAND"; exit 1' ERR

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export DISK="__DISK__"

# ── Hostid for portable ZFS ─────────────────────────────────────────────────
# Generate a stable hostid and bake it into the system.  ZFS uses the hostid
# to detect "foreign" pools.  Because this is a portable drive we pick
# a fixed random value so it is consistent across boots on *any* machine.
echo "[chroot] Setting up stable hostid for portable ZFS..."
HOSTID="$(printf '%08x' $((RANDOM * RANDOM)))"
printf "\\x${HOSTID:6:2}\\x${HOSTID:4:2}\\x${HOSTID:2:2}\\x${HOSTID:0:2}" > /etc/hostid

# ── Clean up live system artifacts ──────────────────────────────────────────
echo "[chroot] Cleaning up live system artifacts..."
# Remove live user if present (from ISO extraction)
userdel -rf liveuser 2>/dev/null || true
rm -f /etc/sudoers.d/liveuser 2>/dev/null || true
# Remove live-specific services
rm -f /etc/systemd/system/livesys*.service 2>/dev/null || true
rm -f /usr/libexec/livesys-session-extra 2>/dev/null || true

# ── Set locale and timezone ─────────────────────────────────────────────────
echo "[chroot] Configuring locale and timezone..."
if command -v localectl &>/dev/null; then
    localectl set-locale LANG=en_US.UTF-8 2>/dev/null || true
fi
echo "LANG=en_US.UTF-8" > /etc/locale.conf
ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# ── Set Fedora release version ──────────────────────────────────────────────
FEDORA_VER=$(rpm -E %fedora 2>/dev/null || echo "43")

# ── Install ZFS from OpenZFS repo ──────────────────────────────────────────
echo "[chroot] Setting up ZFS repository..."
dnf install -y \
    "https://zfsonlinux.org/fedora/zfs-release-2-5$(rpm --eval "%{dist}").noarch.rpm" \
    2>/dev/null || \
dnf install -y \
    "https://zfsonlinux.org/fedora/zfs-release-2-5.fc${FEDORA_VER}.noarch.rpm" \
    2>/dev/null || true

# Import ZFS repo GPG key
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-openzfs* 2>/dev/null || true

echo "[chroot] Installing ZFS packages..."
dnf install -y kernel kernel-devel kernel-headers
dnf install -y zfs zfs-dracut

# Load ZFS module (may fail in chroot but that's ok)
modprobe zfs 2>/dev/null || true

# Ensure ZFS is built for the installed kernel
KVER=$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | tail -1)
echo "[chroot] Kernel version: $KVER"

# Enable DKMS rebuild on kernel updates
mkdir -p /etc/dkms
echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf 2>/dev/null || true

# ── Setup ESP ──────────────────────────────────────────────────────────────
echo "[chroot] Setting up ESP..."
dnf install -y dosfstools efibootmgr
mkdir -p /boot/efi

ESP_UUID=$(blkid -s UUID -o value ${DISK}-part1)
echo "UUID=${ESP_UUID} /boot/efi vfat defaults 0 0" >> /etc/fstab
mount /boot/efi

# ── Install GRUB + Secure Boot ─────────────────────────────────────────────
echo "[chroot] Installing GRUB + Secure Boot shim..."
dnf install -y \
    grub2-efi-x64 \
    grub2-efi-x64-modules \
    grub2-tools \
    grub2-tools-extra \
    shim-x64

# ── Configure swap ─────────────────────────────────────────────────────────
echo "[chroot] Configuring swap..."
mkswap -f /dev/zvol/rpool/swap
echo "/dev/zvol/rpool/swap none swap discard 0 0" >> /etc/fstab

# ── Create bpool import service ────────────────────────────────────────────
echo "[chroot] Creating bpool import service..."
# Use -d /dev/disk/by-id so ZFS scans ALL available identifiers (wwn-, ata-,
# usb-) when looking for the bpool. This is critical for a portable drive —
# different machines may expose different by-id names depending on their USB
# controller and whether ATA passthrough works.
cat > /etc/systemd/system/zfs-import-bpool.service <<'SVCEOF'
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/zpool import -N -o cachefile=none -d /dev/disk/by-id bpool
# Work-around to preserve zpool cache:
ExecStartPre=-/bin/mv /etc/zfs/zpool.cache /etc/zfs/preboot_zpool.cache
ExecStartPost=-/bin/mv /etc/zfs/preboot_zpool.cache /etc/zfs/zpool.cache

[Install]
WantedBy=zfs-import.target
SVCEOF
systemctl enable zfs-import-bpool.service

# ── Install firmware + NetworkManager ──────────────────────────────────────
echo "[chroot] Installing firmware and NetworkManager..."
dnf install -y \
    NetworkManager \
    NetworkManager-wifi \
    linux-firmware \
    iwlwifi-dkms-firmware 2>/dev/null || true
dnf install -y linux-firmware 2>/dev/null || true

# ── Install KDE Plasma desktop ─────────────────────────────────────────────
echo "[chroot] Installing KDE Plasma desktop..."
dnf group install -y "KDE Plasma Workspaces" 2>/dev/null || \
    dnf group install -y kde-desktop-environment 2>/dev/null || \
    dnf install -y @kde-desktop @base-x plasma-desktop plasma-workspace sddm konsole dolphin

# ── Install extra packages ─────────────────────────────────────────────────
echo "[chroot] Installing extra useful packages..."
dnf install -y \
    openssh-server \
    sudo \
    vim-enhanced \
    curl \
    wget \
    git \
    htop \
    tmux \
    pciutils \
    usbutils \
    lsof \
    net-tools \
    bash-completion \
    plymouth \
    plymouth-system-theme

# ── Configure GRUB ─────────────────────────────────────────────────────────
echo "[chroot] Configuring GRUB..."
mkdir -p /etc/default
cat > /etc/default/grub <<'GRUBEOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Fedora"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT/fedora"
GRUB_TERMINAL_OUTPUT=console
GRUB_DISABLE_OS_PROBER=true
GRUBEOF

# ── Configure dracut for ZFS ──────────────────────────────────────────────
echo "[chroot] Configuring dracut for ZFS..."
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/zfs.conf <<'DRACUTEOF'
# ZFS root support
nofsck="yes"
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs "
DRACUTEOF

# Include hostid in initramfs so ZFS can import pools on boot
cat > /etc/dracut.conf.d/hostid.conf <<'DRACUTEOF'
install_items+=" /etc/hostid "
DRACUTEOF

echo "[chroot] Regenerating initramfs..."
dracut --force --kver "$KVER" 2>/dev/null || \
    dracut --regenerate-all --force 2>/dev/null || \
    warn "dracut may need re-running after first boot"

echo "[chroot] Installing GRUB to ESP (portable + Secure Boot)..."
# --removable writes to EFI/BOOT/BOOTX64.EFI so any UEFI machine can find it
grub2-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=fedora --recheck --no-floppy --removable 2>/dev/null || \
grub2-install --target=x86_64-efi --efi-directory=/boot/efi \
    --removable 2>/dev/null || true

# Ensure the Secure Boot shim is placed correctly at the fallback path.
# Fedora's shim-x64 provides shimx64.efi
if [[ -f /boot/efi/EFI/fedora/shimx64.efi ]]; then
    cp /boot/efi/EFI/fedora/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
    cp /boot/efi/EFI/fedora/mmx64.efi /boot/efi/EFI/BOOT/mmx64.efi 2>/dev/null || true
    # Ensure grubx64.efi is alongside the shim
    if [[ ! -f /boot/efi/EFI/BOOT/grubx64.efi ]]; then
        cp /boot/efi/EFI/fedora/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi 2>/dev/null || true
    fi
    echo "[chroot] Secure Boot shim installed at EFI/BOOT/BOOTX64.EFI"
elif [[ -f /boot/efi/EFI/BOOT/shimx64.efi ]]; then
    # shim already at fallback path; rename to BOOTX64.EFI
    cp /boot/efi/EFI/BOOT/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
    echo "[chroot] Secure Boot shim copied to EFI/BOOT/BOOTX64.EFI"
fi

# Generate GRUB config
grub2-mkconfig -o /boot/efi/EFI/BOOT/grub.cfg 2>/dev/null || \
grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
# Also place a copy at the standard Fedora location
mkdir -p /boot/efi/EFI/fedora
cp /boot/grub2/grub.cfg /boot/efi/EFI/fedora/grub.cfg 2>/dev/null || true
cp /boot/efi/EFI/BOOT/grub.cfg /boot/efi/EFI/fedora/grub.cfg 2>/dev/null || true

# ── ZFS mount ordering (zfs-mount-generator) ──────────────────────────────
echo "[chroot] Setting up ZFS mount ordering..."
mkdir -p /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/bpool
touch /etc/zfs/zfs-list.cache/rpool

# Start zed to populate cache, then stop it
zed -F &
ZED_PID=$!
sleep 3

# Force cache update
zfs set canmount=on     bpool/BOOT/fedora 2>/dev/null || true
zfs set canmount=noauto rpool/ROOT/fedora 2>/dev/null || true
sleep 2

kill "$ZED_PID" 2>/dev/null || true
wait "$ZED_PID" 2>/dev/null || true

# Fix mountpoint paths (remove MNT prefix from zfs-list.cache)
sed -Ei "s|/mnt/fedora/?|/|" /etc/zfs/zfs-list.cache/* 2>/dev/null || true

# ── Enable services ───────────────────────────────────────────────────────
echo "[chroot] Enabling essential services..."
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable sddm 2>/dev/null || true
systemctl enable zfs-import-cache
systemctl enable zfs-import.target
systemctl enable zfs-mount
systemctl enable zfs.target
systemctl enable zfs-zed
systemctl set-default graphical.target

# ── Clean up ──────────────────────────────────────────────────────────────
echo "[chroot] Cleaning dnf cache to save space..."
dnf clean all 2>/dev/null || true

echo "[chroot] Setting root password..."
echo "Set the root password for your Fedora installation:"
passwd

echo "[chroot] Creating user account..."
echo "Create a regular user account:"
read -rp "Username: " USERNAME
useradd -m -G wheel "$USERNAME"
echo "Set password for $USERNAME:"
passwd "$USERNAME"
# Create ZFS home dataset for user
zfs create "rpool/home/$USERNAME" 2>/dev/null || true
cp -a /etc/skel/. "/home/$USERNAME/" 2>/dev/null || true
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"

echo "[chroot] Configuration complete!"
CHROOT_EOF

# Replace the DISK placeholder
sed -i "s|__DISK__|${DISK}|g" "$MNT/tmp/chroot-setup.sh"
chmod +x "$MNT/tmp/chroot-setup.sh"

# Run the chroot script
chroot "$MNT" /usr/bin/env bash /tmp/chroot-setup.sh

# Clean up the script
rm -f "$MNT/tmp/chroot-setup.sh"
mark_phase 5
fi  # end Phase 5

###############################################################################
# PHASE 6: Verify Secure Boot Chain
###############################################################################
if skip_phase 6; then
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
   [[ -f "$MNT/boot/efi/EFI/fedora/grubx64.efi" ]]; then
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
info "      -> grubx64.efi (Fedora signed)"
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
mark_phase 6
fi  # end Phase 6

###############################################################################
# PHASE 7: Snapshot & Cleanup
###############################################################################
phase "PHASE 7: Snapshot & Cleanup"

# Take initial snapshots
info "Creating initial snapshots..."
zfs snapshot bpool/BOOT/fedora@install
zfs snapshot rpool/ROOT/fedora@install

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
mark_phase 7
rm -f "$STATEFILE"

###############################################################################
# Done!
###############################################################################
echo ""
phase "Installation Complete!"
echo ""
info "Your portable Fedora Linux is installed on: $DISK"
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
info "  3. Select the USB drive (shows as 'fedora' or 'UEFI: SAMSUNG')"
info "  4. Enter your ZFS encryption passphrase when prompted"
info ""
info "Secure Boot:"
info "  Works out of the box via shim-signed."
info "  Chain: Microsoft-signed shim -> Fedora-signed GRUB -> signed kernel"
info "  Fedora kernels are signed by default."
info ""
info "TPM:"
info "  Secure Boot + TPM machines validate the boot chain via PCR"
info "  measurements automatically. The TPM attests boot integrity;"
info "  ZFS decryption uses your passphrase (not TPM-bound)."
info ""
info "ZFS on Fedora:"
info "  ZFS is provided by the OpenZFS project (zfsonlinux.org)."
info "  After kernel updates, run: sudo dkms autoinstall"
info "  Or ensure zfs-dkms is installed for automatic rebuilds."
info ""
info "Snapshots: bpool/BOOT/fedora@install, rpool/ROOT/fedora@install"
info "           Use 'zfs rollback' to restore to clean state if needed."
info ""
info "Full install log: $LOGFILE"
echo ""
