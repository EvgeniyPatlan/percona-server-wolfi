#!/usr/bin/env bats
# Unit tests for tests/compat/compare.sh (pure comparison on fixture directories, no docker).

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  CMP=$ROOT/tests/compat/compare.sh
  TMP=$BATS_TEST_TMPDIR
  mkfix "$TMP/off"
  mkfix "$TMP/wolfi"
  ALLOW=$TMP/allow.yaml
  printf 'entries:\n' > "$ALLOW"
  OUT=$TMP/out.diff
}

# mkfix <dir>: a small, complete fixture set.
mkfix() {
  mkdir -p "$1"
  printf 'max_connections\t151\nhostname\tabc\n' > "$1/variable.tsv"
  printf 'mysql_native_password\tACTIVE\tAUTHENTICATION\tNULL\tGPL\n' > "$1/plugin.tsv"
  printf 'file://component_validate_password\n' > "$1/component.tsv"
  printf 'component_validate_password.so\tf\n' > "$1/file.tsv"
  printf 'PS_VERSION\t9.7.2-3.1\n' > "$1/env.tsv"
  printf 'User\t"mysql"\nCmd\t["mysqld"]\n' > "$1/config.tsv"
}

run_cmp() { run "$CMP" --dirs "$TMP/off" "$TMP/wolfi" --allowlist "$ALLOW" --out "$OUT"; }

@test "identical fixtures: exit 0" {
  run_cmp
  [ "$status" -eq 0 ]
}

@test "differing variable not allowlisted: exit 1 naming it" {
  sed -i 's/^max_connections\t151/max_connections\t200/' "$TMP/wolfi/variable.tsv"
  run_cmp
  [ "$status" -eq 1 ]
  [[ $output == *"variable"*"max_connections"* ]]
  grep -q 'max_connections' "$OUT"
}

@test "same diff allowlisted: exit 0 and recorded as allowed" {
  sed -i 's/^max_connections\t151/max_connections\t200/' "$TMP/wolfi/variable.tsv"
  cat >> "$ALLOW" <<'Y'
  - kind: variable
    name: max_connections
    reason: "test"
Y
  run_cmp
  [ "$status" -eq 0 ]
  grep -q 'allowed' "$OUT"
}

@test "allowlist glob matches" {
  sed -i 's/^max_connections\t151/max_connections\t200/' "$TMP/wolfi/variable.tsv"
  printf '  - kind: variable\n    name: max_*\n    reason: r\n' >> "$ALLOW"
  run_cmp
  [ "$status" -eq 0 ]
}

@test "allowlist kind must match" {
  sed -i 's/^max_connections\t151/max_connections\t200/' "$TMP/wolfi/variable.tsv"
  printf '  - kind: env\n    name: max_connections\n    reason: r\n' >> "$ALLOW"
  run_cmp
  [ "$status" -eq 1 ]
}

@test "allowlist entry without reason: exit 1" {
  printf '  - kind: variable\n    name: hostname\n' >> "$ALLOW"
  run_cmp
  [ "$status" -eq 1 ]
  [[ $output == *reason* ]]
}

@test "allowlist entry with unknown kind: exit 1" {
  printf '  - kind: bogus\n    name: x\n    reason: r\n' >> "$ALLOW"
  run_cmp
  [ "$status" -eq 1 ]
  [[ $output == *kind* ]]
}

@test "item present on one side only is a diff (plugin, file, env, config)" {
  : > "$TMP/wolfi/plugin.tsv"
  printf 'EXTRA\t1\n' >> "$TMP/wolfi/env.tsv"
  : > "$TMP/wolfi/file.tsv"
  printf 'WorkingDir\t"/"\n' >> "$TMP/off/config.tsv"
  run_cmp
  [ "$status" -eq 1 ]
  [[ $output == *mysql_native_password* ]]
  [[ $output == *EXTRA* ]]
  [[ $output == *component_validate_password.so* ]]
  [[ $output == *WorkingDir* ]]
}

@test "values containing tabs and equals signs compare intact" {
  printf 'x\ta\tb=c\n' >> "$TMP/off/plugin.tsv"
  printf 'x\ta\tb=d\n' >> "$TMP/wolfi/plugin.tsv"
  run_cmp
  [ "$status" -eq 1 ]
  [[ $output == *b=c* && $output == *b=d* ]]
}

@test "missing fixture file: exit 2" {
  rm "$TMP/wolfi/env.tsv"
  run_cmp
  [ "$status" -eq 2 ]
}

@test "shipped allowlist is valid and has only reasoned active entries" {
  run "$CMP" --dirs "$TMP/off" "$TMP/wolfi" --out "$OUT"
  [ "$status" -eq 0 ]
  grep -q 'kind: variable' "$ROOT/tests/compat/allowlist.yaml"
  run grep -c '^  - kind:' "$ROOT/tests/compat/allowlist.yaml"
  n=$output
  run grep -c '^    reason:' "$ROOT/tests/compat/allowlist.yaml"
  [ "$output" -eq "$n" ]
}

@test "shipped allowlist: owner-approved deviations active, unapproved ones not" {
  # approved 2026-11-16 after the first laptop diff (see the allowlist header)
  for n in version innodb_version version_comment PS_VERSION CALL_HOME_OPTIONAL_PARAMS ExposedPorts Volumes User 'debug/\*'; do
    grep -Eq "^    name: $n\$" "$ROOT/tests/compat/allowlist.yaml" || { echo "not active: $n"; false; }
  done
  # container=oci is set in the images, not allowlisted
  run grep -E '^    name: container$' "$ROOT/tests/compat/allowlist.yaml"
  [ "$status" -eq 1 ]
}

@test "collect.sh and compare.sh show usage without args" {
  run "$CMP"
  [ "$status" -eq 2 ]
}

@test "allowlist name of only glob characters: exit 1" {
  printf '  - kind: variable\n    name: "*"\n    reason: r\n' >> "$ALLOW"
  run_cmp
  [ "$status" -eq 1 ]
  [[ $output == *"too broad"* ]]
}

@test "file glob does not cross a slash" {
  printf 'lib/a/x.so\tf\n' >> "$TMP/wolfi/file.tsv"
  printf '  - kind: file\n    name: lib/*.so\n    reason: r\n' >> "$ALLOW"
  run_cmp
  [ "$status" -eq 1 ]
  printf '  - kind: file\n    name: lib/*/x.so\n    reason: r\n' >> "$ALLOW"
  run_cmp
  [ "$status" -eq 0 ]
}

@test "stale allowlist entry is warned about, not fatal" {
  printf '  - kind: variable\n    name: nothing_here\n    reason: r\n' >> "$ALLOW"
  run_cmp
  [ "$status" -eq 0 ]
  [[ $output == *stale*nothing_here* ]]
  grep -q 'stale allowlist entry' "$OUT"
}

@test "trailing comments after values are ignored" {
  sed -i 's/^max_connections\t151/max_connections\t200/' "$TMP/wolfi/variable.tsv"
  printf '  - kind: variable   # k\n    name: max_connections # n\n    reason: "a # b" # r\n' >> "$ALLOW"
  run_cmp
  [ "$status" -eq 0 ]
  grep -q 'allowed (a # b)' "$OUT"
}

@test "collection failure exits 2" {
  printf '#!/bin/sh\nexit 1\n' > "$TMP/docker"; chmod +x "$TMP/docker"
  DOCKER=$TMP/docker run "$CMP" img1 img2 --allowlist "$ALLOW" --out "$OUT"
  [ "$status" -eq 2 ]
}
