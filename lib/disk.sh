#!/usr/bin/env bash
###############################################################################
# lib/disk.sh — Disk partitioning and ZFS pool/dataset helpers
#
# Source after lib/common.sh:
#   source "$SCRIPT_DIR/lib/common.sh"
#   source "$SCRIPT_DIR/lib/disk.sh"
###############################################################################

[[ -z "${_LIB_DISK_LOADED:-}" ]] || return 0
_LIB_DISK_LOADED=1

# ─── Safely destroy pools on the target disk only ──────────────────────────
# Destroys bpool/rpool ONLY if they live on $DISK_DEV.
# Usage: safe_destroy_pools_on_disk "$DISK_DEV"
safe_destroy_pools_on_disk() {
    local disk_dev="${1:?}"
    local target_basename
    target_basename="$(basename "$disk_dev")"

    for p in bpool rpool; do
        if zpool list "$p" &>/dev/null; then
            local pool_vdev
            pool_vdev="$(zpool status "$p" 2>/dev/null | grep -oP '(sd[a-z]+|nvme\S+)' | head -1)"
            if [[ "$pool_vdev" == "$target_basename"* ]]; then
                warn "Pool '$p' already exists on this disk — destroying (previous failed run)..."
                zfs unmount -a -f 2>/dev/null || true
                umount -Rlf "${2:-/mnt}" 2>/dev/null || true
                zpool destroy -f "$p" 2>/dev/null || \
                    warn "Could not destroy $p — if the script fails at pool creation, reboot and retry."
            else
                error "Pool '$p' is already imported from a DIFFERENT disk (vdev: $pool_vdev)." \
                      "Unplug the other ZFS drive or 'zpool export $p' first."
            fi
        fi
    done
}

# ─── Wipe and partition a disk ──────────────────────────────────────────────
# Standard layout: ESP + bpool + rpool (with sizes from caller)
#
# Usage: partition_disk "$DISK" "$ESP_SIZE" "$BOOT_POOL_SIZE" "$ROOT_POOL_SIZE"
partition_disk() {
    local disk="${1:?}" esp_size="${2:?}" bpool_size="${3:?}" rpool_size="${4:?}"

    info "Wiping disk..."
    wipefs -af "$disk" 2>/dev/null || true
    sgdisk --zap-all "$disk"

    info "TRIMming entire disk (this may take a moment)..."
    blkdiscard -f "$disk" 2>/dev/null || warn "blkdiscard failed (non-fatal)"

    partprobe "$disk" 2>/dev/null || true
    sleep 1

    info "Creating GPT partitions..."
    sgdisk -n1:1M:+"${esp_size}"      -t1:EF00 -c1:"EFI System Partition" "$disk"
    sgdisk -n2:0:+"${bpool_size}"      -t2:BF01 -c2:"ZFS Boot Pool"       "$disk"
    sgdisk -n3:0:+"${rpool_size}"      -t3:BF00 -c3:"ZFS Root Pool"       "$disk"
    partprobe "$disk"
    sleep 2

    [[ -e "${disk}-part1" ]] || error "Partition ${disk}-part1 not found after partitioning."
    [[ -e "${disk}-part2" ]] || error "Partition ${disk}-part2 not found after partitioning."
    [[ -e "${disk}-part3" ]] || error "Partition ${disk}-part3 not found after partitioning."

    info "Partition layout:"
    sgdisk -p "$(readlink -f "$disk")"
}

# ─── Create standard ZFS pools ─────────────────────────────────────────────
# Usage: create_zfs_pools "$DISK" "$MNT"
create_zfs_pools() {
    local disk="${1:?}" mnt="${2:?}"

    info "Formatting ESP as FAT32..."
    mkdosfs -F 32 -s 1 -n EFI "${disk}-part1"

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
        -O canmount=off -O mountpoint=/boot -R "$mnt" \
        bpool "${disk}-part2"

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
        -O canmount=off -O mountpoint=/ -R "$mnt" \
        rpool "${disk}-part3"
}

# ─── Create standard ZFS datasets ──────────────────────────────────────────
# Creates the filesystem hierarchy. $distro_name is used for dataset naming
# (e.g. "kali", "debian", "fedora", "arch").
#
# Usage: create_zfs_datasets "$MNT" "kali" "$SWAP_SIZE"
create_zfs_datasets() {
    local mnt="${1:?}" name="${2:?}" swap_size="${3:-4G}"

    zfs create -o canmount=off -o mountpoint=none rpool/ROOT
    zfs create -o canmount=off -o mountpoint=none bpool/BOOT

    zfs create -o canmount=noauto -o mountpoint=/ "rpool/ROOT/$name"
    zfs mount "rpool/ROOT/$name"

    zfs create -o mountpoint=/boot "bpool/BOOT/$name"

    zfs create                     rpool/home
    zfs create -o mountpoint=/root rpool/home/root
    chmod 700 "$mnt/root"

    zfs create -o canmount=off     rpool/var
    zfs create -o canmount=off     rpool/var/lib
    zfs create                     rpool/var/log
    zfs create                     rpool/var/spool

    zfs create -o com.sun:auto-snapshot=false rpool/var/cache
    zfs create -o com.sun:auto-snapshot=false rpool/var/lib/nfs
    zfs create -o com.sun:auto-snapshot=false rpool/var/tmp
    chmod 1777 "$mnt/var/tmp"

    zfs create rpool/var/lib/AccountsService
    zfs create rpool/var/lib/NetworkManager

    info "Creating swap zvol ($swap_size)..."
    zfs create -V "$swap_size" -b "$(getconf PAGESIZE)" -o compression=zle \
        -o logbias=throughput -o sync=always \
        -o primarycache=metadata -o secondarycache=none \
        -o com.sun:auto-snapshot=false rpool/swap

    mkdir -p "$mnt/run"
    mount -t tmpfs tmpfs "$mnt/run"
    mkdir -p "$mnt/run/lock"

    info "ZFS datasets created."
    zfs list -r rpool bpool
}

# ─── Re-import pools for --resume ──────────────────────────────────────────
reimport_pools() {
    local mnt="${1:?}" name="${2:?}"

    if ! zpool list bpool &>/dev/null; then
        info "Re-importing bpool..."
        zpool import -N -d /dev/disk/by-id bpool -R "$mnt" \
            || error "Cannot re-import bpool. Run without --resume to start fresh."
    fi
    if ! zpool list rpool &>/dev/null; then
        info "Re-importing rpool (you may need to enter the passphrase)..."
        zpool import -N -d /dev/disk/by-id rpool -R "$mnt" \
            || error "Cannot re-import rpool. Run without --resume to start fresh."
        zfs load-key rpool || error "Could not load rpool encryption key."
    fi
    zfs mount "rpool/ROOT/$name" 2>/dev/null || true
    zfs mount -a 2>/dev/null || true
    mkdir -p "$mnt/run"
    mountpoint -q "$mnt/run" || mount -t tmpfs tmpfs "$mnt/run"
    mkdir -p "$mnt/run/lock"
}
