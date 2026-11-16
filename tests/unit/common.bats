#!/usr/bin/env bats

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  source "$ROOT/scripts/lib/common.sh"
  TMP=$BATS_TEST_TMPDIR
  export RETRY_SLEEP=0
  cat > "$TMP/v.yaml" <<'Y'
# a comment
# VERIFY-BEFORE-RELEASE: something
ps_version: 9.7.2
k: "abc"
withc: plain   # trailing comment
url: "https://x/y#frag"
Y
  cat > "$TMP/tools.yaml" <<'Y'
# tools
fake: "example.com/fake@sha256:deadbeef"
Y
}

@test "vars_get plain value" {
  run vars_get "$TMP/v.yaml" ps_version
  [ "$status" -eq 0 ]; [ "$output" = "9.7.2" ]
}
@test "vars_get quoted value" {
  run vars_get "$TMP/v.yaml" k
  [ "$output" = "abc" ]
}
@test "vars_get strips trailing comment and keeps # inside quotes" {
  run vars_get "$TMP/v.yaml" withc; [ "$output" = "plain" ]
  run vars_get "$TMP/v.yaml" url; [ "$output" = "https://x/y#frag" ]
}
@test "vars_get missing key fails" {
  run vars_get "$TMP/v.yaml" nope
  [ "$status" -eq 1 ]; [[ "$output" == *"missing key: nope"* ]]
}
@test "vars_get ignores comments" {
  run vars_get "$TMP/v.yaml" VERIFY-BEFORE-RELEASE
  [ "$status" -eq 1 ]
}
@test "retry 3 false runs exactly 3 attempts" {
  cnt="$TMP/cnt"; : > "$cnt"
  stub() { echo x >> "$cnt"; return 1; }
  run retry 3 stub
  [ "$status" -ne 0 ]; [ "$(wc -l < "$cnt")" -eq 3 ]
}
@test "retry 3 true succeeds first try" {
  cnt="$TMP/cnt"; : > "$cnt"
  stub() { echo x >> "$cnt"; }
  run retry 3 stub
  [ "$status" -eq 0 ]; [ "$(wc -l < "$cnt")" -eq 1 ]
}
@test "ts format" {
  run ts
  [[ "$output" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]
}
@test "die exits 1 with message" {
  run die "boom"
  [ "$status" -eq 1 ]; [[ "$output" == *"boom"* ]]
}
@test "tool builds docker run command" {
  DOCKER=echo TOOLS_FILE="$TMP/tools.yaml" run tool fake -e A=1 -- sh -c hi
  [ "$status" -eq 0 ]
  [[ "$output" == *"-v $PWD:/work"* ]]
  [[ "$output" == *"-w /work"* ]]
  [[ "$output" == *"-e A=1 example.com/fake@sha256:deadbeef sh -c hi"* ]]
}
@test "tool with unknown name fails" {
  DOCKER=echo TOOLS_FILE="$TMP/tools.yaml" run tool nope -- true
  [ "$status" -ne 0 ]
}
