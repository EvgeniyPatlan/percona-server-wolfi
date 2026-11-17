#!/usr/bin/env bash
# smoke.sh: melange `test:` for the percona-toolkit package.
# Runs inside the melange test container with percona-toolkit, percona-server-server and percona-server-client
# installed (normally as root; works unprivileged too). The recipe copies this file in through the staged source dir
# (scripts/melange-build.sh) and runs:
#   PT_VERSION=<ver>-<rel> bash tests/smoke.sh
# Checks: the 42 tools of the rpm are there and report PT_VERSION, then pt-heartbeat (the Percona Operator's
# sidecar) writes and checks heartbeats on a throwaway mysqld, and pt-mysql-summary / pt-summary run.
set -euo pipefail

PT_VERSION=${PT_VERSION:?PT_VERSION (e.g. 3.7.1-4) must be set}
# the rpm's /usr/bin/pt-* (official percona/percona-toolkit:3.7.1-4)
TOOLS="pt-align pt-archiver pt-config-diff pt-deadlock-logger pt-diskstats pt-duplicate-key-checker
pt-eustack-resolver pt-fifo-split pt-find pt-fingerprint pt-fk-error-logger pt-galera-log-explainer pt-heartbeat
pt-index-usage pt-ioprofile pt-k8s-debug-collector pt-kill pt-mext pt-mongodb-index-check pt-mongodb-query-digest
pt-mongodb-summary pt-mysql-summary pt-online-schema-change pt-pg-summary pt-pmp pt-query-digest pt-replica-find
pt-replica-restart pt-secure-collect pt-show-grants pt-sift pt-slave-delay pt-slave-find pt-slave-restart pt-stalk
pt-summary pt-table-checksum pt-table-sync pt-table-usage pt-upgrade pt-variable-advisor pt-visual-explain"

step() { printf '\n=== %s\n' "$*"; }
fail() {
  printf 'SMOKE FAIL: %s\n' "$*" >&2
  exit 1
}

as_user=()
if [[ $(id -u) == 0 ]]; then as_user=(--user=root); fi

work=$(mktemp -d)
sock=$work/mysql.sock
pid=
cleanup() {
  local rc=$?
  if [[ -n $pid ]] && kill -0 "$pid" 2> /dev/null; then
    kill "$pid" 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
  fi
  if ((rc != 0)) && [[ -f $work/error.log ]]; then
    echo "--- last 60 lines of $work/error.log ---" >&2
    tail -n 60 "$work/error.log" >&2 || true
  fi
  rm -rf "$work"
  exit "$rc"
}
trap cleanup EXIT

step "tools and versions"
n=0
for t in $TOOLS; do
  [[ -x /usr/bin/$t ]] || fail "missing /usr/bin/$t"
  # exit status not checked: pt-summary --version exits 1 after printing it (upstream, also in the official image)
  out=$("$t" --version 2>&1) || true
  [[ $out == *"$PT_VERSION"* ]] || fail "$t --version does not report $PT_VERSION: $out"
  n=$((n + 1))
done
echo "ok: $n tools report $PT_VERSION"
extra=$(find /usr/bin -maxdepth 1 -name 'pt-*' | wc -l)
[[ $extra -eq $n ]] || fail "/usr/bin has $extra pt-* tools, the rpm $n"

step "throwaway Percona Server"
mysqld --no-defaults "${as_user[@]}" --datadir="$work/data" --log-error="$work/error.log" --initialize-insecure ||
  fail "mysqld --initialize-insecure failed"
mkdir -p "$work/files"
mysqld --no-defaults "${as_user[@]}" --datadir="$work/data" --socket="$sock" --skip-networking --mysqlx=OFF \
  --pid-file="$work/mysqld.pid" --log-error="$work/error.log" --secure-file-priv="$work/files" --log-bin=binlog \
  --server-id=1 &
pid=$!
for _ in $(seq 1 120); do
  if mysqladmin --no-defaults --user=root --socket="$sock" ping > /dev/null 2>&1; then break; fi
  kill -0 "$pid" 2> /dev/null || fail "mysqld exited during startup"
  sleep 1
done
mysqladmin --no-defaults --user=root --socket="$sock" ping > /dev/null 2>&1 || fail "mysqld not ready after 120s"
mysql --no-defaults --user=root --socket="$sock" -e 'CREATE DATABASE sys_operator'

step "pt-heartbeat (the operator's flags)"
pt-heartbeat --update --replace --fail-successive-errors 20 --check-read-only --create-table \
  --database sys_operator --table heartbeat --user root --socket "$sock" --run-time 3 --interval 1 ||
  fail "pt-heartbeat --update"
rows=$(mysql --no-defaults --user=root --socket="$sock" -N -B -e 'SELECT COUNT(*) FROM sys_operator.heartbeat')
[[ $rows -ge 1 ]] || fail "no heartbeat row"
lag=$(pt-heartbeat --check --database sys_operator --table heartbeat --user root --socket "$sock" --master-server-id 1) ||
  fail "pt-heartbeat --check"
echo "ok: heartbeat rows $rows, lag $lag"

step "pt-mysql-summary and pt-summary"
out=$(pt-mysql-summary --user root --socket "$sock" 2>&1) || fail "pt-mysql-summary: $out"
grep -q '# Percona Toolkit MySQL Summary Report' <<< "$out" || fail "pt-mysql-summary: no report header"
echo "ok: pt-mysql-summary ($(wc -l <<< "$out") lines)"
out=$(pt-summary 2>&1) || fail "pt-summary: $out"
grep -q '# Percona Toolkit System Summary Report' <<< "$out" || fail "pt-summary: no report header"
echo "ok: pt-summary ($(wc -l <<< "$out") lines)"

step "pt-show-grants and pt-duplicate-key-checker (DBI tools)"
pt-show-grants --user root --socket "$sock" | grep -q "GRANT" || fail "pt-show-grants"
pt-duplicate-key-checker --user root --socket "$sock" --databases sys_operator > /dev/null || fail "pt-duplicate-key-checker"
echo "ok"

echo
echo "percona-toolkit smoke: all checks passed"
