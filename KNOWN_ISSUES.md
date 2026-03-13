# Known Issues & Workarounds

## Active Issues

### 1. Shim crashes in QEMU/OVMF (boot loop)

**Symptom**: When booting the VM with shim as `BOOTX64.EFI`, OVMF shows `BdsDxe: loading Boot0001` then immediately resets. Continuous boot loop.

**Affects**: QEMU/OVMF only. Not yet tested on real hardware.

**Root cause**: Unknown. Kali's `shim-signed` ships shim 15.8 which should have the buffer overrun fix from [rhboot/shim#249](https://github.com/rhboot/shim/issues/249). May be an OVMF version incompatibility or a Kali-specific build issue.

**Workaround for VM testing**: Place signed GRUB directly as `BOOTX64.EFI` (bypassing shim). This allows testing the GRUB → kernel → ZFS chain without shim. Secure Boot verification is skipped but the rest of the boot path works.

```bash
# On the mounted ESP:
cp grubx64.efi BOOTX64.EFI  # signed GRUB as primary bootloader
```

**Next steps**: Test on real Dell hardware with Secure Boot enabled. If shim works on real hardware, the issue is OVMF-specific and VM testing can use the workaround above.

### 2. Kali does not package grub-efi-amd64-signed

**Symptom**: `apt-get install grub-efi-amd64-signed` fails in Kali — package not available.

**Root cause**: Kali is based on Debian Testing but patches `grub-common` with a Kali version suffix (`2.12-9+kali1` vs Debian's `2.12-9`), causing a dependency version mismatch.

**Fix implemented**: Phase 5b downloads the .deb from Debian Trixie, extracts just the signed binary, and places it manually. The Debian repo is removed immediately after. See [ARCHITECTURE.md](ARCHITECTURE.md) for details.

### 3. Signed GRUB drops to shell without ZFS modules on ESP

**Symptom**: Signed GRUB loads but drops to `grub>` shell instead of booting. The `search.file` command fails because GRUB can't read ZFS filesystems.

**Root cause**: Debian's signed GRUB is modular (not monolithic). It doesn't have ZFS compiled in and needs external modules.

**Fix implemented**: Phase 5d now copies all GRUB modules to `/EFI/debian/x86_64-efi/` on the ESP and writes redirect grub.cfg files that `insmod zfs` before searching. The dpkg hook keeps modules in sync on updates.

### 4. Pool export "busy" warnings during install finalization

**Symptom**: `zpool export rpool` warns "pool is busy" during Phase 7.

**Root cause**: Some process or mount inside the chroot may still reference the pool. The lazy unmount (`umount -lf`) doesn't always clean up in time.

**Impact**: Low. The pool can be imported with `-f` on next boot if needed. The installer still completes.

**Workaround**: The installer uses `umount -lf` for all mounts and proceeds despite the warning.

## Resolved Issues

### Loop device partition naming (fixed)

**Was**: Script used `${DISK}-partN` which only works for `/dev/disk/by-id/` paths.

**Fix**: Added `part()` helper function that handles loop, nvme, by-id, and sd device naming patterns. Introduced `PART_ESP`, `PART_BOOT`, `PART_ROOT` computed variables.

### partprobe not creating partition nodes for loop devices (fixed)

**Was**: `partprobe` alone doesn't reliably create `/dev/loop0p1` etc.

**Fix**: Added `partx --update` fallback after `partprobe` for loop devices.

## Known Limitations

### No dual-boot support

The installer formats the target disk completely. It's designed for dedicated portable USB SSDs, not dual-boot configurations.

### Host must have ZFS loaded

The installer runs from the host (Arch/CachyOS) and requires ZFS kernel modules and userspace tools already available. It does not install ZFS on the host.

### ESP modules take ~30 MiB

Copying ~270 GRUB modules to the 512 MiB ESP uses about 30 MiB. This is acceptable given the ESP size but worth noting.

### No automatic GRUB module pruning

All x86_64-efi GRUB modules are copied to the ESP, not just the ones needed for ZFS boot. A minimal set would be: `zfs.mod`, `zfscrypt.mod`, `zfsinfo.mod`, `part_gpt.mod`, `fat.mod`, `ext2.mod`, `normal.mod`, `search.mod`, `search_fs_file.mod`, `configfile.mod`, `linux.mod`, `gzio.mod`. The full set is kept for simplicity and forward compatibility.
