# AI Agent Instructions for linuxliveinstall

This document enables any AI agent (Claude Haiku 4.5, Claude Sonnet 4.6, Copilot, etc.) to productively work on this project without prior context.

## Project Overview

**linuxliveinstall** is a collection of bash scripts that install portable Linux distributions onto USB SSDs using ZFS (native encryption) with full UEFI Secure Boot support. The primary and most complete installer is for **Kali Linux**; other distros (Debian, Fedora, Arch, Windows To Go) have stub installers.

### Key Design Goals
- **Portable boot**: The USB SSD boots on ANY UEFI machine, including those with password-locked BIOS where Secure Boot cannot be disabled
- **ZFS native encryption**: `aes-256-gcm` with passphrase — no LUKS layer
- **Microsoft-trusted Secure Boot chain**: shimx64 (MS-signed) → grubx64 (Debian-signed) → vmlinuz (Debian-signed) — zero MOK enrollment needed
- **Resume support**: `--resume` flag skips completed phases after a crash

## Repository Structure

```
install-kali-zfs.sh          # Main Kali installer (orchestrator, ~730 lines)
install-debian-zfs.sh        # Debian installer (stub)
install-fedora-zfs.sh        # Fedora installer (stub)
install-arch-zfs.sh          # Arch installer (stub)
install-windowstogo.sh       # Windows To Go (stub)

lib/
  common.sh                  # Shared functions: logging, part(), resume, chroot mounts, cleanup
  disk.sh                    # Disk: partitioning, ZFS pool/dataset creation, cleanup
  secureboot.sh              # Secure Boot: signed chain install (chroot) + host-side verification
  desktop.sh                 # Desktop: KDE Plasma install script generator

configs/
  kali.conf                  # Distro-specific variables (packages, mirrors, disk layout)
  debian.conf
  fedora.conf
  arch.conf
  windows.conf

test/
  unit/                      # BATS unit tests
    test_common.bats
    test_disk.bats
    test_secureboot.bats
  helpers/
    setup.bash               # BATS test helpers
  README.md                  # VM testing guide (QEMU/KVM)

logs/                        # Install logs (gitignored, created at runtime)
tools/                       # Helper utilities
ARCHITECTURE.md              # Detailed architecture documentation
KNOWN_ISSUES.md              # Known bugs and workarounds
```

## Architecture

### Phase System

The installer runs in sequential phases with checkpoint/resume support:

| Phase | Checkpoint | Description |
|-------|-----------|-------------|
| 1     | 1         | Disk preparation (wipe, partition, destroy stale pools) |
| 2     | 2         | Create ZFS pools (bpool + encrypted rpool) |
| 3     | 3         | Create ZFS datasets (root, home, var, swap zvol) |
| 4     | 4         | Extract Kali squashfs from ISO |
| 5a    | 5         | Base system config (hostname, locale, hostid, apt) |
| 5b    | 6         | ZFS + kernel + boot packages (shim-signed, grub-efi) |
| 5c    | 7         | KDE Plasma desktop (replaces XFCE from ISO) |
| 5d    | 8         | GRUB + Secure Boot chain + initramfs + services |
| 5e    | 9         | User account creation (interactive) |
| 6     | 10        | Verify Secure Boot chain (comprehensive host-side audit) |
| 7     | —         | Snapshots + cleanup (unmount, export pools) |

### Lib Modules

**lib/common.sh** — Sourced first by all installers:
- `setup_log_dir()`, `setup_transcript()`, `setup_logging()` — project-local log files in `logs/`
- `part()` — partition naming for by-id, loop, nvme, sd devices
- `init_resume()`, `skip_phase()`, `mark_phase()`, `completed_phase()` — checkpoint system
- `setup_chroot_mounts()` — bind-mounts dev/proc/sys into chroot
- `cleanup_mounts()` — **unmounts in correct order**: sys → proc → dev → ESP → run → remaining (this ordering fixes "pool is busy" on export)
- `export_pools()` — graceful export with force fallback
- `generate_apt_retry_func()` — outputs apt_retry function for chroot heredocs

**lib/disk.sh** — Sourced after common.sh:
- `safe_destroy_pools_on_disk()` — destroys bpool/rpool only if on target disk; regex handles `sd*`, `nvme*`, and `loop*` devices
- `partition_disk()` — GPT layout with ESP + bpool + rpool; uses `partx --update` for loop devices
- `create_zfs_pools()` — ESP format + bpool (grub2-compatible) + rpool (encrypted); uses `-f` flag on rpool to handle stale pool references
- `create_zfs_datasets()` — full dataset tree + swap zvol
- `reimport_pools()` — re-imports for `--resume`

