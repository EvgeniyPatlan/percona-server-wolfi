#!/usr/bin/env bats

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  cd "$BATS_TEST_TMPDIR" || return
  git init -q .
  tree=$(git write-tree)
  c=$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git commit-tree "$tree" -m init)
  git update-ref HEAD "$c"
  mkdir -p out/logs out/results versions
  echo log > out/logs/a.log; echo res > out/results/x.txt; echo "k: v" > versions/9.7.yaml
}

@test "report bundles logs, results, versions and manifest" {
  run "$ROOT/scripts/report.sh"
  [ "$status" -eq 0 ]
  f=$(find out -name "report-*.tar.gz")
  list=$(tar tzf "$f")
  [[ "$list" == *out/logs/a.log* ]]
  [[ "$list" == *out/results/x.txt* ]]
  [[ "$list" == *versions/9.7.yaml* ]]
  [[ "$list" == *MANIFEST* ]]
  tar xzOf "$f" MANIFEST | grep -q "$(git rev-parse HEAD)"
}
@test "report does not include previous reports" {
  "$ROOT/scripts/report.sh"; sleep 1; "$ROOT/scripts/report.sh"
  f=$(find out -name "report-*.tar.gz" | sort | tail -1)
  run tar tzf "$f"
  [[ "$output" != *report-* ]]
}

@test "report lists UNEXPECTED-PATH lines from the logs in the MANIFEST" {
  printf 'x\nUNEXPECTED-PATH (moved into percona-server-server): usr/lib/foo\n' > out/logs/pkg-percona-server-1.log
  printf 'UNEXPECTED-PATH (moved into percona-server-server): usr/lib/foo\nUNEXPECTED-PATH (moved into x): etc/bar\n' \
    > out/logs/pkg-percona-server-2.log
  run "$ROOT/scripts/report.sh"
  [ "$status" -eq 0 ]
  f=$(find out -name "report-*.tar.gz" | sort | tail -1)
  m=$(tar xzOf "$f" MANIFEST)
  [[ "$m" == *"unexpected_paths: 2"* ]]
  [[ "$m" == *"pkg-percona-server-1.log: UNEXPECTED-PATH (moved into percona-server-server): usr/lib/foo"* ]]
  [[ "$m" == *"etc/bar"* ]]
}

@test "report says unexpected_paths: 0 when the logs have none" {
  run "$ROOT/scripts/report.sh"
  f=$(find out -name "report-*.tar.gz" | sort | tail -1)
  tar xzOf "$f" MANIFEST | grep -qx 'unexpected_paths: 0'
}

@test "report also lists BUILD-PATH LEAK lines (LEAK_SCAN=warn runs do not fail on them)" {
  printf 'BUILD-PATH LEAK: usr/lib/x.so\n' > out/logs/pkg-a.log
  run "$ROOT/scripts/report.sh"
  f=$(find out -name "report-*.tar.gz" | sort | tail -1)
  m=$(tar xzOf "$f" MANIFEST)
  [[ "$m" == *"build_path_leaks: 1"* ]]
  [[ "$m" == *"pkg-a.log: BUILD-PATH LEAK: usr/lib/x.so"* ]]
}

@test "only package build logs are scanned (test names in other logs do not count)" {
  printf 'ok 1 report lists UNEXPECTED-PATH lines\n' > out/logs/test-unit-1.log
  run "$ROOT/scripts/report.sh"
  f=$(find out -name "report-*.tar.gz" | sort | tail -1)
  tar xzOf "$f" MANIFEST | grep -qx 'unexpected_paths: 0'
}
