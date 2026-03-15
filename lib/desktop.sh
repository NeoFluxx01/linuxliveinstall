#!/usr/bin/env bash
###############################################################################
# lib/desktop.sh — KDE Plasma desktop installation (chroot)
#
# Generates the chroot script that replaces XFCE (from the Kali live ISO's
# squashfs) with KDE Plasma, sets SDDM as the display manager, and installs
# supplemental packages.
#
# Source after lib/common.sh:
#   source "$SCRIPT_DIR/lib/common.sh"
#   source "$SCRIPT_DIR/lib/desktop.sh"
###############################################################################

[[ -z "${_LIB_DESKTOP_LOADED:-}" ]] || return 0
_LIB_DESKTOP_LOADED=1

# ─── Generate KDE Plasma install script for chroot ─────────────────────────
# Outputs bash code to be written to a chroot script file.
# Includes the apt_retry wrapper for transient failure handling.
#
# Usage:
#   generate_desktop_chroot_script > "$MNT/tmp/chroot-desktop.sh"
generate_desktop_chroot_script() {
    cat <<'DESKTOP_SCRIPT'
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

echo "[chroot] Desktop setup complete."
DESKTOP_SCRIPT
}
