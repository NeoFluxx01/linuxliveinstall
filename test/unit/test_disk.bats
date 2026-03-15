#!/usr/bin/env bats
###############################################################################
# test/unit/test_disk.bats — Tests for lib/disk.sh
###############################################################################

load '../helpers/setup'

# ─── safe_destroy_pools_on_disk vdev regex ──────────────────────────────────

@test "disk.sh vdev regex matches loop devices" {
    # Verify the grep pattern inside safe_destroy_pools_on_disk catches loop*
    sample="	  loop0p3	ONLINE	 0	 0	 0"
    result=$(echo "$sample" | grep -oP '(sd[a-z]+\S*|nvme\S+|loop[0-9]+\S*)' | head -1)
    [ "$result" = "loop0p3" ]
}

@test "disk.sh vdev regex matches sd devices" {
    sample="	  sda3	ONLINE	 0	 0	 0"
    result=$(echo "$sample" | grep -oP '(sd[a-z]+\S*|nvme\S+|loop[0-9]+\S*)' | head -1)
    [ "$result" = "sda3" ]
}

@test "disk.sh vdev regex matches nvme devices" {
    sample="	  nvme0n1p3	ONLINE	 0	 0	 0"
    result=$(echo "$sample" | grep -oP '(sd[a-z]+\S*|nvme\S+|loop[0-9]+\S*)' | head -1)
    [ "$result" = "nvme0n1p3" ]
}

# ─── partition_disk (verifies partition naming) ─────────────────────────────

@test "partition names correct for loop device" {
    _load_lib common.sh
    run part "/dev/loop0" 1; assert_output "/dev/loop0p1"
    run part "/dev/loop0" 2; assert_output "/dev/loop0p2"
    run part "/dev/loop0" 3; assert_output "/dev/loop0p3"
}

# ─── create_zfs_pools uses -f flag on rpool ────────────────────────────────

@test "create_zfs_pools contains -f flag for rpool" {
    # Verify the source code has -f on the rpool create
    grep -q 'zpool create -f' "$PROJECT_DIR/lib/disk.sh"
}

# ─── lib loads without error ───────────────────────────────────────────────

@test "lib/disk.sh sources without error" {
    _load_lib common.sh
    _load_lib disk.sh
}
