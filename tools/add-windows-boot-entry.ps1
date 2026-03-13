<#
.SYNOPSIS
    Adds a USB drive's UEFI bootloader to the Windows Boot Manager menu.

.DESCRIPTION
    On machines with password-locked BIOS where you can't access the boot
    menu (F12) or change boot order, this script lets you boot from a USB
    drive by adding it as a Windows Boot Manager entry.

    The firmware boots Windows Boot Manager (which it already trusts),
    then WBM presents a menu where you can choose the USB entry.

    Works because the USB drive uses Microsoft-trusted Secure Boot keys
    (shimx64.efi signed by Microsoft UEFI 3rd-party CA).

.PARAMETER Action
    list     - Show available UEFI boot entries
    add      - Add the USB drive as a boot option
    remove   - Remove a previously added USB boot option
    boot-next - Set USB as the next one-time boot target

.EXAMPLE
    # Run as Administrator:
    .\add-windows-boot-entry.ps1 list
    .\add-windows-boot-entry.ps1 add
    .\add-windows-boot-entry.ps1 boot-next

.NOTES
    Requires: Administrator privileges
    Safe: Does not modify existing boot entries, only adds a new one.
    Reversible: Use 'remove' to undo.
#>

param(
    [Parameter(Position=0)]
    [ValidateSet('list', 'add', 'remove', 'boot-next')]
    [string]$Action = 'list'
)

# Require elevation
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> 'Run as Administrator'" -ForegroundColor Yellow
    exit 1
}

$EntryDescription = "USB Kali Linux (Secure Boot)"
$EfiPath = "\EFI\BOOT\BOOTX64.EFI"

