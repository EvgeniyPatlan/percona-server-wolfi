#!/usr/bin/env bats

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  TMP=$BATS_TEST_TMPDIR
  cat > "$TMP/v.yaml" <<'Y'
ps_version: 9.7.2
ps_release: 2
url: "https://x.example/a/b?c=1&d=2"
digest: "sha256:abc/def&ghi\jkl"
Y
}

@test "substitutes version and release" {
  printf '@@ps_version@@-r@@ps_release@@\n' > "$TMP/t"
  run "$ROOT/scripts/render.sh" "$TMP/t" "$TMP/v.yaml" "$TMP/o"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/o")" = "9.7.2-r2" ]
}
@test "unknown key fails naming it and creates no output" {
  printf 'x @@nope@@\n' > "$TMP/t"
  run "$ROOT/scripts/render.sh" "$TMP/t" "$TMP/v.yaml" "$TMP/o"
  [ "$status" -eq 1 ]; [[ "$output" == *nope* ]]
  [ ! -e "$TMP/o" ]
}
@test "text without placeholders is unchanged byte for byte" {
  # shellcheck disable=SC2016
  printf 'a: b\n\n  c: "d" $x \\ & /\nno newline' > "$TMP/t"
  run "$ROOT/scripts/render.sh" "$TMP/t" "$TMP/v.yaml" "$TMP/o"
  [ "$status" -eq 0 ]
  cmp "$TMP/t" "$TMP/o"
}
@test "values with slash ampersand colon dot backslash are safe" {
  printf 'u=@@url@@ d=@@digest@@ u2=@@url@@\n' > "$TMP/t"
  run "$ROOT/scripts/render.sh" "$TMP/t" "$TMP/v.yaml" "$TMP/o"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/o")" = 'u=https://x.example/a/b?c=1&d=2 d=sha256:abc/def&ghi\jkl u2=https://x.example/a/b?c=1&d=2' ]
}
@test "usage error with wrong arg count" {
  run "$ROOT/scripts/render.sh" "$TMP/t"
  [ "$status" -ne 0 ]
}
@test "make render and lint-recipes are no-ops without templates" {
  cd "$ROOT"
  run make render
  [ "$status" -eq 0 ]
  run make lint-recipes
  [ "$status" -eq 0 ]
}
