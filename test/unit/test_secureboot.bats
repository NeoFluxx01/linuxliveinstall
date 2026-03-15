#!/usr/bin/env bats
###############################################################################
# test/unit/test_secureboot.bats — Tests for lib/secureboot.sh
###############################################################################

load '../helpers/setup'

# ─── lib loads without error ───────────────────────────────────────────────

@test "lib/secureboot.sh sources without error" {
    _load_lib common.sh
    _load_lib secureboot.sh
}

# ─── generate_secureboot_chroot_script ─────────────────────────────────────

@test "secureboot chroot script contains signed shim path" {
    _load_lib common.sh
    _load_lib secureboot.sh
    output="$(generate_secureboot_chroot_script)"
    echo "$output" | grep -q 'shimx64.efi.signed'
}

@test "secureboot chroot script contains grub module copy" {
    _load_lib common.sh
    _load_lib secureboot.sh
    output="$(generate_secureboot_chroot_script)"
    echo "$output" | grep -q 'Copying GRUB modules to ESP'
}

@test "secureboot chroot script uses pipefail-safe grep" {
    _load_lib common.sh
    _load_lib secureboot.sh
    output="$(generate_secureboot_chroot_script)"
    # Verify { grep ... || true; } pattern (pipefail fix)
    echo "$output" | grep -q '{ grep -i .subject. || true; }'
}

@test "secureboot chroot script contains grub.cfg with insmod zfs" {
    _load_lib common.sh
    _load_lib secureboot.sh
    output="$(generate_secureboot_chroot_script)"
    echo "$output" | grep -q 'insmod zfs'
}

@test "secureboot chroot script installs dpkg hook" {
    _load_lib common.sh
    _load_lib secureboot.sh
    output="$(generate_secureboot_chroot_script)"
    echo "$output" | grep -q '99-secureboot-esp-sync'
}

@test "secureboot chroot script is valid bash syntax" {
    _load_lib common.sh
    _load_lib secureboot.sh
    output="$(generate_secureboot_chroot_script)"
    bash -n <(echo "$output")
}

# ─── verify_secureboot_chain ──────────────────────────────────────────────

@test "verify_secureboot_chain function exists" {
    _load_lib common.sh
    _load_lib secureboot.sh
    declare -f verify_secureboot_chain > /dev/null
}