function Find-UsbEfiPartition {
    # Find USB drives with an EFI System Partition
    $usbDisks = Get-Disk | Where-Object { $_.BusType -eq 'USB' }
    if (-not $usbDisks) {
        Write-Host "No USB drives detected." -ForegroundColor Yellow
        return $null
    }

    Write-Host "`nUSB drives found:" -ForegroundColor Cyan
    foreach ($disk in $usbDisks) {
        Write-Host "  Disk $($disk.Number): $($disk.FriendlyName) ($([math]::Round($disk.Size / 1GB, 1)) GB)"

        $partitions = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
            Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }

        foreach ($part in $partitions) {
            # Try to get the volume letter
            $vol = Get-Volume -Partition $part -ErrorAction SilentlyContinue
            $letter = $vol.DriveLetter
            if (-not $letter) {
                # Assign a temporary drive letter
                $letter = (68..90 | ForEach-Object { [char]$_ } |
                    Where-Object { -not (Test-Path "${_}:\") } | Select-Object -First 1)
                Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -AccessPath "${letter}:\" -ErrorAction SilentlyContinue
            }

            $efiFile = "${letter}:$EfiPath"
            if (Test-Path $efiFile) {
                Write-Host "    ESP found: ${letter}:\ with $EfiPath" -ForegroundColor Green
                return @{
                    DiskNumber = $disk.Number
                    PartitionNumber = $part.PartitionNumber
                    DriveLetter = $letter
                    EfiFile = $efiFile
                    FriendlyName = $disk.FriendlyName
                }
            } else {
                Write-Host "    ESP at ${letter}:\ but no $EfiPath" -ForegroundColor Yellow
            }
        }
    }

    Write-Host "No USB drive with EFI bootloader found." -ForegroundColor Red
    return $null
}

function Show-BootEntries {
    Write-Host "`n=== Current UEFI Boot Entries ===" -ForegroundColor Cyan
    bcdedit /enum firmware | Out-String | Write-Host
}

function Add-UsbBootEntry {
    $usb = Find-UsbEfiPartition
    if (-not $usb) { return }

    Write-Host "`nAdding boot entry for: $($usb.FriendlyName)" -ForegroundColor Cyan
    Write-Host "  EFI path: $EfiPath"
    Write-Host "  Description: $EntryDescription"
    Write-Host ""

    # Create a new firmware boot entry
    # Using bcdedit to add to the firmware boot manager
    $result = bcdedit /copy "{bootmgr}" /d "$EntryDescription" 2>&1
    if ($result -match '\{([0-9a-f-]+)\}') {
        $newGuid = "{$($Matches[1])}"
        Write-Host "Created entry: $newGuid" -ForegroundColor Green

        # Set the entry to point to the USB drive's EFI bootloader
        bcdedit /set $newGuid path $EfiPath
        bcdedit /set $newGuid device "partition=$($usb.DriveLetter):\"

        # Add to the display order
        bcdedit /set "{fwbootmgr}" displayorder $newGuid /addlast

        Write-Host "`nBoot entry added successfully!" -ForegroundColor Green
        Write-Host "On next reboot, Windows Boot Manager will show:" -ForegroundColor Cyan
        Write-Host "  - Windows Boot Manager (default)" -ForegroundColor White
        Write-Host "  - $EntryDescription" -ForegroundColor White
        Write-Host "`nThe GUID for this entry is: $newGuid" -ForegroundColor Yellow
        Write-Host "To remove later: .\add-windows-boot-entry.ps1 remove" -ForegroundColor Yellow
    } else {
        Write-Host "Failed to create boot entry: $result" -ForegroundColor Red
    }
}

function Remove-UsbBootEntry {
    Write-Host "`nSearching for USB boot entries..." -ForegroundColor Cyan

    $bcdOutput = bcdedit /enum all 2>&1 | Out-String
    $entries = [regex]::Matches($bcdOutput, "identifier\s+(\{[0-9a-f-]+\})\s*\r?\ndescription\s+$([regex]::Escape($EntryDescription))")

    if ($entries.Count -eq 0) {
        Write-Host "No '$EntryDescription' entries found." -ForegroundColor Yellow
        return
    }

    foreach ($entry in $entries) {
        $guid = $entry.Groups[1].Value
        Write-Host "  Found: $guid — $EntryDescription" -ForegroundColor Yellow
        $confirm = Read-Host "  Remove this entry? (y/N)"
        if ($confirm -eq 'y' -or $confirm -eq 'Y') {
            bcdedit /delete $guid
            Write-Host "  Removed." -ForegroundColor Green
        }
    }
}

function Set-BootNext {
    $usb = Find-UsbEfiPartition
    if (-not $usb) { return }

    Write-Host "`nSetting one-time boot to USB..." -ForegroundColor Cyan

    # Find existing entry or create one
    $bcdOutput = bcdedit /enum all 2>&1 | Out-String
    $entry = [regex]::Match($bcdOutput, "identifier\s+(\{[0-9a-f-]+\})\s*\r?\ndescription\s+$([regex]::Escape($EntryDescription))")

    if (-not $entry.Success) {
        Write-Host "No existing entry found. Creating one first..." -ForegroundColor Yellow
        Add-UsbBootEntry
        $bcdOutput = bcdedit /enum all 2>&1 | Out-String
        $entry = [regex]::Match($bcdOutput, "identifier\s+(\{[0-9a-f-]+\})\s*\r?\ndescription\s+$([regex]::Escape($EntryDescription))")
    }

    if ($entry.Success) {
        $guid = $entry.Groups[1].Value
        bcdedit /bootsequence $guid
        Write-Host "`nNext boot will go to: $EntryDescription" -ForegroundColor Green
        Write-Host "After that, it returns to normal Windows boot." -ForegroundColor Cyan
        Write-Host "`nReboot now? (y/N): " -NoNewline
        $reboot = Read-Host
        if ($reboot -eq 'y' -or $reboot -eq 'Y') {
            shutdown /r /t 5 /c "Rebooting to USB Kali Linux..."
        }
    } else {
        Write-Host "Could not find or create boot entry." -ForegroundColor Red
    }
}

# Main dispatch
switch ($Action) {
    'list'      { Show-BootEntries }
    'add'       { Add-UsbBootEntry }
    'remove'    { Remove-UsbBootEntry }
    'boot-next' { Set-BootNext }
}
