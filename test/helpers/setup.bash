#!/usr/bin/env bash
###############################################################################
# test/helpers/setup.bash — Shared BATS test helpers
#
# Loaded by each *.bats file via:
#   load '../helpers/setup'
###############################################################################

# Load bats helper libraries (installed via pacman on Arch/CachyOS)
load '/usr/lib/bats-support/load'
load '/usr/lib/bats-assert/load'

# Project root
export PROJECT_DIR="${BATS_TEST_DIRNAME}/../.."

# Source lib files in a safe (non-root) test context
# We override functions that require root so tests can run unprivileged.
_load_lib() {
    local lib="$1"
    # Stub out error() to avoid exit 1 killing the test runner
    error() { echo "ERROR: $*" >&2; return 1; }
    source "$PROJECT_DIR/lib/$lib"
}

# Create a temp directory for test artifacts (auto-cleaned by BATS)
setup() {
    export TEST_TMPDIR="$(mktemp -d)"
}

teardown() {
    [[ -d "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}
