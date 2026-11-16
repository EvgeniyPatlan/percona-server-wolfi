#!/usr/bin/env bash
# run-bats.sh <bats> <file.bats|dir>...
# Runs each bats suite (a file; a directory means every *.bats in it, sorted) with TAP output and --timing, and fails
# when a suite fails OR when every test of a suite was skipped (an image test suite that skips everything tested
# nothing: wrong image, missing pull). All suites run; the exit status is 1 if any failed. Used by mk/tests.mk.
set -euo pipefail

usage() { echo "usage: run-bats.sh <bats> <file.bats|dir>..." >&2; exit 2; }
(($# >= 2)) || usage
bats=$1
shift
files=()
for a in "$@"; do
  if [[ -d $a ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$a" -maxdepth 1 -name '*.bats' | LC_ALL=C sort)
  else
    [[ -f $a ]] || { echo "no such suite: $a" >&2; exit 2; }
    files+=("$a")
  fi
done
((${#files[@]})) || { echo "run-bats.sh: no .bats files in $*" >&2; exit 2; }

rc=0
for f in "${files[@]}"; do
  out=$(mktemp)
  frc=0
  "$bats" --formatter tap --timing "$f" | tee "$out" || frc=$?
  total=$(grep -cE '^(not )?ok [0-9]+' "$out" || true)
  skipped=$(grep -cE '^ok [0-9]+ .* # skip' "$out" || true)
  rm -f "$out"
  name=${f##*/}
  if ((frc != 0)); then
    echo "FAILED $name (bats exit $frc)" >&2
    rc=1
  elif ((total == 0)); then
    echo "NO-TESTS $name: no test ran" >&2
    rc=1
  elif ((skipped == total)); then
    echo "ALL-SKIPPED $name: every one of its $total test(s) was skipped" >&2
    rc=1
  fi
  echo "suite $name: $total test(s), $skipped skipped"
done
exit "$rc"
