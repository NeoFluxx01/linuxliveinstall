#!/usr/bin/env bash
###############################################################################
# Create a QEMU/KVM test environment for installer development
#
# Creates a virtual disk image that mimics the USB SSD, and provides
# commands to run the installer against it and boot-test the result.
#
# Supports Secure Boot testing via OVMF with enrolled Microsoft keys.
#
# Usage:
#   sudo ./test/create-test-vm.sh setup       # Install QEMU + OVMF
#   sudo ./test/create-test-vm.sh create       # Create virtual disk + VM vars
#   sudo ./test/create-test-vm.sh install       # Run installer against vdisk
#   sudo ./test/create-test-vm.sh boot         # Boot the installed system
#   sudo ./test/create-test-vm.sh boot-secureboot  # Boot with Secure Boot enforced
#   sudo ./test/create-test-vm.sh clean        # Delete test artifacts
#   sudo ./test/create-test-vm.sh status       # Show current test env state
###############################################################################
set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_DIR="$PROJECT_DIR/test"

VM_DIR="$TEST_DIR/.vm"                 # VM artifacts (gitignored)
VDISK="$VM_DIR/test-disk.raw"          # Virtual USB SSD
VDISK_SIZE="128G"                      # Match real Samsung 128 GB SSD
VM_RAM="4096"                          # MB
VM_CPUS="4"
VM_NAME="linuxliveinstall-test"

# OVMF firmware paths (vary by distro)
OVMF_CODE=""
OVMF_VARS_TEMPLATE=""
OVMF_VARS="$VM_DIR/OVMF_VARS.fd"      # Per-VM writable copy

# Secure Boot OVMF (with Microsoft keys pre-enrolled)
OVMF_CODE_SB=""
OVMF_VARS_TEMPLATE_SB=""
OVMF_VARS_SB="$VM_DIR/OVMF_VARS_SB.fd"

# ─── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header(){ echo -e "\n${BOLD}${CYAN}── $* ──${NC}\n"; }

# ─── Detect OVMF paths ─────────────────────────────────────────────────────
detect_ovmf() {
    # Arch / CachyOS (edk2-ovmf package)
    if [[ -f /usr/share/edk2/x64/OVMF_CODE.4m.fd ]]; then
        OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
        OVMF_VARS_TEMPLATE="/usr/share/edk2/x64/OVMF_VARS.4m.fd"
    elif [[ -f /usr/share/edk2/x64/OVMF_CODE.fd ]]; then
        OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.fd"
        OVMF_VARS_TEMPLATE="/usr/share/edk2/x64/OVMF_VARS.fd"
    # Debian / Ubuntu / Kali
    elif [[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]]; then
        OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
        OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS_4M.fd"
    elif [[ -f /usr/share/OVMF/OVMF_CODE.fd ]]; then
        OVMF_CODE="/usr/share/OVMF/OVMF_CODE.fd"
        OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS.fd"
    # Fedora
    elif [[ -f /usr/share/edk2/ovmf/OVMF_CODE.fd ]]; then
        OVMF_CODE="/usr/share/edk2/ovmf/OVMF_CODE.fd"
        OVMF_VARS_TEMPLATE="/usr/share/edk2/ovmf/OVMF_VARS.fd"
    fi

    # Secure Boot variants (with Microsoft keys enrolled)
    if [[ -f /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd ]]; then
        OVMF_CODE_SB="/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd"
        OVMF_VARS_TEMPLATE_SB="/usr/share/edk2/x64/OVMF_VARS.4m.fd"
    elif [[ -f /usr/share/OVMF/OVMF_CODE_4M.secboot.fd ]]; then
        OVMF_CODE_SB="/usr/share/OVMF/OVMF_CODE_4M.secboot.fd"
        OVMF_VARS_TEMPLATE_SB="/usr/share/OVMF/OVMF_VARS_4M.secboot.fd"
    elif [[ -f /usr/share/edk2/x64/OVMF_CODE.secboot.fd ]]; then
        OVMF_CODE_SB="/usr/share/edk2/x64/OVMF_CODE.secboot.fd"
        OVMF_VARS_TEMPLATE_SB="/usr/share/edk2/x64/OVMF_VARS.fd"
    fi
}

