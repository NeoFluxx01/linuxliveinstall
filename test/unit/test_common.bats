#!/usr/bin/env bats
###############################################################################
# test/unit/test_common.bats — Tests for lib/common.sh
###############################################################################

load '../helpers/setup'

# ─── part() ────────────────────────────────────────────────────────────────

@test "part: by-id disk uses -partN suffix" {
    _load_lib common.sh
    run part "/dev/disk/by-id/wwn-0x5002538d006b1ef3" 1
    assert_output "/dev/disk/by-id/wwn-0x5002538d006b1ef3-part1"
}

@test "part: loop device uses pN suffix" {
    _load_lib common.sh
    run part "/dev/loop0" 2
    assert_output "/dev/loop0p2"
}

@test "part: nvme device uses pN suffix" {
    _load_lib common.sh
    run part "/dev/nvme0n1" 3
    assert_output "/dev/nvme0n1p3"
}

@test "part: sd device uses bare N suffix" {
    _load_lib common.sh
    run part "/dev/sda" 1
    assert_output "/dev/sda1"
}

# ─── Logging functions ──────────────────────────────────────────────────────

@test "info outputs green INFO tag" {
    _load_lib common.sh
    run info "test message"
    assert_output --partial "INFO"
    assert_output --partial "test message"
}

@test "warn outputs yellow WARN tag" {
    _load_lib common.sh
    run warn "warning message"
    assert_output --partial "WARN"
    assert_output --partial "warning message"
}

# ─── setup_log_dir ─────────────────────────────────────────────────────────

@test "setup_log_dir creates logs/ directory" {
    _load_lib common.sh
    setup_log_dir "$TEST_TMPDIR"
    [ -d "$TEST_TMPDIR/logs" ]
    [ "$LOGDIR" = "$TEST_TMPDIR/logs" ]
}

# ─── checkpoint / resume ───────────────────────────────────────────────────

@test "completed_phase returns 0 when no state file" {
    _load_lib common.sh
    STATEFILE="$TEST_TMPDIR/.nonexistent-state"
    run completed_phase
    assert_output "0"
}

@test "mark_phase and completed_phase round-trip" {
    _load_lib common.sh
    STATEFILE="$TEST_TMPDIR/.test-state"
    mark_phase 5
    run completed_phase
    assert_output "5"
}

@test "skip_phase returns true for completed phases when RESUME=true" {
    _load_lib common.sh
    STATEFILE="$TEST_TMPDIR/.test-state"
    RESUME=true
    mark_phase 3
    run skip_phase 2
    assert_success
}

@test "skip_phase returns false for future phases when RESUME=true" {
    _load_lib common.sh
    STATEFILE="$TEST_TMPDIR/.test-state"
    RESUME=true
    mark_phase 3
    run skip_phase 5
    assert_failure
}

@test "skip_phase always returns false when RESUME=false" {
    _load_lib common.sh
    STATEFILE="$TEST_TMPDIR/.test-state"
    RESUME=false
    mark_phase 10
    run skip_phase 1
    assert_failure
}

# ─── generate_apt_retry_func ───────────────────────────────────────────────

@test "generate_apt_retry_func outputs a valid bash function" {
    _load_lib common.sh
    output="$(generate_apt_retry_func)"
    # Should define apt_retry
    echo "$output" | grep -q 'apt_retry()'
    # Should be valid bash (no syntax errors)
    bash -n <(echo "$output")
}
