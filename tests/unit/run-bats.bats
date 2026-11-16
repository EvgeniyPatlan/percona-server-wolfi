#!/usr/bin/env bats
# scripts/run-bats.sh: runs bats suites (files or directories) and fails a suite whose tests were all skipped.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  T=$BATS_TEST_TMPDIR
  S="$ROOT/scripts/run-bats.sh"
  B="$ROOT/out/tools/bats/bin/bats"
  [ -x "$B" ] || skip "vendored bats missing"
  mkdir -p "$T/s"
  printf '@test "a" {\n  skip "no image"\n}\n@test "b" {\n  skip "no image"\n}\n' > "$T/s/allskip.bats"
  printf '@test "a" {\n  skip "refused"\n}\n@test "b" {\n  true\n}\n' > "$T/s/someskip.bats"
  printf '@test "a" {\n  true\n}\n' > "$T/s/pass.bats"
  printf '@test "a" {\n  false\n}\n' > "$T/s/fail.bats"
  printf 'setup_file() { false; }\n@test "a" {\n  true\n}\n' > "$T/s/setupfail.bats"
}

@test "passing and partly skipped suites pass" {
  run "$S" "$B" "$T/s/pass.bats" "$T/s/someskip.bats"
  [ "$status" -eq 0 ]
  [[ $output == *"ok 1 a"* ]]
  [[ $output == *"suite someskip.bats: 2 test(s), 1 skipped"* ]]
}

@test "a suite whose tests were all skipped fails, the others still run" {
  run "$S" "$B" "$T/s/allskip.bats" "$T/s/pass.bats"
  [ "$status" -eq 1 ]
  [[ $output == *"ALL-SKIPPED allskip.bats: every one of its 2 test(s) was skipped"* ]]
  [[ $output == *"suite pass.bats: 1 test(s), 0 skipped"* ]]
}

@test "failing tests and setup_file failures fail" {
  run "$S" "$B" "$T/s/fail.bats"
  [ "$status" -eq 1 ]
  run "$S" "$B" "$T/s/setupfail.bats"
  [ "$status" -eq 1 ]
  [[ $output == *"setup_file failed"* ]]
}

@test "a directory runs every .bats file in it; an empty selection fails" {
  mkdir -p "$T/d"
  cp "$T/s/pass.bats" "$T/d/one.bats"; cp "$T/s/someskip.bats" "$T/d/two.bats"
  run "$S" "$B" "$T/d"
  [ "$status" -eq 0 ]
  [[ $output == *"suite one.bats"* && $output == *"suite two.bats"* ]]
  mkdir -p "$T/empty"
  run "$S" "$B" "$T/empty"
  [ "$status" -eq 2 ]
  run "$S" "$B"
  [ "$status" -eq 2 ]
}