# ─── Commands ───────────────────────────────────────────────────────────────

cmd_setup() {
    header "Installing QEMU + OVMF test dependencies"
    [[ $EUID -eq 0 ]] || error "Run with sudo for package installation"

    if command -v pacman &>/dev/null; then
        info "Detected Arch/CachyOS — using pacman"
        pacman -S --needed --noconfirm \
            qemu-full \
            edk2-ovmf \
            swtpm
    elif command -v apt-get &>/dev/null; then
        info "Detected Debian/Ubuntu/Kali — using apt"
        apt-get update
        apt-get install -y \
            qemu-system-x86 \
            ovmf \
            swtpm
    elif command -v dnf &>/dev/null; then
        info "Detected Fedora — using dnf"
        dnf install -y \
            qemu-kvm \
            edk2-ovmf \
            swtpm
    else
        error "Unsupported distro — install qemu-system-x86_64 and OVMF manually"
    fi

    # Verify
    command -v qemu-system-x86_64 &>/dev/null || error "qemu-system-x86_64 not found after install"
    detect_ovmf
    [[ -n "$OVMF_CODE" ]] || error "OVMF firmware not found after install"

    info "QEMU:      $(qemu-system-x86_64 --version | head -1)"
    info "OVMF Code: $OVMF_CODE"
    info "OVMF Vars: $OVMF_VARS_TEMPLATE"
    if [[ -n "$OVMF_CODE_SB" ]]; then
        info "OVMF SB:   $OVMF_CODE_SB (Secure Boot firmware available)"
    else
        warn "No Secure Boot OVMF found — boot-secureboot won't work"
    fi
    info ""
    info "Setup complete. Next: sudo ./test/create-test-vm.sh create"
}

cmd_create() {
    header "Creating virtual test disk + OVMF vars"
    detect_ovmf
    [[ -n "$OVMF_CODE" ]] || error "OVMF not found. Run 'setup' first."

    mkdir -p "$VM_DIR"

    if [[ -f "$VDISK" ]]; then
        warn "Virtual disk already exists: $VDISK"
        read -rp "Delete and recreate? (y/N): " yn
        [[ "$yn" =~ ^[Yy] ]] || { info "Keeping existing disk."; return; }
        rm -f "$VDISK"
    fi

    info "Creating sparse virtual disk ($VDISK_SIZE)..."
    # Sparse file — doesn't consume real space until written
    truncate -s "$VDISK_SIZE" "$VDISK"

    info "Creating writable OVMF vars copy..."
    cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"

    if [[ -n "$OVMF_VARS_TEMPLATE_SB" ]]; then
        cp "$OVMF_VARS_TEMPLATE_SB" "$OVMF_VARS_SB"
        info "Secure Boot OVMF vars created"
    fi

    info ""
    info "Virtual disk: $VDISK ($(du -h "$VDISK" | cut -f1) actual / $VDISK_SIZE sparse)"
    info "OVMF vars:    $OVMF_VARS"
    info ""
    info "Next: sudo ./test/create-test-vm.sh install <distro>"
}

