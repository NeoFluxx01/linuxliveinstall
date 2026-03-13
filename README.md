# Portable OS-on-ZFS Installer Suite

Portable OS installers that set up fully encrypted ZFS root on USB SSDs with **Microsoft-trusted Secure Boot** — works on password-locked BIOS machines (Dell AIO PCs, corporate/school hardware).

## Quick Start

```bash
# Working installer (Kali — battle-tested):
sudo ./install-kali-zfs.sh

# Resume from failure:
sudo ./install-kali-zfs.sh --resume
```

## The Problem: Locked BIOS Boot Menu

Many school/corporate machines have BIOS passwords that prevent changing boot order. Our solutions:

| Approach | How | Requires |
|----------|-----|----------|
| **Microsoft-trusted Secure Boot chain** | shimx64 (MS-signed) → GRUB (Debian-signed) → kernel (signed) | USB drive to be in boot order |
| **Windows Boot Manager entry** | `bcdedit` adds USB as a boot option from within Windows | Local admin on Windows |
| **One-time boot via PowerShell** | Sets USB as next-boot-only, then reverts to Windows | Local admin on Windows |

### Using the Windows Boot Entry Tool

On the Dell AIO (from within Windows, run as Administrator):
```powershell
# List current boot entries:
.\tools\add-windows-boot-entry.ps1 list

# Add USB drive permanently to boot menu:
.\tools\add-windows-boot-entry.ps1 add

# Boot to USB just once (next reboot only):
.\tools\add-windows-boot-entry.ps1 boot-next

# Remove the entry later:
.\tools\add-windows-boot-entry.ps1 remove
```
Or double-click `tools\add-windows-boot-entry.bat` for auto-elevation.

## Project Structure

```
├── install-kali-zfs.sh            # Standalone Kali installer (working)
├── install-fedora-zfs.sh          # Standalone Fedora installer (working)
├── install-arch-zfs.sh            # Arch (planned)
├── install-debian-zfs.sh          # Debian (planned)
├── install-windowstogo.sh         # Windows To Go (planned, last)
│
├── lib/                           # Shared shell library
│   ├── common.sh                  # Logging, colors, preflight, resume
│   ├── disk.sh                    # Partitioning, ZFS pool/dataset creation
│   └── secureboot.sh              # Signed boot chain setup + verification
│
├── configs/                       # Per-distro configuration
│   ├── kali.conf                  # Mirror, suite, packages, hostname
│   ├── debian.conf
│   ├── arch.conf
│   └── fedora.conf
│
├── tools/
│   ├── add-windows-boot-entry.ps1 # PowerShell: add USB to Windows Boot Manager
│   └── add-windows-boot-entry.bat # Wrapper with auto-elevation
│
└── test/
    └── create-test-vm.sh          # QEMU/KVM VM for testing
```

## Features

- **ZFS native encryption** (aes-256-gcm, passphrase)
- **Microsoft-trusted Secure Boot** — full chain signed with factory-trusted keys:
  ```
  UEFI firmware  (Microsoft UEFI CA 2011 in DB — every PC since 2012)
    → shimx64.efi  (signed by Microsoft UEFI 3rd-party CA)
      → grubx64.efi  (signed by Debian key, embedded in shim)
        → vmlinuz  (signed by Debian key, verified via shim protocol)
  ```
- **Password-locked BIOS compatible** — no MOK enrollment needed
- **Portable** — `--removable` GRUB at `EFI/BOOT/BOOTX64.EFI`
- **TPM-compatible** — Secure Boot PCR attestation through the full chain
- **Auto-maintained** — dpkg hook refreshes signed ESP binaries on updates
- **Signature verified** — sbverify checks at install time
- **KDE Plasma** desktop
- **ZFS compression** — zstd on rpool, lz4 on bpool
- **Portable hostid** — baked into initramfs
- **Checkpoint/resume** — `--resume` continues from last completed phase
- **Full logging** — timestamped to `/var/log/install-*.log`

## Partition Layout

| Part | Size | Type | Purpose |
|------|------|------|---------|
| 1 | 512 MiB | ESP (FAT32) | Signed Secure Boot chain + GRUB |
| 2 | 1 GiB | ZFS | Boot pool (bpool, lz4) |
| 3 | 64 GiB | ZFS | Root pool (rpool, encrypted, zstd) |
| — | ~53 GiB | — | Unallocated (future use) |

## VM Testing

Test installers against virtual disks with QEMU/KVM, including Secure Boot and TPM:

```bash
# Install QEMU + OVMF + swtpm:
sudo ./test/create-test-vm.sh setup

# Create a 128G sparse virtual disk:
sudo ./test/create-test-vm.sh create

# Check what's available:
./test/create-test-vm.sh status

# Boot the disk (standard UEFI):
sudo ./test/create-test-vm.sh boot

# Boot with Secure Boot enforced + virtual TPM:
sudo ./test/create-test-vm.sh boot-secureboot
```

The Secure Boot VM uses OVMF with Microsoft keys pre-enrolled — simulates a real PC with Secure Boot enabled.

## Scripts Status

| Script | Status | Notes |
|--------|--------|-------|
| `install-kali-zfs.sh` | **Working** | Battle-tested, signed Secure Boot |
| `install-fedora-zfs.sh` | Working | Needs signed boot chain update |
| `install-arch-zfs.sh` | Planned | Needs archzfs repo + AUR shim |
| `install-debian-zfs.sh` | Planned | Closest to Kali (same base) |
| `install-windowstogo.sh` | Planned | Windows To Go on ZFS (last) |

## Disk Identification

Scripts use WWN (World Wide Name) as the primary disk identifier — burned into SSD firmware, survives enclosure swaps and USB port changes. ATA serial and USB enclosure ID are fallbacks.

## License

MIT

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — Design decisions, trade-offs, and technical "why" behind every major choice
- [KNOWN_ISSUES.md](KNOWN_ISSUES.md) — Active bugs, workarounds, and resolved issues
