# VM Testing Guide

## Overview

The test harness uses QEMU/KVM with OVMF (UEFI firmware) to test installers against virtual disks. It supports:

- **Standard UEFI boot** — verify the install works
- **Secure Boot enforced** — OVMF with Microsoft UEFI CA enrolled, rejects unsigned binaries
- **Virtual TPM 2.0** — via swtpm, for PCR measurement testing

## Setup

```bash
# Install dependencies (QEMU, OVMF, swtpm):
sudo ./create-test-vm.sh setup

# Create a 128G sparse virtual disk (only uses actual space as written):
sudo ./create-test-vm.sh create
```

## Testing Workflow

### 1. Run the installer

The installer needs to target the virtual disk. Two approaches:

**Loop device (automated):**
```bash
sudo ./create-test-vm.sh install kali
```
This creates a loop device from the virtual disk image and guides you through pointing the installer at it.

**Manual (more control):**
```bash
# Set up loop device
sudo losetup --find --show test/.vm/test-disk.raw
# Returns e.g. /dev/loop0

# Edit installer disk vars to point at /dev/loop0, then run it
sudo ./install-kali-zfs.sh

# Clean up
sudo losetup -d /dev/loop0
```

### 2. Boot test (standard UEFI)

```bash
sudo ./create-test-vm.sh boot
```

Opens a QEMU window. You should see:
1. OVMF firmware initializes
2. GRUB menu appears
3. ZFS encryption passphrase prompt
4. System boots to login

SSH is forwarded: `ssh -p 2222 user@localhost`

### 3. Boot test (Secure Boot enforced)

```bash
sudo ./create-test-vm.sh boot-secureboot
```

This uses OVMF firmware with Microsoft keys pre-enrolled and SMM (System Management Mode) enabled. The firmware will **reject any unsigned EFI binary**.

If the boot chain is properly signed:
- shimx64.efi loads (Microsoft-signed → accepted)
- grubx64.efi loads (Debian-signed, trusted by shim → accepted)
- vmlinuz loads (Debian-signed, verified via shim protocol → accepted)

If anything is unsigned, you'll see a Secure Boot violation error.

### 4. Clean up

```bash
sudo ./create-test-vm.sh clean
```

## VM Artifacts

All VM files are stored in `test/.vm/` (gitignored):
- `test-disk.raw` — 128G sparse virtual disk
- `OVMF_VARS.fd` — writable UEFI variable store (standard)
- `OVMF_VARS_SB.fd` — writable UEFI variable store (Secure Boot)
- `tpm/` — virtual TPM state

## Tips

- The virtual disk is sparse — `ls -lh` shows 128G but `du -h` shows actual usage
- QEMU runs with KVM acceleration (hardware virtualization)
- Close the QEMU window or press Ctrl+C in the terminal to stop the VM
- Reset OVMF vars by re-running `create` if the firmware state gets messy