cmd_install() {
    local distro="${1:-}"
    header "Running installer against virtual disk"
    detect_ovmf

    [[ -f "$VDISK" ]] || error "Virtual disk not found. Run 'create' first."
    [[ $EUID -eq 0 ]] || error "Installer must run as root"

    # Map the virtual disk image to a loop device so the installer sees it
    # as a normal block device with /dev/disk/by-id/ symlinks
    info "Setting up loop device for virtual disk..."
    LOOP_DEV=$(losetup --find --show "$VDISK")
    info "Loop device: $LOOP_DEV"

    # Create a temporary by-id symlink so the installer's disk detection works
    # (the installer expects /dev/disk/by-id/... paths)
    FAKE_ID="/dev/disk/by-id/test-virtual-disk-128GB"
    ln -sf "$LOOP_DEV" "$FAKE_ID" 2>/dev/null || true

    cleanup_loop() {
        info "Cleaning up loop device..."
        rm -f "$FAKE_ID" 2>/dev/null || true
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    }
    trap cleanup_loop EXIT

    # Figure out which installer to run
    local installer=""
    case "${distro,,}" in
        kali)   installer="$PROJECT_DIR/install-kali-zfs.sh" ;;
        fedora) installer="$PROJECT_DIR/install-fedora-zfs.sh" ;;
        arch)   installer="$PROJECT_DIR/install-arch-zfs.sh" ;;
        debian) installer="$PROJECT_DIR/install-debian-zfs.sh" ;;
        "")
            echo "Available distros:"
            echo "  kali, fedora, arch, debian"
            read -rp "Which distro? " distro
            cmd_install "$distro"
            return
            ;;
        *)      error "Unknown distro: $distro" ;;
    esac

    [[ -f "$installer" ]] || error "Installer not found: $installer"

    info ""
    info "Installer:   $installer"
    info "Target disk: $FAKE_ID -> $LOOP_DEV -> $VDISK"
    info ""
    warn "The installer's disk detection will need to be pointed at:"
    warn "  $FAKE_ID"
    warn ""
    warn "You can either:"
    warn "  1. Edit the DISK_* variables in the installer temporarily"
    warn "  2. Or use the modular installer with --disk=$FAKE_ID"
    info ""
    info "Loop device is ready. You can now run the installer manually:"
    info "  sudo bash $installer"
    info ""
    info "Or press Enter to launch it automatically..."
    read -rp ""

    bash "$installer"
}

cmd_boot() {
    header "Booting VM from virtual disk (UEFI, no Secure Boot)"
    detect_ovmf
    [[ -f "$VDISK" ]]     || error "Virtual disk not found. Run 'create' first."
    [[ -f "$OVMF_VARS" ]] || error "OVMF vars not found. Run 'create' first."
    [[ -n "$OVMF_CODE" ]] || error "OVMF not found. Run 'setup' first."

    info "Starting QEMU with UEFI firmware..."
    info "  RAM: ${VM_RAM}M  CPUs: ${VM_CPUS}  Disk: $VDISK"
    info ""
    info "Console: VGA window (close window or Ctrl+C to stop)"
    info ""

    qemu-system-x86_64 \
        -name "$VM_NAME" \
        -machine q35,accel=kvm \
        -cpu host \
        -smp "$VM_CPUS" \
        -m "$VM_RAM" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OVMF_VARS" \
        -drive file="$VDISK",format=raw,if=virtio,cache=writeback \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-vga \
        -device usb-ehci \
        -device usb-kbd \
        -device usb-mouse \
        -boot order=c \
        -serial mon:stdio
}

cmd_boot_secureboot() {
    header "Booting VM with Secure Boot ENFORCED"
    detect_ovmf
    [[ -f "$VDISK" ]]  || error "Virtual disk not found. Run 'create' first."
    [[ -n "$OVMF_CODE_SB" ]] || error "Secure Boot OVMF not found. Run 'setup' and check for secboot firmware."
    [[ -f "$OVMF_VARS_SB" ]] || error "Secure Boot OVMF vars not found. Run 'create' first."

    info "Starting QEMU with Secure Boot UEFI firmware..."
    info "  This simulates a machine with Microsoft UEFI CA enrolled"
    info "  and Secure Boot enforced — like the Dell AIO PCs."
    info ""
    info "  If the boot chain is properly signed, it will boot."
    info "  If not, the firmware will refuse to load unsigned binaries."
    info ""
    info "  RAM: ${VM_RAM}M  CPUs: ${VM_CPUS}  Disk: $VDISK"
    info ""

    # swtpm provides a virtual TPM 2.0 for PCR measurements
    local TPM_DIR="$VM_DIR/tpm"
    mkdir -p "$TPM_DIR"

    # Start swtpm in the background
    info "Starting virtual TPM 2.0..."
    swtpm socket \
        --tpm2 \
        --tpmstate dir="$TPM_DIR" \
        --ctrl type=unixio,path="$TPM_DIR/swtpm-sock" \
        --flags not-need-init \
        --daemon

    qemu-system-x86_64 \
        -name "${VM_NAME}-secureboot" \
        -machine q35,accel=kvm,smm=on \
        -cpu host \
        -smp "$VM_CPUS" \
        -m "$VM_RAM" \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE_SB" \
        -drive if=pflash,format=raw,file="$OVMF_VARS_SB" \
        -drive file="$VDISK",format=raw,if=virtio,cache=writeback \
        -chardev socket,id=chrtpm,path="$TPM_DIR/swtpm-sock" \
        -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device tpm-tis,tpmdev=tpm0 \
        -device virtio-net-pci,netdev=net0 \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -device virtio-vga \
        -device usb-ehci \
        -device usb-kbd \
        -device usb-mouse \
        -boot order=c \
        -serial mon:stdio
}

