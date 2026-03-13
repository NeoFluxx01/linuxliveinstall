# Architecture & Design Decisions

This document captures the key technical decisions, trade-offs, and "why" behind this project. It exists primarily so that future developers (human or AI) can understand the reasoning without needing to rediscover it through trial and error.

## Project Goal

Install a fully functional, portable Linux desktop on a USB SSD with:
- **ZFS root** with native encryption (aes-256-gcm)
- **Microsoft-trusted Secure Boot** — no MOK enrollment, works on password-locked BIOS
- **Multi-distro support** — same architecture for Kali, Debian, Arch, Fedora
- **VM testable** — full QEMU/KVM test harness with Secure Boot + TPM

## Disk Layout: Why 3 Partitions?

```
Part 1: 512 MiB  ESP (FAT32)   — UEFI boot, signed chain, GRUB modules
Part 2: 1 GiB    ZFS bpool     — /boot (kernels, initramfs, grub.cfg)
Part 3: 64 GiB   ZFS rpool     — / (encrypted, everything else)
Rest:   ~53 GiB  Unallocated   — future use
```

### Why separate bpool and rpool?

GRUB's ZFS implementation only supports a subset of ZFS features (see `spa_feature_names` in `grub-core/fs/zfs/zfs.c`). If we used a single pool with all modern features, GRUB couldn't read `/boot`. The split allows:
- **bpool**: `compatibility=grub2` — restricted to GRUB-supported features, lz4 compression
- **rpool**: All modern ZFS features, zstd compression, native encryption

This is the standard approach from the [OpenZFS Root on ZFS guides](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Trixie%20Root%20on%20ZFS.html).

### Why 64 GiB rpool (not whole disk)?

The target is a 128 GiB USB SSD. Leaving ~53 GiB unallocated provides:
- Space for a future Windows To Go partition
- Room to grow rpool later with `zpool online -e`
- Avoids filling the SSD (bad for flash wear leveling)

## Secure Boot Chain: Why Shim + Signed GRUB?

```
UEFI Firmware (Microsoft UEFI CA 2011 in DB — every UEFI PC since 2012)
  → shimx64.efi.signed   (signed by Microsoft UEFI 3rd-party CA)
    → grubx64.efi.signed (signed by Debian key, embedded in shim)
      → vmlinuz           (signed by Debian key, verified via shim protocol)
```

### Why not just sign our own GRUB?

Microsoft's UEFI CA is the only key present in every factory Secure Boot database. To get a binary signed by Microsoft, you must go through the [shim-review process](https://github.com/rhboot/shim-review). Only distro vendors (Debian, Red Hat, Ubuntu, etc.) do this. We piggyback on Debian's signed shim and GRUB.

### Why `--removable` (EFI/BOOT/BOOTX64.EFI)?

Portable drives don't have NVRAM entries. The UEFI spec defines `EFI/BOOT/BOOTX64.EFI` as the fallback boot path for removable media. Using `--removable` ensures the drive boots on any UEFI machine without needing `efibootmgr`.

### Why MOK enrollment is not needed

The Debian signing key is **hardcoded inside the shim binary** itself. Microsoft reviewed this during shim-review and counter-signed the shim. When shim loads grubx64.efi, it checks against its embedded key — not the MOK database. This means the chain works on password-locked BIOS machines where MOK enrollment (which requires a reboot + manual key approval) is impossible.

## Kali-Specific: grub-efi-amd64-signed Extraction

**Problem**: Kali Linux (which is based on Debian Testing/Trixie) does NOT package `grub-efi-amd64-signed`. The package exists in Debian proper but has version conflicts with Kali's `grub-common` (e.g., Kali ships `2.12-9+kali1` vs Debian's `2.12-9`).

**Solution** (Phase 5b): Download the `grub-efi-amd64-signed` .deb from Debian Trixie, extract just the signed binary, place it at `/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed`, then remove the Debian repo. This avoids installing the full package (which would conflict) while getting the signed binary we need.

```bash
# Temporary Debian Trixie repo with low-priority pinning
echo "deb http://deb.debian.org/debian trixie main" > /etc/apt/sources.list.d/debian-trixie.list
# Pin-Priority: 100 prevents Debian packages from being auto-installed
apt-get download grub-efi-amd64-signed
dpkg-deb --extract grub-efi-amd64-signed_*.deb /tmp/extract/
cp /tmp/extract/usr/lib/grub/x86_64-efi-signed/* /usr/lib/grub/x86_64-efi-signed/
# Clean up Debian source immediately
rm -f /etc/apt/sources.list.d/debian-trixie.list
```

## Signed GRUB Is Modular (Not Monolithic)

This is a critical insight that caused significant debugging time.

**The problem**: `grub-install` produces a **monolithic** GRUB binary with ZFS support compiled in. But Debian's `grub-efi-amd64-signed` is a **modular** binary — it can't read ZFS filesystems without loading `zfs.mod` first.

