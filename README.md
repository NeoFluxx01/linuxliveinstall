# Linux Live Install on ZFS

Portable Linux installers that set up fully encrypted ZFS root on USB SSDs, with Secure Boot and TPM support.

## Scripts

| Script | Target | Drive |
|--------|--------|-------|
| `install-kali-zfs.sh` | Kali Linux (kali-rolling) | USB SSD `/dev/sda` (EAGET) |
| `install-fedora-zfs.sh` | Fedora 43 | USB SSD `/dev/sdb` (Samsung) |

## Features

- **ZFS native encryption** (aes-256-gcm, passphrase)
- **Secure Boot** via shim-signed + signed GRUB + signed kernel
- **Portable** — `--removable` GRUB installs to `EFI/BOOT/BOOTX64.EFI`, works on any UEFI machine
- **TPM-compatible** — Secure Boot PCR attestation through the full boot chain
- **KDE Plasma** desktop environment
- **ZFS compression** — zstd on rpool, lz4 on bpool (GRUB compatibility)
- **Portable hostid** — baked into initramfs so pools import on any machine
- **Checkpoint/resume** — failed runs can resume from the last completed phase
- **Full logging** — timestamped output tee'd to `/var/log/install-*-zfs-*.log`

## Partition Layout

| Part | Size | Type | Purpose |
|------|------|------|---------|
| 1 | 512 MiB | ESP (FAT32) | EFI System Partition |
| 2 | 1 GiB | ZFS | Boot pool (bpool) |
| 3 | 64 GiB | ZFS | Root pool (rpool, encrypted) |
| — | ~53 GiB | — | Unallocated (future use) |

## Prerequisites

Run from an Arch/CachyOS host with ZFS loaded:

```bash
# Required: zfs/zpool, debootstrap (Kali), sgdisk, mkdosfs
# The scripts will install missing tools automatically where possible
sudo ./install-kali-zfs.sh
sudo ./install-fedora-zfs.sh
```

## Disk Identification

Scripts use WWN (World Wide Name) as the primary disk identifier — it's burned into the SSD firmware and survives enclosure swaps, USB port changes, and works on any machine. ATA serial and USB enclosure ID are used as fallbacks.

## License

MIT