**lib/secureboot.sh** — Sourced after common.sh:
- `generate_secureboot_chroot_script()` — outputs bash code for Phase 5d chroot: GRUB install, signed chain placement, module copy, grub.cfg stubs with `insmod zfs`, sbverify checks, dpkg auto-refresh hook
- `verify_secureboot_chain()` — host-side Phase 6 audit: file presence, GRUB config, module inventory, cryptographic verification with signer extraction, certificate chain analysis, hash inventory, trust chain diagram

**lib/desktop.sh** — Sourced after common.sh:
- `generate_desktop_chroot_script()` — outputs bash for KDE Plasma install + SDDM + extras

### Chroot Pattern

Phases 5a-5e use chroot heredoc scripts. The pattern is:
1. `setup_chroot_mounts "$MNT"` — bind dev/proc/sys
2. Write script to `$MNT/tmp/chroot-5X.sh` (includes `apt_retry()` inline)
3. `sed -i` to replace `__DISK__`, `__HOSTID__`, `__PART_ESP__`, `__DISTRO_NAME__` placeholders
4. `chroot "$MNT" /usr/bin/env bash /tmp/chroot-5X.sh`
5. `rm -f "$MNT/tmp/chroot-5X.sh"`

### Critical Bug Fixes (Preserve These)

1. **Unmount ordering in cleanup** (`cleanup_mounts` in common.sh): Must unmount `sys → proc → dev` BEFORE ESP and other mounts. Wrong order causes "pool is busy" on `zpool export`.

2. **Loop device support in vdev regex** (`safe_destroy_pools_on_disk` in disk.sh): Pattern must include `loop[0-9]+\S*` alongside `sd[a-z]+\S*` and `nvme\S+`.

3. **`-f` flag on `zpool create rpool`** (disk.sh): Overrides stale pool references when prior cleanup couldn't fully destroy/export.

4. **`partx --update` for loop devices** (disk.sh): Loop devices don't auto-detect partitions like real disks.

5. **Pipefail-safe grep** (secureboot.sh): `{ grep -i 'subject' || true; }` prevents `set -o pipefail` from killing the pipeline when `grep` finds no match. Present in sbverify output parsing.

6. **`--allow-change-held-packages`** (Phase 5b): The Kali ISO may have held kernel packages that need upgrading for ZFS DKMS headers.

## Development Environment

- **Host OS**: CachyOS (Arch-based), ZFS pool `zpcachyos`
- **Testing**: QEMU/KVM with OVMF (UEFI), 128G sparse test-disk.raw, swtpm for TPM
- **Test command**: `sudo expect test/.vm/run-install.expect <disk> <kali-iso> [debian-iso] [--resume]`
- **BATS tests**: `bats test/unit/` (requires `pacman -S bats bats-assert bats-file bats-support`)
- **Syntax check**: `bash -n install-kali-zfs.sh lib/*.sh`

## Common Tasks

### Running a VM Test
```bash
# Set up test disk (once)
truncate -s 128G test/.vm/test-disk.raw
sudo losetup --find --show --partscan test/.vm/test-disk.raw

# Run the installer in QEMU
sudo expect test/.vm/run-install.expect /dev/loop0 \
    /path/to/kali-linux-live-amd64.iso \
    /path/to/debian-live-amd64-kde.iso
```

### Adding a New Lib Function
1. Add function to appropriate `lib/*.sh` file
2. Add BATS test in `test/unit/test_*.bats`
3. Run `bash -n lib/*.sh` to syntax-check
4. Run `bats test/unit/` to verify

### Extending to a New Distro
1. Create `configs/<distro>.conf` with package lists and variables
2. Create `install-<distro>-zfs.sh` orchestrator (copy kali as template)
3. Modify chroot scripts for distro-specific package manager (apt vs dnf vs pacman)
4. The lib/ functions are distro-agnostic — reuse them

## Coding Conventions

- `set -euo pipefail` at the top of every script
- Guard against double-sourcing: `[[ -z "${_LIB_X_LOADED:-}" ]] || return 0`
- Use `info()`, `warn()`, `error()` for all user-facing output
- Use `phase()` for major section headers
- Chroot scripts use `[chroot]` prefix in echo statements
- Every `grep` in a pipeline that might return no matches: `{ grep ... || true; }`
- No shellcheck disable comments — fix the warning instead
- Prefer `[[ ]]` over `[ ]` for conditionals
- Quote all variables: `"$var"` not `$var`

## Known Issues

See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for the full list. Key ones:
- `rpool export` occasionally fails with "pool is busy" if cleanup ordering is wrong
- Kali ISO doesn't include `grub-efi-amd64-signed` — requires Debian ISO fallback or internet
- Loop device partitions may not appear without `partx --update`
