#!/usr/bin/env bash
###############################################################################
# Portable Windows To Go on USB SSD — Installer (PLANNED)
#
# Status: Not yet implemented
# Priority: Last
#
# Approach:
#   - Use a Windows ISO as source
#   - Apply WIM/ESD image to a partition on the USB SSD
#   - Configure as Windows To Go (portable Windows)
#   - Disable automounting of internal drives (SAN policy)
#     * Rufus uses this same technique: sets the SAN policy to
#       "Offline All" so the internal machine drives don't appear
#       in Windows, preventing accidental writes to host storage.
#   - Secure Boot works natively (Windows bootloader is MS-signed)
#
# SAN Policy for portable Windows:
#   The key to safe portable Windows is the Storage Area Network (SAN)
#   policy. Setting it to "4" (Offline All) prevents Windows from
#   automounting internal drives on the host machine. This is what
#   Rufus does under the hood for Windows To Go.
#   Registry: HKLM\SYSTEM\CurrentControlSet\Services\partmgr\Parameters
#     SanPolicy = 4
#   Or via diskpart in WinPE: san policy=OfflineAll
#
# See configs/windows.conf for planned settings.
###############################################################################
echo "Windows To Go installer is not yet implemented."
echo "See configs/windows.conf for the planned configuration."
exit 1
