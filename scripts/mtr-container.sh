#!/usr/bin/env bash
# Runs INSIDE the MTR container (see mk/tests.mk, target mtr-nightly): installs percona-server-test from the local
# repo mounted at /repo, runs the mysql-test suites as a non-root user and decides pass/fail against the skip lists.
# Env: SUITES (comma separated), PARALLEL, HOST_UID, HOST_GID, MTR_ARGS (extra mysql-test-run.pl arguments),
#      MTR_EXTRA_PKGS (extra apk packages). /work = repo (read-only), /results = out/results, /mtrvar = tmpfs.
set -euo pipefail
. /work/scripts/lib/common.sh
. /work/scripts/lib/mtr.sh

: "${SUITES:?}" "${PARALLEL:?}" "${HOST_UID:?}" "${HOST_GID:?}"
[[ $SUITES =~ ^[A-Za-z0-9_,.-]+$ ]] || die "bad SUITES: $SUITES"
[[ $PARALLEL =~ ^[0-9]+$ ]] || die "bad PARALLEL: $PARALLEL"

# the -test subpackage has no-depends: the runtime deps are installed explicitly (perl for mysql-test-run.pl)
# shellcheck disable=SC2086
apk add --no-cache -X /repo percona-server-test percona-server-server percona-server-client percona-server-rocksdb percona-server-scripts \
  percona-server-js perl bash procps diffutils ${MTR_EXTRA_PKGS:-} >&2

adduser -D -u 1001 mtr 2>/dev/null || true
test_dir=/usr/share/mysql-test
[[ -f $test_dir/mysql-test-run.pl ]] || die "no $test_dir/mysql-test-run.pl in percona-server-test"
chown -R mtr "$test_dir" /mtrvar

rc=0
IFS=, read -ra suites <<<"$SUITES"
for s in "${suites[@]}"; do
  out=/results/mtr-$s.txt
  skip=/work/tests/mtr/skip-$s.txt
  mtr_skip_names "$skip" >/dev/null || die "invalid skip list $skip"
  log_info "mtr suite $s (parallel=$PARALLEL)"
  set +e
  # shellcheck disable=SC2086
  su mtr -s /bin/sh -c "cd $test_dir && exec perl mysql-test-run.pl --suite=$s --parallel=$PARALLEL \
    --vardir=/mtrvar/$s --force --max-test-fail=0 --retry-failure=1 ${MTR_ARGS:-}" >"$out" 2>&1
  mtr_rc=$?
  set -e
  unexpected=$(mtr_unexpected_failures "$out" "$skip")
  failed=$(mtr_failed_tests "$out")
  nskip=$(mtr_skip_names "$skip" | wc -l)
  {
    echo
    echo "== mtr-nightly summary: suite=$s mtr_exit=$mtr_rc =="
    echo "failed: $(grep -c . <<<"$failed" || true)  skip-listed: $nskip"
    if [[ -n $unexpected ]]; then echo "UNEXPECTED FAILURES:"; echo "$unexpected"; fi
  } >>"$out"
  if [[ -n $unexpected ]]; then
    log_warn "suite $s: unexpected failures: $(tr '\n' ' ' <<<"$unexpected")"
    rc=1
  elif ((mtr_rc != 0)) && [[ -z $failed ]]; then
    # nonzero exit without any failed test: MTR itself broke (startup, missing binary); never a pass
    log_warn "suite $s: mtr exited $mtr_rc without a test result, see $out"
    echo "MTR EXITED $mtr_rc WITHOUT A TEST RESULT" >>"$out"
    rc=1
  else
    log_info "suite $s: ok"
  fi
done
chown -R "$HOST_UID:$HOST_GID" /results
exit "$rc"