cmd_clean() {
    header "Cleaning test VM artifacts"
    if [[ -d "$VM_DIR" ]]; then
        du -sh "$VM_DIR"
        read -rp "Delete $VM_DIR? (y/N): " yn
        [[ "$yn" =~ ^[Yy] ]] || { info "Cancelled."; return; }
        rm -rf "$VM_DIR"
        info "Cleaned."
    else
        info "Nothing to clean — $VM_DIR doesn't exist."
    fi
}

cmd_status() {
    header "Test environment status"
    detect_ovmf

    echo "QEMU:"
    if command -v qemu-system-x86_64 &>/dev/null; then
        echo "  $(qemu-system-x86_64 --version | head -1)"
    else
        echo "  NOT INSTALLED (run: sudo ./test/create-test-vm.sh setup)"
    fi

    echo ""
    echo "OVMF firmware:"
    if [[ -n "$OVMF_CODE" ]]; then
        echo "  Code: $OVMF_CODE"
        echo "  Vars: $OVMF_VARS_TEMPLATE"
    else
        echo "  NOT FOUND"
    fi
    echo "  Secure Boot: ${OVMF_CODE_SB:-NOT FOUND}"

    echo ""
    echo "swtpm (virtual TPM):"
    if command -v swtpm &>/dev/null; then
        echo "  $(swtpm --version 2>&1 | head -1)"
    else
        echo "  NOT INSTALLED"
    fi

    echo ""
    echo "Virtual disk:"
    if [[ -f "$VDISK" ]]; then
        echo "  $VDISK"
        echo "  Apparent: $VDISK_SIZE  Actual: $(du -h "$VDISK" | cut -f1)"
    else
        echo "  NOT CREATED (run: sudo ./test/create-test-vm.sh create)"
    fi

    echo ""
    echo "OVMF vars copies:"
    [[ -f "$OVMF_VARS" ]]    && echo "  Standard:    $OVMF_VARS" || echo "  Standard:    not created"
    [[ -f "$OVMF_VARS_SB" ]] && echo "  Secure Boot: $OVMF_VARS_SB" || echo "  Secure Boot: not created"

    echo ""
    echo "KVM:"
    if [[ -r /dev/kvm ]]; then
        echo "  Available (/dev/kvm accessible)"
    elif [[ -e /dev/kvm ]]; then
        echo "  Exists but not readable (add user to kvm group)"
    else
        echo "  NOT AVAILABLE (no hardware virtualization?)"
    fi
}

# ─── Main ───────────────────────────────────────────────────────────────────
case "${1:-}" in
    setup)           cmd_setup ;;
    create)          cmd_create ;;
    install)         cmd_install "${2:-}" ;;
    boot)            cmd_boot ;;
    boot-secureboot) cmd_boot_secureboot ;;
    clean)           cmd_clean ;;
    status)          cmd_status ;;
    *)
        echo "Usage: $(basename "$0") <command>"
        echo ""
        echo "Commands:"
        echo "  setup            Install QEMU, OVMF, swtpm"
        echo "  create           Create virtual disk + OVMF vars"
        echo "  install [distro] Run installer against virtual disk"
        echo "  boot             Boot VM (UEFI, no Secure Boot)"
        echo "  boot-secureboot  Boot VM with Secure Boot + TPM enforced"
        echo "  clean            Delete test artifacts"
        echo "  status           Show test environment state"
        exit 1
        ;;
esac
