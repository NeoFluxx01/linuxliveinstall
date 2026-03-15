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

# ─── Log directory ──────────────────────────────────────────────────────────
# Logs go to LOGDIR (default: ./logs/ relative to SCRIPT_DIR). Created
# automatically. Falls back to /var/log/ if the directory is not writable.
LOGDIR=""
LOGFILE=""
TYPESCRIPT=""

setup_log_dir() {
    local script_dir="${1:?Usage: setup_log_dir /path/to/script/dir}"
    LOGDIR="$script_dir/logs"
    mkdir -p "$LOGDIR" 2>/dev/null || {
        LOGDIR="/var/log"
        warn "Cannot create $script_dir/logs — falling back to /var/log/"
    }
}

# ─── Script transcript capture ──────────────────────────────────────────────
# Re-execs through `script` to capture the full raw terminal transcript.
# Must be called AFTER setup_log_dir.
#
# Usage: setup_transcript "kali-zfs" "$@"
setup_transcript() {
    local name="${1:?Usage: setup_transcript <name>}"; shift
    TYPESCRIPT="$LOGDIR/install-${name}-$(date +%Y%m%d-%H%M%S).typescript"
    export TYPESCRIPT LOGDIR
    if [[ -z "${INSIDE_SCRIPT_WRAPPER:-}" ]]; then
        export INSIDE_SCRIPT_WRAPPER=1
        exec script -efq "$TYPESCRIPT" -c "$(printf '%q ' "$0" "$@")"
    fi
}

# ─── Log file setup ────────────────────────────────────────────────────────
# Tees all stdout+stderr to a log file while still printing to terminal.
# Must be called AFTER setup_log_dir.
#
# Usage: setup_logging "kali-zfs"
setup_logging() {
    local name="${1:?Usage: setup_logging <name>}"
    LOGFILE="$LOGDIR/install-${name}-$(date +%Y%m%d-%H%M%S).log"
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
STATEFILE=""
RESUME=false

init_resume() {
    local name="${1:?}"; shift
    STATEFILE="/tmp/.install-state-${name}"
    for arg in "$@"; do
        [[ "$arg" == "--resume" ]] && RESUME=true
    done
}

completed_phase() { cat "$STATEFILE" 2>/dev/null || echo 0; }
mark_phase()      { echo "$1" > "$STATEFILE"; }
skip_phase() {
    local n=$1
    $RESUME && (( n <= $(completed_phase) ))
}

# ─── Root check ─────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || error "This script must be run as root."
}

# ─── Disk resolution ───────────────────────────────────────────────────────
DISK=""
DISK_DEV=""

# Usage: resolve_disk [--override=/dev/X] "$DISK_WWN" "$DISK_ATA" "$DISK_USB"
resolve_disk() {
    local override=""
    local -a candidates=()
    for arg in "$@"; do
        case "$arg" in
            --override=*) override="${arg#--override=}" ;;
            *) candidates+=("$arg") ;;
        esac
    done

    if [[ -n "$override" ]]; then
        [[ -e "$override" ]] || error "Disk override not found: $override"
        DISK="$override"
        info "Disk set via --disk= override: $DISK"
    else
        for candidate in "${candidates[@]}"; do
            if [[ -n "$candidate" && -e "$candidate" ]]; then
                DISK="$candidate"
                info "Disk found: $DISK"
                break
            fi
        done
    fi
    [[ -n "$DISK" ]] || error "Disk not found via any known identifier. Is the drive plugged in?\n  Tip: use --disk=/dev/sdX or --disk=/dev/loop0 for testing."
    DISK_DEV="$(readlink -f "$DISK")"
}

# ─── ZFS module check ──────────────────────────────────────────────────────
require_zfs() {
    lsmod | grep -q '^zfs' || modprobe zfs || error "ZFS kernel module not available."
}

# ─── Tool checks ───────────────────────────────────────────────────────────
require_commands() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || error "Missing required command: $cmd"
    done
}

# Try to install a package by name (auto-detects host package manager)
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
setup_chroot_mounts() {
    local mnt="${1:?Usage: setup_chroot_mounts /mnt/target}"
    mountpoint -q "$mnt/dev"  || mount --make-private --rbind /dev  "$mnt/dev"
    mountpoint -q "$mnt/proc" || mount --make-private --rbind /proc "$mnt/proc"
    mountpoint -q "$mnt/sys"  || mount --make-private --rbind /sys  "$mnt/sys"
    cp /etc/resolv.conf "$mnt/etc/resolv.conf" 2>/dev/null || true
}

# ─── APT retry function text ───────────────────────────────────────────────
# Outputs the apt_retry function as text for embedding in chroot heredocs.
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
confirm_destructive() {
    echo ""
    read -rp "Type YES to continue: " confirm
    [[ "$confirm" == "YES" ]] || { echo "Aborted."; exit 0; }
}

# ─── Cleanup helpers ───────────────────────────────────────────────────────
# Unmount bind mounts (proc/sys/dev) FIRST, then other mounts, then ESP.
# This correct ordering prevents "pool is busy" on zpool export.
cleanup_mounts() {
    local mnt="${1:?}"

    # 1. Unmount bind mounts (reverse order: sys, proc, dev)
    for vfs in sys proc dev; do
        umount -Rlf "$mnt/$vfs" 2>/dev/null || true
    done

    # 2. Unmount ESP
    umount -lf "$mnt/boot/efi" 2>/dev/null || true

    # 3. Unmount /run
    umount -lf "$mnt/run" 2>/dev/null || true

    # 4. Unmount any remaining non-ZFS mounts under $mnt (in reverse order)
    mount | grep -v zfs | tac | awk -v m="$mnt" '$3 ~ m {print $3}' | \
        while read -r mp; do umount -lf "$mp" 2>/dev/null || true; done
}

export_pools() {
    for pool in "$@"; do
        info "Exporting $pool..."
        zpool export "$pool" 2>/dev/null || {
            warn "Normal export of $pool failed — force exporting..."
            zpool export -f "$pool" 2>/dev/null || \
                warn "Could not export $pool — may need reboot to clear"
        }
    done
}

# ─── ISO mount helpers ──────────────────────────────────────────────────────
mount_iso() {
    local iso_path="$1" var_name="$2"
    [[ -f "$iso_path" ]] || error "ISO not found: $iso_path"
    local mnt_path="/tmp/.iso-$$-$(basename "$iso_path" .iso)"
    mkdir -p "$mnt_path"
    mount -o loop,ro "$iso_path" "$mnt_path" || error "Failed to mount ISO: $iso_path"
    eval "$var_name='$mnt_path'"
}

unmount_isos() {
    for mnt in "$@"; do
        [[ -n "$mnt" ]] && umount "$mnt" 2>/dev/null && rmdir "$mnt" 2>/dev/null || true
    done
}
