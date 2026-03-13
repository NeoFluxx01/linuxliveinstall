#!/usr/bin/env bash
###############################################################################
# lib/common.sh — Shared functions for all install scripts
#
# Source this at the top of each installer:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/common.sh"
###############################################################################

# Guard against double-sourcing
[[ -z "${_LIB_COMMON_LOADED:-}" ]] || return 0
_LIB_COMMON_LOADED=1

# ─── Colours & logging ─────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
_ts()   { date '+%H:%M:%S'; }
info()  { echo -e "${GREEN}[$(_ts) INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[$(_ts) WARN]${NC}  $*"; }
error() { echo -e "${RED}[$(_ts) ERROR]${NC} $*"; exit 1; }
phase() {
    echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  [$(_ts)] $*${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}\n"
}

# ─── Script transcript capture ──────────────────────────────────────────────
# Call this early in the main script. Re-execs through `script` to capture
# the full raw terminal transcript.
#
# Usage: setup_transcript "kali-zfs"
setup_transcript() {
    local name="${1:?Usage: setup_transcript <name>}"
    TYPESCRIPT="/var/log/install-${name}-$(date +%Y%m%d-%H%M%S).typescript"
    export TYPESCRIPT
    if [[ -z "${INSIDE_SCRIPT_WRAPPER:-}" ]]; then
        export INSIDE_SCRIPT_WRAPPER=1
        exec script -efq "$TYPESCRIPT" -c "$(printf '%q ' "$0" "$@")"
    fi
}

# ─── Log file setup ────────────────────────────────────────────────────────
# Tees all stdout+stderr to a log file while still printing to terminal.
#
# Usage: setup_logging "kali-zfs"
setup_logging() {
    local name="${1:?Usage: setup_logging <name>}"
    LOGFILE="/var/log/install-${name}-$(date +%Y%m%d-%H%M%S).log"
    export LOGFILE
    exec > >(tee -a "$LOGFILE") 2>&1

    trap 'trap_handler "$LINENO" "$BASH_COMMAND" "$?"' ERR
}

trap_handler() {
    local lineno=$1 cmd=$2 rc=$3
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  FATAL: command failed (exit $rc)"
    echo "  Line:  $lineno"
    echo "  Cmd:   $cmd"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Last 30 lines of log (${LOGFILE:-/dev/null}):"
    tail -n 30 "${LOGFILE:-/dev/null}" 2>/dev/null || true
    echo ""
    echo "Full log saved to: ${LOGFILE:-<none>}"
    exit "$rc"
}

# ─── Checkpoint / resume ───────────────────────────────────────────────────
# Usage:
#   init_resume "kali-zfs" "$@"   # parses --resume flag
#   skip_phase 1 && info "skipped" || { ...; mark_phase 1; }
STATEFILE=""
RESUME=false

init_resume() {
    local name="${1:?}"; shift
    STATEFILE="/tmp/.install-state-${name}"
    for arg in "$@"; do
        case "$arg" in
            --resume) RESUME=true ;;
        esac
    done
}

completed_phase() { cat "$STATEFILE" 2>/dev/null || echo 0; }
mark_phase()      { echo "$1" > "$STATEFILE"; }
skip_phase() {
    local n=$1
    if $RESUME && (( n <= $(completed_phase) )); then
        return 0
    fi
    return 1
}

# ─── Root check ─────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || error "This script must be run as root."
}

# ─── Disk resolution ───────────────────────────────────────────────────────
# Tries each identifier in order, sets DISK and DISK_DEV.
# Usage: resolve_disk "$DISK_WWN" "$DISK_ATA" "$DISK_USB"
#   or:  resolve_disk --interactive   (prompts user to pick)
DISK=""
DISK_DEV=""

