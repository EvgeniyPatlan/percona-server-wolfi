#!/usr/bin/env bats
# Unit tests for tests/fixtures/upgrade-lib.bash (no docker).

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  source "$ROOT/tests/fixtures/upgrade-lib.bash"
  TMP=$BATS_TEST_TMPDIR
}

stub_sql() {
  case $1 in
    'SELECT COUNT(*) FROM up.t_innodb') echo 1000 ;;
    'CHECKSUM TABLE up.t_innodb') printf 'up.t_innodb\t111\n' ;;
    'CHECKSUM TABLE up.t_rocksdb') printf 'up.t_rocksdb\t222\n' ;;
    'CHECKSUM TABLE up.t_encrypted') printf 'up.t_encrypted\t333\n' ;;
    'SELECT create_options'*) echo 1 ;;
    "SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema='up' AND routine_name='f'") echo "${STUB_JS:-1}" ;;
    'SELECT up.f()') echo 2 ;;
    'SELECT CONCAT('*) printf 'user.u_pam=auth_pam\nuser.u_sha2=caching_sha2_password\n' ;;
    *) return 1 ;;
  esac
}

@test "upgrade_state prints the key=value state" {
  run upgrade_state stub_sql
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = rows.innodb=1000 ]
  [[ $output == *checksum.rocksdb=222* ]]
  [[ $output == *js.f=2* ]]
  [[ $output == *user.u_sha2=caching_sha2_password* ]]
}

@test "upgrade_state omits js.f when the fixture has no JS function (official image without component_js_lang)" {
  STUB_JS=0 run upgrade_state stub_sql
  [ "$status" -eq 0 ]
  [[ $output != *js.f* ]]
  [[ $output == *checksum.encrypted=333* ]]
}

@test "upgrade_state fails when a query fails" {
  failing() { return 1; }
  run upgrade_state failing
  [ "$status" -ne 0 ]
}

@test "expect_compare accepts an identical state and ignores extra actual keys" {
  upgrade_state stub_sql > "$TMP/e"
  { cat "$TMP/e"; echo extra=1; } > "$TMP/a"
  run expect_compare "$TMP/e" "$TMP/a"
  [ "$status" -eq 0 ]
}

@test "expect_compare reports mismatches and missing keys" {
  printf 'a=1\nb=2\nc=3\n' > "$TMP/e"
  printf 'a=1\nb=9\n' > "$TMP/a"
  run expect_compare "$TMP/e" "$TMP/a"
  [ "$status" -eq 1 ]
  [[ $output == *"mismatch b: expected 2, got 9"* ]]
  [[ $output == *"missing c"* ]]
}

@test "expect_compare rejects an empty expectation" {
  : > "$TMP/e"
  printf 'a=1\n' > "$TMP/a"
  run expect_compare "$TMP/e" "$TMP/a"
  [ "$status" -eq 1 ]
}

@test "expect_get returns values containing equals signs and fails on absent keys" {
  printf 'k=a=b\n' > "$TMP/e"
  run expect_get "$TMP/e" k
  [ "$output" = a=b ]
  run expect_get "$TMP/e" nope
  [ "$status" -ne 0 ]
}

@test "upgrade_refusal_text extracts the server's refusal, nothing for other logs" {
  run bash -c 'source "$1"; printf "%s\n" "x [Note] hi" "2026 [ERROR] [MY-013171] [Server] Invalid MySQL server upgrade: Cannot upgrade from 80040 to 90702." | upgrade_refusal_text' _ "$ROOT/tests/fixtures/upgrade-lib.bash"
  [ "$status" -eq 0 ]
  [[ $output == *"Cannot upgrade from 80040"* ]]
  run bash -c 'source "$1"; echo "[ERROR] disk full" | upgrade_refusal_text' _ "$ROOT/tests/fixtures/upgrade-lib.bash"
  [ "$status" -ne 0 ]
}

@test "version_cmp: equal, older, newer, Percona suffix ordering" {
  [ "$(version_cmp 9.7.2-2 9.7.2-2)" = 0 ]
  [ "$(version_cmp 9.7.1-5 9.7.2-1)" = -1 ]
  [ "$(version_cmp 9.7.10-1 9.7.9-9)" = 1 ]
  [ "$(version_cmp 9.7.2-2 9.7.2-3)" = -1 ]
  [ "$(version_cmp 9.7.2-3.1 9.7.2-3)" = 1 ]
  [ "$(version_cmp 9.7.2-10 9.7.2-9)" = 1 ]
  [ "$(version_cmp 9.7.2 9.7.2-0)" = 0 ]
  [ "$(version_cmp 9.7.2-2-debug 9.7.2-2)" = 0 ]
}

@test "version_direction labels" {
  [ "$(version_direction 9.7.2-2 9.7.2-2)" = same-version ]
  [ "$(version_direction 9.7.2-3.1 9.7.2-2)" = downgrade ]
  [ "$(version_direction 9.7.1-2 9.7.2-2)" = upgrade ]
  [ "$(version_direction 9.7.2-1 9.7.2-2)" = upgrade ]
  [ "$(version_direction 9.8.0-1 9.7.2-2)" = downgrade ]
}

@test "server_upgrade_expected only for a strictly newer numeric version" {
  run server_upgrade_expected 9.7.1-9 9.7.2-1
  [ "$status" -eq 0 ]
  run server_upgrade_expected 9.7.2-3.1 9.7.2-2
  [ "$status" -ne 0 ]
  run server_upgrade_expected 9.7.2-2 9.7.2-2
  [ "$status" -ne 0 ]
  run server_upgrade_expected 9.7.2-1 9.7.2-2
  [ "$status" -ne 0 ]
}
