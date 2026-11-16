#!/usr/bin/env bats

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  . "$ROOT/scripts/lib/mtr.sh"
  cat >"$BATS_TEST_TMPDIR/out.txt" <<'X'
main.alpha                                [ pass ]   10
main.beta 'innodb'                        [ fail ]
w2 main.gamma                             [ fail ]  timeout
main.delta                                [ retry-pass ]
main.eps                                  [ skip ]  not applicable
X
}

@test "failed tests are extracted, passes and skips ignored" {
  run mtr_failed_tests "$BATS_TEST_TMPDIR/out.txt"
  [ "$output" = $'main.beta\nmain.gamma' ]
}

@test "skip list entries remove known failures" {
  printf '# c\n\nmain.beta env only: no O_DIRECT on tmpfs\n' >"$BATS_TEST_TMPDIR/skip.txt"
  run mtr_unexpected_failures "$BATS_TEST_TMPDIR/out.txt" "$BATS_TEST_TMPDIR/skip.txt"
  [ "$status" -eq 0 ]
  [ "$output" = main.gamma ]
}

@test "empty skip list reports every failure" {
  : >"$BATS_TEST_TMPDIR/skip.txt"
  run mtr_unexpected_failures "$BATS_TEST_TMPDIR/out.txt" "$BATS_TEST_TMPDIR/skip.txt"
  [ "$output" = $'main.beta\nmain.gamma' ]
}

@test "skip entry without a reason is rejected" {
  printf 'main.beta\n' >"$BATS_TEST_TMPDIR/skip.txt"
  run mtr_unexpected_failures "$BATS_TEST_TMPDIR/out.txt" "$BATS_TEST_TMPDIR/skip.txt"
  [ "$status" -ne 0 ]
  [[ $output == *"no reason"* ]]
}

@test "committed skip files are valid" {
  for f in "$ROOT"/tests/mtr/skip-*.txt; do mtr_skip_names "$f" >/dev/null; done
}

@test "a failure that passes on retry is not a failure" {
  printf "main.flaky   w1 [ fail ]\nRetrying test main.flaky\nmain.flaky   w1 [ retry-pass ]\nmain.bad w2 [ fail ]\nmain.bad w2 [ retry-fail ]\n" >"$BATS_TEST_TMPDIR/r.txt"
  run mtr_failed_tests "$BATS_TEST_TMPDIR/r.txt"
  [ "$output" = main.bad ]
}