**The consequence**: When signed GRUB boots, it tries to execute `search.file /boot/grub/grub.cfg` to find the boot pool. But it can't search ZFS filesystems because ZFS support isn't built in. It drops to a GRUB shell.

**The fix** (Phase 5d, Steps 3-4):
1. Copy all GRUB modules from `/usr/lib/grub/x86_64-efi/` to the ESP at `/EFI/debian/x86_64-efi/` (the signed GRUB's `$prefix` is `/EFI/debian`)
2. Write a redirect grub.cfg that loads ZFS before searching:

```grub
insmod part_gpt
insmod zfs
search.file /boot/grub/grub.cfg root
set prefix=($root)/boot/grub
configfile $prefix/grub.cfg
```

The dpkg hook (`99-secureboot-esp-sync`) keeps both the signed binaries AND the modules in sync on future package updates.

## Partition Naming: The part() Helper

Different device types use different partition naming conventions:
- `/dev/disk/by-id/X` → `/dev/disk/by-id/X-partN`
- `/dev/loop0` → `/dev/loop0p1`
- `/dev/nvme0n1` → `/dev/nvme0n1p1`
- `/dev/sda` → `/dev/sda1`

The `part()` function handles all of these, making the installer work with `--disk=/dev/loop0` (VM testing), by-id paths (production), and any other device type.

## Disk Identification: Why WWN?

The installer uses the drive's **WWN (World Wide Name)** as the primary identifier. WWN is burned into the SSD firmware and is the most stable identifier:
- Survives enclosure swaps (unlike USB serial)
- Survives USB port changes (unlike USB path)
- Works on any machine (unlike ATA serial which depends on the controller)

Fallbacks: ATA serial → USB enclosure ID → manual `--disk=` override.

## Checkpoint/Resume System

The installer uses a simple file-based state machine (`/tmp/.install-state-kali-zfs`) where each phase writes its number on completion. `--resume` skips phases whose number is ≤ the last completed phase.

Phase numbering (internal state numbers, not phase names):
```
Phase 1  (state 1): Partitioning
Phase 2  (state 2): Boot pool creation
Phase 3  (state 3): Root pool + datasets
Phase 4  (state 4): Debootstrap
Phase 5a (state 5): Base system config
Phase 5b (state 6): ZFS, kernel, boot packages
Phase 5c (state 7): Desktop & packages
Phase 5d (state 8): GRUB, initramfs, Secure Boot chain
Phase 5e (state 9): User account setup
Phase 6  (state 10): Secure Boot verification
Phase 7  (state 11): Snapshot & cleanup
```

## ZFS Safety on Host

**CRITICAL**: If the host machine also runs ZFS (e.g., CachyOS with `zpcachyos`), always:
- Use `zpool import -R /mnt/kali` (altroot) — never bare `import`
- Use distinct mountpoints (e.g., `/mnt/kali`, not `/mnt`)
- Always `zpool export` bpool and rpool when done
- Never have both the host pool and test pools imported with overlapping mount paths

## VM Testing Architecture

The test harness uses:
- **QEMU 10.x** with KVM acceleration
- **OVMF** (UEFI firmware) — standard and Secure Boot variants
- **swtpm** — virtual TPM 2.0 for PCR measurement testing
- **128 GiB sparse virtual disk** — only uses actual space written
- **Loop devices** with `--partscan` for installer access to the virtual disk

OVMF Secure Boot variant (`OVMF_CODE.secboot.4m.fd`) comes with Microsoft's UEFI CA pre-enrolled, simulating a real PC.

## Future: ZFSBootMenu Alternative

[ZFSBootMenu](https://github.com/zbm-dev/zfsbootmenu) (1.1k stars) is a compelling alternative to the GRUB-based boot chain. It:
- Eliminates the signed GRUB + ZFS module headache entirely
- Uses kexec instead of GRUB's limited ZFS implementation
- Provides native boot environment support (snapshots, rollback, multi-distro)
- Supports Secure Boot via unified EFI bundles
- Works the same across all distros

Trade-offs: Different boot UX, requires kexec, has its own learning curve. Worth evaluating for v2 of this project.

## File Structure

```
install-kali-zfs.sh          # Standalone installer (all phases in one file)
install-fedora-zfs.sh        # Fedora variant (different bootstrap method)
lib/                         # Shared shell library (planned refactor target)
  common.sh                  # Logging, colors, preflight, resume
  disk.sh                    # Partitioning, ZFS pool/dataset creation
  secureboot.sh              # Signed boot chain setup + verification
configs/                     # Per-distro configuration
  kali.conf                  # Mirror, suite, packages, hostname, disk IDs
test/                        # QEMU/KVM test harness
  create-test-vm.sh          # VM lifecycle management
tools/                       # Windows-side utilities
  add-windows-boot-entry.ps1 # Add USB to Windows Boot Manager
```

Currently, each installer is standalone (~1200 lines). The `lib/` and `configs/` structure exists for a planned refactor where common logic (partitioning, ZFS setup, Secure Boot chain, verification) moves into shared libraries and each installer becomes a thin wrapper that sources its config and calls shared functions.
