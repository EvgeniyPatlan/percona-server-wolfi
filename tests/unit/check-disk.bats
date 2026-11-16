#!/usr/bin/env bats

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  printf '#!/bin/sh\necho 50\n' > "$BATS_TEST_TMPDIR/df50"
  chmod +x "$BATS_TEST_TMPDIR/df50"
  export DF_CMD="$BATS_TEST_TMPDIR/df50"
}

@test "fails when not enough space" {
  MIN_GB=100 run "$ROOT/scripts/check-disk.sh"
  [ "$status" -eq 1 ]; [[ "$output" == *"need 100 GB free, have 50"* ]]
}
@test "passes when enough space" {
  MIN_GB=35 run "$ROOT/scripts/check-disk.sh"
  [ "$status" -eq 0 ]
}
@test "defaults to 100 GB" {
  run "$ROOT/scripts/check-disk.sh"
  [ "$status" -eq 1 ]; [[ "$output" == *"need 100 GB"* ]]
}
