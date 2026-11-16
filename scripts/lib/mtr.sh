#!/usr/bin/env bash
# MTR result helpers (sourced by mtr-container.sh and the unit tests).

# mtr_failed_tests <mtr-output>: names of failed tests, one per line, sorted unique.
# MTR prints "main.foo 'combination'   [ fail ]" (worker prefixes like "w2" may precede). The test name is the
# first token that looks like <suite>.<test>. "[ retry-fail ]" / "[ retry-pass ]" are not final results.
mtr_failed_tests() {
  # The LAST result line of each test decides: with --retry-failure a first "[ fail ]" followed by
  # "[ retry-pass ]" is a pass. (Format assumed from MTR 8.x/9.x; host-verify with a real mtr-<suite>.txt.)
  awk '
    /\[ (pass|fail|timeout|skip|disabled|retry-pass|retry-fail|retry-skip) \]/ {
      st = ($0 ~ /\[ (fail|timeout|retry-fail) \]/) ? 1 : 0
      for (i = 1; i <= NF; i++) if ($i ~ /^[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+$/) { last[$i] = st; break }
    }
    END { for (t in last) if (last[t]) print t }' "$1" | sort -u
}

# mtr_skip_names <skip-file>: test names of the skip list. Each line is "<test> <reason>"; blank lines and
# "#" comments are ignored. A line without a reason is an error (returns 1, message on stderr).
mtr_skip_names() {
  local f=$1 line name reason n=0
  [[ -r $f ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line#"${line%%[![:space:]]*}"}
    [[ -z $line || $line == \#* ]] && continue
    name=${line%%[[:space:]]*}
    reason=${line#"$name"}
    reason=${reason#"${reason%%[![:space:]]*}"}
    if [[ -z $reason ]]; then
      echo "$f:$n: skip entry '$name' has no reason" >&2
      return 1
    fi
    printf '%s\n' "$name"
  done < "$f"
}

# mtr_unexpected_failures <mtr-output> <skip-file>: failed tests that are not in the skip list.
mtr_unexpected_failures() {
  local skips t
  skips=$(mtr_skip_names "$2") || return 1
  while IFS= read -r t; do
    [[ -z $t ]] && continue
    grep -qxF -- "$t" <<<"$skips" || printf '%s\n' "$t"
  done < <(mtr_failed_tests "$1")
}
