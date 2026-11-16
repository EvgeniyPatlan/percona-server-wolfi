#!/usr/bin/env bats
# Unit tests for the pure helpers of tests/image/xb-lib.bash (no docker).

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  source "$ROOT/tests/image/xb-lib.bash"
  source "$ROOT/tests/fixtures/upgrade-lib.bash"
}

@test "rand_secret: requested length, hex only, different each time" {
  a=$(rand_secret 32)
  b=$(rand_secret 32)
  [ "${#a}" -eq 32 ]
  [[ $a =~ ^[0-9a-f]+$ ]]
  [ "$a" != "$b" ]
}

@test "xbcloud_s3_args: endpoint, bucket and credentials, path-style lookup" {
  run xbcloud_s3_args http://10.0.0.5:9000 bkt AK SK
  [[ $output == *"--s3-endpoint=http://10.0.0.5:9000"* ]]
  [[ $output == *"--s3-bucket=bkt"* ]]
  [[ $output == *"--s3-access-key=AK"* ]]
  [[ $output == *"--s3-secret-key=SK"* ]]
  [[ $output == *"--s3-bucket-lookup=PATH"* ]]
}

@test "xb_completed_ok: detects the final xtrabackup line" {
  run xb_completed_ok <<< $'260101 xtrabackup: Transaction log\n260101 12:00:00 completed OK!'
  [ "$status" -eq 0 ]
  run xb_completed_ok <<< $'260101 12:00:00 Error: failed'
  [ "$status" -eq 1 ]
}

@test "xb_restore_state_matches: ignores server.version, flags mismatches" {
  printf 'server.version=9.7.2-3.1\nrows.innodb=1000\nchecksum.innodb=42\n' > "$BATS_TEST_TMPDIR/e"
  printf 'rows.innodb=1000\nchecksum.innodb=42\nserver.version=9.7.2-2\n' > "$BATS_TEST_TMPDIR/a"
  run xb_restore_state_matches "$BATS_TEST_TMPDIR/e" "$BATS_TEST_TMPDIR/a"
  [ "$status" -eq 0 ]
  printf 'rows.innodb=1000\nchecksum.innodb=43\n' > "$BATS_TEST_TMPDIR/a"
  run xb_restore_state_matches "$BATS_TEST_TMPDIR/e" "$BATS_TEST_TMPDIR/a"
  [ "$status" -eq 1 ]
  [[ $output == *"mismatch checksum.innodb"* ]]
}
