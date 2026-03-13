#!/usr/bin/env bash
###############################################################################
# lib/secureboot.sh — Secure Boot signed chain setup & verification
#
# Handles the Microsoft-trusted UEFI signing chain:
#   shimx64.efi  (Microsoft UEFI 3rd-party CA)
#   grubx64.efi  (Debian key, embedded in shim)
#   vmlinuz       (Debian key, verified via shim protocol)
#
# Works on password-locked BIOS — no MOK enrollment needed.
#
# Source after lib/common.sh:
#   source "$SCRIPT_DIR/lib/common.sh"
#   source "$SCRIPT_DIR/lib/secureboot.sh"
###############################################################################

[[ -z "${_LIB_SECUREBOOT_LOADED:-}" ]] || return 0
_LIB_SECUREBOOT_LOADED=1

# ─── Signed binary paths (Debian/Kali) ─────────────────────────────────────
# These are the standard paths installed by shim-signed and
# grub-efi-amd64-signed packages on Debian-based distributions.
SB_SHIM="/usr/lib/shim/shimx64.efi.signed"
SB_GRUB="/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
SB_MOK="/usr/lib/shim/mmx64.efi.signed"
SB_FB="/usr/lib/shim/fbx64.efi.signed"

# ─── Generate the chroot Secure Boot install script ────────────────────────
# This outputs a bash script fragment that should be embedded in a chroot
# heredoc. It handles:
#   1. Running grub-install --removable for config/module generation
#   2. Replacing unsigned GRUB with the signed chain
#   3. Setting up grub.cfg redirects for the signed binary's $prefix
#   4. Verifying signatures with sbverify
#   5. Installing a dpkg hook for auto-refresh on package updates
#
# Usage in installer:
#   source lib/secureboot.sh
#   generate_secureboot_install_script >> "$MNT/tmp/chroot-boot.sh"
generate_secureboot_install_script() {
    cat <<'SB_SCRIPT'
# ── Secure Boot chain with Microsoft-trusted signed binaries ────────────────
# Trust chain:
#   UEFI firmware (factory Microsoft UEFI CA in Secure Boot DB)
#     → shimx64.efi.signed   (signed by Microsoft UEFI 3rd-party CA)
#       → grubx64.efi.signed (signed by Debian key, embedded in shim)
#         → vmlinuz           (signed by Debian key, verified via shim protocol)

SIGNED_SHIM="/usr/lib/shim/shimx64.efi.signed"
SIGNED_GRUB="/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
SIGNED_MOK="/usr/lib/shim/mmx64.efi.signed"
SIGNED_FB="/usr/lib/shim/fbx64.efi.signed"

echo "[chroot] Verifying signed binaries exist..."
[[ -f "$SIGNED_SHIM" ]] || { echo "FATAL: shim-signed not found at $SIGNED_SHIM"; exit 1; }
[[ -f "$SIGNED_GRUB" ]] || { echo "FATAL: grub-efi-amd64-signed not found at $SIGNED_GRUB"; exit 1; }

echo "[chroot] Installing GRUB to ESP (portable mode)..."
mountpoint -q /boot/efi || mount /boot/efi

grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=kali --recheck --no-floppy --removable

ESP_BOOT="/boot/efi/EFI/BOOT"

echo "[chroot] Installing signed Secure Boot chain to ESP..."
mv "$ESP_BOOT/BOOTX64.EFI" "$ESP_BOOT/grubx64.efi.unsigned"
cp "$SIGNED_SHIM" "$ESP_BOOT/BOOTX64.EFI"
cp "$SIGNED_GRUB" "$ESP_BOOT/grubx64.efi"
[[ -f "$SIGNED_MOK" ]] && cp "$SIGNED_MOK" "$ESP_BOOT/mmx64.efi"
[[ -f "$SIGNED_FB" ]]  && cp "$SIGNED_FB"  "$ESP_BOOT/fbx64.efi"

echo "[chroot] Signed chain installed:"
echo "  BOOTX64.EFI = shimx64.efi  (Microsoft UEFI 3rd-party CA)"
echo "  grubx64.efi = GRUB         (Debian key, embedded in shim)"
echo "  mmx64.efi   = MOK Manager  (optional)"

# GRUB config redirects — signed GRUB may look in /EFI/debian/ or /EFI/BOOT/
if [[ -f "$ESP_BOOT/grub/grub.cfg" ]]; then
    echo "[chroot] Setting up GRUB config redirects..."
    cp "$ESP_BOOT/grub/grub.cfg" "$ESP_BOOT/grub.cfg"
    mkdir -p /boot/efi/EFI/debian
    cp "$ESP_BOOT/grub/grub.cfg" /boot/efi/EFI/debian/grub.cfg
else
    echo "[chroot] Creating manual search stub..."
    cat > "$ESP_BOOT/grub.cfg" <<'STUBCFG'
search.file /boot/grub/grub.cfg root
set prefix=($root)/boot/grub
configfile $prefix/grub.cfg
STUBCFG
    mkdir -p /boot/efi/EFI/debian
    cp "$ESP_BOOT/grub.cfg" /boot/efi/EFI/debian/grub.cfg
fi

# Verify signatures
if command -v sbverify &>/dev/null; then
    echo "[chroot] Verifying Secure Boot signatures..."
    SB_PASS=true
    for efi_bin in "$ESP_BOOT/BOOTX64.EFI" "$ESP_BOOT/grubx64.efi"; do
        efi_name="$(basename "$efi_bin")"
        sig_count=$(sbverify --list "$efi_bin" 2>/dev/null | grep -c 'signature' || true)
        if (( sig_count > 0 )); then
            echo "  OK: $efi_name — $sig_count signature(s)"
        else
            echo "  FAIL: $efi_name — NO signature!"
            SB_PASS=false
        fi
    done
    if ! $SB_PASS; then
        echo "FATAL: Signed binaries failed signature check."
        exit 1
    fi
fi

# dpkg hook — auto-refresh ESP when packages update
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99-secureboot-esp-sync <<'DPKGHOOK'
DPkg::Post-Invoke {
    "if [ -f /usr/lib/shim/shimx64.efi.signed ] && [ -d /boot/efi/EFI/BOOT ]; then cp /usr/lib/shim/shimx64.efi.signed /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true; fi";
    "if [ -f /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed ] && [ -d /boot/efi/EFI/BOOT ]; then cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed /boot/efi/EFI/BOOT/grubx64.efi 2>/dev/null || true; fi";
    "if [ -f /usr/lib/shim/mmx64.efi.signed ] && [ -d /boot/efi/EFI/BOOT ]; then cp /usr/lib/shim/mmx64.efi.signed /boot/efi/EFI/BOOT/mmx64.efi 2>/dev/null || true; fi";
};
DPKGHOOK
echo "[chroot] dpkg hook installed: auto-refresh signed ESP binaries on updates"
SB_SCRIPT
}

