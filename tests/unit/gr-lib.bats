#!/usr/bin/env bats
# Unit tests for the pure helpers of tests/image/gr-lib.bash (no docker).

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  source "$ROOT/tests/image/gr-lib.bash"
}

@test "rand_secret: requested length, hex only, different each time" {
  a=$(rand_secret 32)
  b=$(rand_secret 32)
  [ "${#a}" -eq 32 ]
  [[ $a =~ ^[0-9a-f]+$ ]]
  [ "$a" != "$b" ]
}

@test "gr_mysqld_args: unique id, report host, gtid options" {
  run gr_mysqld_args 2 host-b
  [ "$status" -eq 0 ]
  [[ $output == *"--server-id=2"* ]]
  [[ $output == *"--report-host=host-b"* ]]
  [[ $output == *"--gtid-mode=ON"* ]]
  [[ $output == *"--enforce-gtid-consistency=ON"* ]]
  [[ $output == *"--log-bin=binlog"* ]]
}

@test "gr_online_count: takes the last ONLINE_COUNT line" {
  run gr_online_count <<< $'noise\nONLINE_COUNT=1\nmore\nONLINE_COUNT=3\n'
  [ "$status" -eq 0 ]
  [ "$output" = 3 ]
}

@test "gr_online_count: fails without a count" {
  run gr_online_count <<< $'ERROR: nothing\n'
  [ "$status" -eq 1 ]
}

@test "gr_online_js: counts ONLINE members of the topology" {
  run gr_online_js
  [[ $output == *"defaultReplicaSet.topology"* ]]
  [[ $output == *"ONLINE_COUNT="* ]]
}