resolve_disk() {
    if [[ "${1:-}" == "--interactive" ]]; then
        info "Available disks:"
        lsblk -dpno NAME,SIZE,MODEL,TRAN | grep -v '^/dev/zram' | while read -r line; do
            echo "  $line"
        done
        echo ""
        read -rp "Enter disk path (e.g. /dev/sda) or by-id path: " DISK
        [[ -b "$DISK" || -e "$DISK" ]] || error "Not a valid block device: $DISK"
        DISK_DEV="$(readlink -f "$DISK")"
        return
    fi

    for candidate in "$@"; do
        if [[ -n "$candidate" && -e "$candidate" ]]; then
            DISK="$candidate"
            DISK_DEV="$(readlink -f "$DISK")"
            info "Disk found: $DISK -> $DISK_DEV"
            return
        fi
    done
    error "Disk not found via any known identifier. Is the drive plugged in?"
}

# ─── ZFS module check ──────────────────────────────────────────────────────
require_zfs() {
    lsmod | grep -q '^zfs' || modprobe zfs || error "ZFS kernel module not available."
}

# ─── Tool checks ───────────────────────────────────────────────────────────
# Usage: require_commands sgdisk zpool zfs debootstrap mkdosfs chroot
require_commands() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || error "Missing required command: $cmd"
    done
}

# Try to install a package by name (auto-detects package manager on host)
host_install_package() {
    local pkg="$1"
    info "$pkg not found — attempting install..."
    if command -v pacman &>/dev/null; then
        pacman -S --noconfirm "$pkg" || error "Failed to install $pkg"
    elif command -v apt-get &>/dev/null; then
        apt-get install -y "$pkg" || error "Failed to install $pkg"
    elif command -v dnf &>/dev/null; then
        dnf install -y "$pkg" || error "Failed to install $pkg"
    else
        error "Cannot auto-install $pkg — unknown package manager"
    fi
}

# ─── Chroot helpers ─────────────────────────────────────────────────────────
# Bind-mount virtual filesystems for chroot
setup_chroot_mounts() {
    local mnt="${1:?Usage: setup_chroot_mounts /mnt/target}"
    mountpoint -q "$mnt/dev"  || mount --make-private --rbind /dev  "$mnt/dev"
    mountpoint -q "$mnt/proc" || mount --make-private --rbind /proc "$mnt/proc"
    mountpoint -q "$mnt/sys"  || mount --make-private --rbind /sys  "$mnt/sys"
    cp /etc/resolv.conf "$mnt/etc/resolv.conf" 2>/dev/null || true
}

# ─── APT retry wrapper (for use inside heredoc chroot scripts) ──────────────
# This function is meant to be COPIED into chroot scripts as text,
# not called directly from the host. See generate_apt_retry_func().
generate_apt_retry_func() {
    cat <<'RETRY_FUNC'
apt_retry() {
    local attempt max_attempts=3
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        if apt-get "$@"; then return 0; fi
        echo "[chroot] apt-get failed (attempt $attempt/$max_attempts) — retrying in 10s..."
        sleep 10; apt-get update -qq 2>/dev/null || true
    done
    echo "[chroot] apt-get failed after $max_attempts attempts"; return 1
}
RETRY_FUNC
}

# ─── Confirmation prompt ───────────────────────────────────────────────────
# Usage: confirm_destructive "This will DESTROY ALL DATA on $DISK."
confirm_destructive() {
    local msg="${1:-This operation is destructive.}"
    warn "$msg"
    echo ""
    read -rp "Type YES to continue: " confirm
    [[ "$confirm" == "YES" ]] || { echo "Aborted."; exit 0; }
}

# ─── Cleanup helpers ───────────────────────────────────────────────────────
# Unmount a chroot tree and export ZFS pools
cleanup_mounts() {
    local mnt="${1:?}"
    umount -lf "$mnt/boot/efi" 2>/dev/null || true
    mount | grep -v zfs | tac | awk -v m="$mnt" '$3 ~ m {print $3}' | \
        xargs -I{} umount -lf {} 2>/dev/null || true
    umount -lf "$mnt/run" 2>/dev/null || true
}

export_pools() {
    for pool in "$@"; do
        info "Exporting $pool..."
        zpool export "$pool" || warn "Could not export $pool cleanly"
    done
}