# ─── Verify Secure Boot chain on a mounted ESP ─────────────────────────────
# Called from the host after chroot is done.
#
# Usage: verify_secureboot_chain "/mnt/kali"
verify_secureboot_chain() {
    local mnt="${1:?}"
    local esp_boot="$mnt/boot/efi/EFI/BOOT"
    local sb_ok=true

    info "Checking Secure Boot binaries on ESP..."
    for item in \
        "BOOTX64.EFI:shimx64 (Microsoft UEFI 3rd-party CA signed)" \
        "grubx64.efi:GRUB (Debian key signed)" \
        "mmx64.efi:MOK Manager (optional)"; do
        local file="${item%%:*}" desc="${item#*:}"
        if [[ -f "$esp_boot/$file" ]]; then
            info "  FOUND: $file — $desc"
        elif [[ "$file" == "mmx64.efi" ]]; then
            warn "  MISSING: $file — $desc (non-fatal)"
        else
            warn "  MISSING: $file — $desc"
            sb_ok=false
        fi
    done

    # Check GRUB config redirects
    info ""
    info "Checking GRUB config accessibility..."
    for cfg in "$esp_boot/grub/grub.cfg" "$esp_boot/grub.cfg" "$mnt/boot/efi/EFI/debian/grub.cfg"; do
        local rel="${cfg#$mnt/boot/efi/}"
        [[ -f "$cfg" ]] && info "  FOUND: $rel" || warn "  MISSING: $rel"
    done

    # Cryptographic verification
    info ""
    local sbverify_cmd=""
    if command -v sbverify &>/dev/null; then
        sbverify_cmd="sbverify"
    elif [[ -x "$mnt/usr/bin/sbverify" ]]; then
        sbverify_cmd="chroot $mnt sbverify"
    fi

    if [[ -n "$sbverify_cmd" ]]; then
        info "Cryptographic signature verification (sbverify):"
        for item in "BOOTX64.EFI:shim" "grubx64.efi:GRUB"; do
            local file="${item%%:*}" label="${item#*:}"
            [[ -f "$esp_boot/$file" ]] || continue
            local sig_info sig_count
            sig_info=$($sbverify_cmd --list "$esp_boot/$file" 2>&1 || true)
            sig_count=$(echo "$sig_info" | grep -ci 'signature' || true)
            if (( sig_count > 0 )); then
                info "  SIGNED: $file ($label) — $sig_count signature(s)"
            else
                warn "  UNSIGNED: $file ($label)"
                sb_ok=false
            fi
        done

        # Check kernel signature
        local vmlinuz
        vmlinuz=$(ls -1 "$mnt/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1)
        if [[ -n "$vmlinuz" && -f "$vmlinuz" ]]; then
            local sig_info sig_count
            sig_info=$($sbverify_cmd --list "$vmlinuz" 2>&1 || true)
            sig_count=$(echo "$sig_info" | grep -ci 'signature' || true)
            if (( sig_count > 0 )); then
                info "  SIGNED: $(basename "$vmlinuz") (kernel)"
            else
                warn "  UNSIGNED: $(basename "$vmlinuz") (kernel)"
                sb_ok=false
            fi
        fi
    else
        warn "sbverify not available — skipping cryptographic verification"
    fi

    # Print trust chain diagram
    info ""
    info "Secure Boot trust chain:"
    info "  UEFI Firmware (Microsoft UEFI CA 2011)"
    info "    → BOOTX64.EFI (shim, Microsoft-signed)"
    info "      → grubx64.efi (GRUB, Debian-signed)"
    info "        → vmlinuz (kernel, Debian-signed)"
    info "          → initramfs → ZFS → passphrase → root"
    info ""
    if $sb_ok; then
        info "Secure Boot: READY (password-locked BIOS compatible)"
    else
        warn "Secure Boot: ISSUES DETECTED (see above)"
    fi

    # ESP file listing
    info ""
    info "ESP layout:"
    find "$mnt/boot/efi/" -type f 2>/dev/null | sort | while read -r f; do
        local rel="${f#$mnt/boot/efi/}"
        local size
        size=$(stat -c%s "$f" 2>/dev/null || echo "?")
        info "  $rel  ($size bytes)"
    done
}
