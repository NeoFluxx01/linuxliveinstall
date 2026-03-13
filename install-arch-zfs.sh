#!/usr/bin/env bash
###############################################################################
# Portable Arch Linux on ZFS — Full Installer (PLANNED)
#
# Status: Not yet implemented
# Priority: After Debian (needs archzfs repo + AUR shim-signed)
#
# Key differences from Debian-family installers:
#   - Bootstrap via pacstrap (not debootstrap)
#   - ZFS from archzfs third-party repo or DKMS
#   - Secure Boot shim from AUR (shim-signed)
#   - mkinitcpio instead of initramfs-tools
#   - No apt — uses pacman
#
# See configs/arch.conf for package lists and settings.
###############################################################################
echo "Arch Linux ZFS installer is not yet implemented."
echo "See configs/arch.conf for the planned configuration."
exit 1
