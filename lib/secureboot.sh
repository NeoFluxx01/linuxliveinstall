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
SB_SHIM="/usr/lib/shim/shimx64.efi.signed"
SB_GRUB="/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
SB_MOK="/usr/lib/shim/mmx64.efi.signed"
SB_FB="/usr/lib/shim/fbx64.efi.signed"

# ─── Generate the Secure Boot install script for chroot ────────────────────
# Outputs bash code that should be appended to a chroot heredoc script.
# It handles grub-install, signed chain placement, module copy, grub.cfg
# redirects, signature verification, and the dpkg auto-refresh hook.
#
# Usage in installer:
#   generate_secureboot_chroot_script >> "$MNT/tmp/chroot-boot.sh"
generate_secureboot_chroot_script() {
    cat <<'SB_SCRIPT'
# ── Secure Boot chain with Microsoft-trusted signed binaries ────────────────
SIGNED_SHIM="/usr/lib/shim/shimx64.efi.signed"
SIGNED_GRUB="/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
SIGNED_MOK="/usr/lib/shim/mmx64.efi.signed"
SIGNED_FB="/usr/lib/shim/fbx64.efi.signed"

echo "[chroot] Verifying signed binaries exist..."
[[ -f "$SIGNED_SHIM" ]] || { echo "FATAL: shim-signed binary not found at $SIGNED_SHIM"; exit 1; }
[[ -f "$SIGNED_GRUB" ]] || { echo "FATAL: grub-efi-amd64-signed binary not found at $SIGNED_GRUB"; exit 1; }

echo "[chroot] Installing GRUB to ESP (portable mode)..."
mountpoint -q /boot/efi || mount /boot/efi

grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=__DISTRO_NAME__ --recheck --no-floppy --removable

ESP_BOOT="/boot/efi/EFI/BOOT"

echo "[chroot] Installing signed Secure Boot chain to ESP..."
mv "$ESP_BOOT/BOOTX64.EFI" "$ESP_BOOT/grubx64.efi.unsigned"
cp "$SIGNED_SHIM" "$ESP_BOOT/BOOTX64.EFI"
cp "$SIGNED_GRUB" "$ESP_BOOT/grubx64.efi"
[[ -f "$SIGNED_MOK" ]] && cp "$SIGNED_MOK" "$ESP_BOOT/mmx64.efi"
[[ -f "$SIGNED_FB" ]]  && cp "$SIGNED_FB"  "$ESP_BOOT/fbx64.efi"

echo "[chroot] Secure Boot chain installed:"
echo "  BOOTX64.EFI  = shimx64.efi  (Microsoft UEFI 3rd-party CA signed)"
echo "  grubx64.efi  = GRUB         (Debian/Kali key signed)"
echo "  mmx64.efi    = MOK Manager  (Microsoft UEFI 3rd-party CA signed)"

# ── Copy GRUB modules to ESP for signed GRUB ──────────────────────────────
GRUB_MOD_SRC="/usr/lib/grub/x86_64-efi"
GRUB_MOD_DST="/boot/efi/EFI/debian/x86_64-efi"
if [[ -d "$GRUB_MOD_SRC" ]]; then
    echo "[chroot] Copying GRUB modules to ESP for signed GRUB..."
    mkdir -p "$GRUB_MOD_DST"
    cp "$GRUB_MOD_SRC"/*.mod "$GRUB_MOD_DST/" 2>/dev/null || true
    cp "$GRUB_MOD_SRC"/*.lst "$GRUB_MOD_DST/" 2>/dev/null || true
    mod_count=$(ls -1 "$GRUB_MOD_DST"/*.mod 2>/dev/null | wc -l)
    echo "[chroot] Copied $mod_count GRUB modules to ESP (EFI/debian/x86_64-efi/)"
    for m in zfs zfscrypt zfsinfo part_gpt; do
        if [[ -f "$GRUB_MOD_DST/${m}.mod" ]]; then
            echo "[chroot]   OK: ${m}.mod"
        else
            echo "[chroot]   WARNING: ${m}.mod missing — boot may fail!"
        fi
    done
else
    echo "[chroot] WARNING: GRUB module source not found at $GRUB_MOD_SRC"
fi

# ── GRUB config redirects for signed binary ──────────────────────────────
echo "[chroot] Setting up GRUB config redirects for signed binary..."
mkdir -p /boot/efi/EFI/debian
mkdir -p "$ESP_BOOT/grub"
cat > /boot/efi/EFI/debian/grub.cfg <<'STUBEOF'
insmod part_gpt
insmod zfs
search.file /boot/grub/grub.cfg root
set prefix=($root)/boot/grub
configfile $prefix/grub.cfg
STUBEOF
cp /boot/efi/EFI/debian/grub.cfg "$ESP_BOOT/grub.cfg"
cp /boot/efi/EFI/debian/grub.cfg "$ESP_BOOT/grub/grub.cfg"

# ── Verify signatures with sbverify ──────────────────────────────────────
if command -v sbverify &>/dev/null; then
    echo "[chroot] Verifying Secure Boot signatures..."
    SB_PASS=true

    for efi_bin in "$ESP_BOOT/BOOTX64.EFI" "$ESP_BOOT/grubx64.efi"; do
        efi_name="$(basename "$efi_bin")"
        sig_info=$(sbverify --list "$efi_bin" 2>&1 || true)
        sig_count=$(echo "$sig_info" | grep -ci 'signature' || true)
        if (( sig_count > 0 )); then
            echo "  OK: $efi_name — $sig_count signature(s)"
            echo "$sig_info" | { grep -i 'subject' || true; } | head -1 | sed 's/^/          /'
        else
            echo "  FAIL: $efi_name — NO signature found!"
            SB_PASS=false
        fi
    done

    VMLINUZ_LATEST=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
    if [[ -n "$VMLINUZ_LATEST" && -f "$VMLINUZ_LATEST" ]]; then
        sig_info=$(sbverify --list "$VMLINUZ_LATEST" 2>&1 || true)
        sig_count=$(echo "$sig_info" | grep -ci 'signature' || true)
        if (( sig_count > 0 )); then
            echo "  OK: $(basename "$VMLINUZ_LATEST") — signed kernel"
            echo "$sig_info" | { grep -i 'subject' || true; } | head -1 | sed 's/^/          /'
        else
            echo "  WARNING: $(basename "$VMLINUZ_LATEST") — kernel NOT signed"
        fi
    fi

    if ! $SB_PASS; then
        echo "FATAL: Signed boot binaries failed signature check. Secure Boot will not work."
        exit 1
    fi
else
    echo "[chroot] WARNING: sbverify not available — skipping signature verification"
fi

# ── dpkg hook — auto-refresh ESP on package updates ──────────────────────
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99-secureboot-esp-sync <<'DPKGEOF'
DPkg::Post-Invoke {
    "if [ -f /usr/lib/shim/shimx64.efi.signed ] && [ -d /boot/efi/EFI/BOOT ]; then cp /usr/lib/shim/shimx64.efi.signed /boot/efi/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true; fi";
    "if [ -f /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed ] && [ -d /boot/efi/EFI/BOOT ]; then cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed /boot/efi/EFI/BOOT/grubx64.efi 2>/dev/null || true; fi";
    "if [ -f /usr/lib/shim/mmx64.efi.signed ] && [ -d /boot/efi/EFI/BOOT ]; then cp /usr/lib/shim/mmx64.efi.signed /boot/efi/EFI/BOOT/mmx64.efi 2>/dev/null || true; fi";
    "if [ -f /usr/lib/shim/fbx64.efi.signed ] && [ -d /boot/efi/EFI/BOOT ]; then cp /usr/lib/shim/fbx64.efi.signed /boot/efi/EFI/BOOT/fbx64.efi 2>/dev/null || true; fi";
    "if [ -d /usr/lib/grub/x86_64-efi ] && [ -d /boot/efi/EFI/debian/x86_64-efi ]; then cp /usr/lib/grub/x86_64-efi/*.mod /boot/efi/EFI/debian/x86_64-efi/ 2>/dev/null || true; cp /usr/lib/grub/x86_64-efi/*.lst /boot/efi/EFI/debian/x86_64-efi/ 2>/dev/null || true; fi";
};
DPKGEOF
echo "[chroot] Installed dpkg hook: /etc/apt/apt.conf.d/99-secureboot-esp-sync"
SB_SCRIPT
}

# ─── Verify Secure Boot chain from the host (outside chroot) ───────────────
# Called after all chroot phases are done, from the main orchestrator.
# This is a comprehensive audit: file presence, signatures, certificate chain,
# GRUB modules, and config redirects.
#
# Usage: verify_secureboot_chain "/mnt/kali"
verify_secureboot_chain() {
    local mnt="${1:?}"
    local esp_boot="$mnt/boot/efi/EFI/BOOT"
    local sb_ok=true
    local sb_warnings=0

    # ── File presence ───────────────────────────────────────────────────────
    info "Checking Secure Boot binaries on ESP..."
    for efi_item in \
        "BOOTX64.EFI:shimx64 (Microsoft UEFI 3rd-party CA signed)" \
        "grubx64.efi:GRUB (Debian key signed, validated by shim)" \
        "mmx64.efi:MOK Manager (optional — for manual key enrollment)" \
        "fbx64.efi:Fallback (optional — for NVRAM-less boot)"; do
        local efi_file="${efi_item%%:*}" efi_desc="${efi_item#*:}"
        if [[ -f "$esp_boot/$efi_file" ]]; then
            local efi_size
            efi_size=$(stat -c%s "$esp_boot/$efi_file" 2>/dev/null || echo "?")
            info "  FOUND: $efi_file — $efi_desc ($efi_size bytes)"
        elif [[ "$efi_file" == "mmx64.efi" || "$efi_file" == "fbx64.efi" ]]; then
            warn "  MISSING: $efi_file — $efi_desc (non-fatal)"
        else
            warn "  MISSING: $efi_file — $efi_desc"
            sb_ok=false
        fi
    done

    # ── GRUB config redirects ───────────────────────────────────────────────
    info ""
    info "Checking GRUB config accessibility for signed binary..."
    for cfg_path in \
        "$esp_boot/grub/grub.cfg" \
        "$esp_boot/grub.cfg" \
        "$mnt/boot/efi/EFI/debian/grub.cfg"; do
        local rel_path="${cfg_path#$mnt/boot/efi/}"
        [[ -f "$cfg_path" ]] && info "  FOUND: $rel_path" || warn "  MISSING: $rel_path"
    done

    local debian_cfg="$mnt/boot/efi/EFI/debian/grub.cfg"
    if [[ -f "$debian_cfg" ]]; then
        if grep -q 'insmod zfs' "$debian_cfg"; then
            info "  OK: grub.cfg contains 'insmod zfs'"
        else
            warn "  MISSING: grub.cfg does NOT contain 'insmod zfs' — signed GRUB cannot read ZFS!"
            sb_ok=false
        fi
    fi

    # ── GRUB modules on ESP ─────────────────────────────────────────────────
    info ""
    local grub_mod_dir="$mnt/boot/efi/EFI/debian/x86_64-efi"
    if [[ -d "$grub_mod_dir" ]]; then
        local mod_count
        mod_count=$(ls -1 "$grub_mod_dir"/*.mod 2>/dev/null | wc -l)
        info "GRUB modules on ESP: $mod_count modules in EFI/debian/x86_64-efi/"
        for m in zfs zfscrypt zfsinfo part_gpt fat ext2 normal search search_fs_file configfile linux gzio; do
            if [[ -f "$grub_mod_dir/${m}.mod" ]]; then
                info "  OK: ${m}.mod"
            else
                warn "  MISSING: ${m}.mod"
                [[ "$m" == "zfs" ]] && sb_ok=false
            fi
        done
    else
        warn "GRUB module directory not found: EFI/debian/x86_64-efi/"
        sb_ok=false
    fi

    # ── Cryptographic signature verification ────────────────────────────────
    info ""
    local sbverify_cmd=""
    if command -v sbverify &>/dev/null; then
        sbverify_cmd="sbverify"
    elif [[ -x "$mnt/usr/bin/sbverify" ]]; then
        sbverify_cmd="chroot $mnt sbverify"
    fi

    local shim_signer="" grub_signer="" kernel_signer=""

    if [[ -n "$sbverify_cmd" ]]; then
        info "Cryptographic signature verification:"

        if [[ -f "$esp_boot/BOOTX64.EFI" ]]; then
            local sig_info sig_count
            sig_info=$($sbverify_cmd --list "$esp_boot/BOOTX64.EFI" 2>&1 || true)
            sig_count=$(echo "$sig_info" | grep -ci 'signature' || true)
            shim_signer=$(echo "$sig_info" | { grep -i 'subject' || true; } | head -1 | sed 's/.*CN=//' | sed 's/,.*//')
            if (( sig_count > 0 )); then
                info "  SIGNED: BOOTX64.EFI (shim) — $sig_count signature(s)"
                [[ -n "$shim_signer" ]] && info "          Signer: $shim_signer"
            else
                warn "  UNSIGNED: BOOTX64.EFI (shim)"
                sb_ok=false
            fi
        fi

        if [[ -f "$esp_boot/grubx64.efi" ]]; then
            local sig_info sig_count
            sig_info=$($sbverify_cmd --list "$esp_boot/grubx64.efi" 2>&1 || true)
            sig_count=$(echo "$sig_info" | grep -ci 'signature' || true)
            grub_signer=$(echo "$sig_info" | { grep -i 'subject' || true; } | head -1 | sed 's/.*CN=//' | sed 's/,.*//')
            if (( sig_count > 0 )); then
                info "  SIGNED: grubx64.efi (GRUB) — $sig_count signature(s)"
                [[ -n "$grub_signer" ]] && info "          Signer: $grub_signer"
            else
                warn "  UNSIGNED: grubx64.efi (GRUB)"
                sb_ok=false
            fi
        fi

        local vmlinuz
        vmlinuz=$(ls -1 "$mnt/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1)
        if [[ -n "$vmlinuz" && -f "$vmlinuz" ]]; then
            local sig_info sig_count
            sig_info=$($sbverify_cmd --list "$vmlinuz" 2>&1 || true)
            sig_count=$(echo "$sig_info" | grep -ci 'signature' || true)
            kernel_signer=$(echo "$sig_info" | { grep -i 'subject' || true; } | head -1 | sed 's/.*CN=//' | sed 's/,.*//')
            if (( sig_count > 0 )); then
                info "  SIGNED: $(basename "$vmlinuz") — $sig_count signature(s)"
                [[ -n "$kernel_signer" ]] && info "          Signer: $kernel_signer"
            else
                warn "  UNSIGNED: $(basename "$vmlinuz") (kernel)"
                sb_warnings=$((sb_warnings + 1))
            fi
        fi

        # Certificate chain consistency
        info ""
        info "Certificate chain analysis:"
        if [[ -n "$shim_signer" ]] && echo "$shim_signer" | grep -qi 'microsoft'; then
            info "  OK: Shim signed by Microsoft (trusted by factory UEFI DB)"
        elif [[ -n "$shim_signer" ]]; then
            warn "  UNEXPECTED: Shim signer is '$shim_signer' (expected Microsoft)"
            sb_warnings=$((sb_warnings + 1))
        fi
        if [[ -n "$grub_signer" && -n "$kernel_signer" ]]; then
            if [[ "$grub_signer" == "$kernel_signer" ]]; then
                info "  OK: GRUB and kernel signed by same key ($grub_signer)"
            else
                warn "  MISMATCH: GRUB signer '$grub_signer' != kernel signer '$kernel_signer'"
                sb_warnings=$((sb_warnings + 1))
            fi
        fi
    else
        warn "sbverify not available — cannot perform cryptographic verification"
        sb_warnings=$((sb_warnings + 1))
    fi

    # ── Binary hash inventory ───────────────────────────────────────────────
    info ""
    info "Binary hash inventory (SHA256):"
    for efi_file in BOOTX64.EFI grubx64.efi mmx64.efi fbx64.efi; do
        if [[ -f "$esp_boot/$efi_file" ]]; then
            local hash
            hash=$(sha256sum "$esp_boot/$efi_file" | cut -d' ' -f1)
            info "  $efi_file: ${hash:0:16}..."
        fi
    done
    if [[ -n "${vmlinuz:-}" && -f "${vmlinuz:-}" ]]; then
        local hash
        hash=$(sha256sum "$vmlinuz" | cut -d' ' -f1)
        info "  $(basename "$vmlinuz"): ${hash:0:16}..."
    fi

    # ── Trust chain diagram ─────────────────────────────────────────────────
    info ""
    info "Secure Boot trust chain:"
    info "  ┌─ UEFI Firmware ──────────────────────────────────────────────┐"
    info "  │  Secure Boot DB: Microsoft UEFI CA 2011 (factory-installed)  │"
    info "  └──────────────────────┬───────────────────────────────────────┘"
    info "                         │ validates"
    info "  ┌──────────────────────▼───────────────────────────────────────┐"
    info "  │  BOOTX64.EFI (shimx64)                                      │"
    info "  │  Signed by: Microsoft UEFI Third-Party Marketplace CA        │"
    info "  └──────────────────────┬───────────────────────────────────────┘"
    info "                         │ validates"
    info "  ┌──────────────────────▼───────────────────────────────────────┐"
    info "  │  grubx64.efi (GRUB)                                         │"
    info "  │  Signed by: Debian Secure Boot key (embedded in shim)        │"
    info "  │  Loads: ZFS modules → bpool → /boot/grub/grub.cfg           │"
    info "  └──────────────────────┬───────────────────────────────────────┘"
    info "                         │ validates (shim protocol)"
    info "  ┌──────────────────────▼───────────────────────────────────────┐"
    info "  │  vmlinuz (Linux kernel)                                      │"
    info "  │  Signed by: Debian/Kali Secure Boot key                      │"
    info "  └──────────────────────┬───────────────────────────────────────┘"
    info "                         │ loads"
    info "  ┌──────────────────────▼───────────────────────────────────────┐"
    info "  │  initramfs → ZFS module → passphrase prompt → mount rpool    │"
    info "  └──────────────────────────────────────────────────────────────┘"

    # ── Summary ─────────────────────────────────────────────────────────────
    info ""
    if $sb_ok && (( sb_warnings == 0 )); then
        info "Secure Boot: READY (all checks passed)"
    elif $sb_ok; then
        warn "Secure Boot: READY WITH WARNINGS ($sb_warnings warning(s) — see above)"
    else
        warn "Secure Boot: CRITICAL ISSUES (boot chain is broken)"
    fi

    # ── ESP layout ──────────────────────────────────────────────────────────
    info ""
    info "ESP layout:"
    find "$mnt/boot/efi/" -type f 2>/dev/null | sort | while read -r f; do
        local rel="${f#$mnt/boot/efi/}"
        local size
        size=$(stat -c%s "$f" 2>/dev/null || echo "?")
        info "  $rel  ($size bytes)"
    done
}
