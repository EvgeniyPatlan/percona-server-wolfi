#!/usr/bin/env bash
# smoke.sh: melange `test:` for the percona-mysql-shell package.
# Runs inside the melange test container with percona-mysql-shell (+ its hard dependency percona-mysql-shell-jit),
# percona-server-server and percona-server-client installed. The recipe copies this file in through the staged
# source dir (scripts/melange-build.sh) and runs: MYSQLSH_VERSION=<x.y.z> bash tests/smoke.sh
#
# Env:
#   MYSQLSH_VERSION  required, e.g. 9.7.1 (must appear in `mysqlsh --version`)
#   SKIP_SERVER      set to 1 to skip the --sql checks against a throwaway mysqld
set -euo pipefail

MYSQLSH_VERSION=${MYSQLSH_VERSION:?MYSQLSH_VERSION (e.g. 9.7.1) must be set}

step() { printf '\n=== %s\n' "$*"; }
fail() {
  printf 'SMOKE FAIL: %s\n' "$*" >&2
  exit 1
}
expect() {
  local want=$1 got=$2 what=$3
  [[ $got == "$want" ]] || fail "$what: expected '$want', got '$got'"
  echo "ok: $what = $got"
}

# mysqld refuses to run as root without --user=root.
as_user=()
if [[ $(id -u) == 0 ]]; then as_user=(--user=root); fi

work=$(mktemp -d)
# mysqlsh writes its config, history and log under MYSQLSH_USER_CONFIG_HOME (default ~/.mysqlsh)
export MYSQLSH_USER_CONFIG_HOME=$work/mysqlsh-home MYSQLSH_TERM_COLOR_MODE=nocolor
mkdir -p "$MYSQLSH_USER_CONFIG_HOME"
pid=
cleanup() {
  local rc=$?
  if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  if ((rc != 0)); then
    for f in "$work/error.log" "$MYSQLSH_USER_CONFIG_HOME/mysqlsh.log"; do
      [[ -f $f ]] || continue
      echo "--- last 60 lines of $f ---" >&2
      tail -n 60 "$f" >&2 || true
    done
  fi
  rm -rf "$work"
  exit "$rc"
}
trap cleanup EXIT

# shell_out <mode-and-args...>: run mysqlsh, stdout only (stderr to a file shown on failure).
shell_out() {
  mysqlsh "$@" 2>"$work/mysqlsh.err" || {
    cat "$work/mysqlsh.err" >&2
    fail "mysqlsh $* exited non-zero"
  }
}

step "version"
ver=$(mysqlsh --version)
echo "$ver"
[[ $ver == *"$MYSQLSH_VERSION"* ]] || fail "mysqlsh --version lacks $MYSQLSH_VERSION"

step "layout"
for f in /usr/bin/mysqlsh /usr/libexec/mysqlsh/mysqlbinlog /usr/lib/mysqlsh/libjitexecutor.so /usr/share/mysqlsh/sysvars.json; do
  [[ -e $f ]] || fail "missing $f"
  echo "ok: $f"
done
ls /usr/lib/mysql/plugins/authentication_*_client.so >/dev/null 2>&1 || fail "no client auth plugins in /usr/lib/mysql/plugins"

step "JavaScript mode (GraalVM jit executor, percona-mysql-shell-jit)"
expect 2 "$(shell_out --js -e 'print(1+1)')" "mysqlsh --js print(1+1)"

step "Python mode"
expect 2 "$(shell_out --py -e 'print(1+1)')" "mysqlsh --py print(1+1)"
shell_out --py -e 'import sys; print(sys.version)'

step "bundled plugins load (plugins/, python-packages/: certifi, yaml)"
# mysqlsh loads every plugin at start and only logs a failure (stdout shows a one-line warning)
if grep -E 'Error loading|ModuleNotFoundError' "$MYSQLSH_USER_CONFIG_HOME/mysqlsh.log"; then
  fail "mysqlsh plugins failed to load (see $MYSQLSH_USER_CONFIG_HOME/mysqlsh.log)"
fi
expect ok "$(shell_out --py -e 'import certifi, yaml; print("ok")')" "python modules certifi, yaml"

if [[ ${SKIP_SERVER:-0} == 1 ]]; then
  echo "server checks skipped"
  echo
  echo "SMOKE PASS"
  exit 0
fi

step "initialize and start a throwaway server"
# Default client paths (/tmp/mysql.sock, /tmp/mysqlx.sock, 3306/33060) so `mysqlsh root@localhost` needs no options.
datadir=$work/data
sock=/tmp/mysql.sock xsock=/tmp/mysqlx.sock
mkdir -p "$work/files"
mysqld --no-defaults "${as_user[@]}" --datadir="$datadir" --secure-file-priv="$work/files" \
  --log-error="$work/error.log" --initialize-insecure ||
  fail "mysqld --initialize-insecure failed"
mysqld --no-defaults "${as_user[@]}" --datadir="$datadir" --socket="$sock" --port=3306 --bind-address=127.0.0.1 \
  --mysqlx-socket="$xsock" --mysqlx-port=33060 --mysqlx-bind-address=127.0.0.1 \
  --pid-file="$work/mysqld.pid" --secure-file-priv="$work/files" --log-error="$work/error.log" &
pid=$!
for _ in $(seq 1 120); do
  if mysqladmin --no-defaults --user=root --socket="$sock" ping >/dev/null 2>&1; then break; fi
  kill -0 "$pid" 2>/dev/null || fail "mysqld exited during startup"
  sleep 1
done
mysqladmin --no-defaults --user=root --socket="$sock" ping >/dev/null 2>&1 || fail "mysqld not ready after 120s"

step "SQL mode"
# the plain URI form (protocol auto-detected); --no-password: root has an empty password, never prompt
out=$(shell_out root@localhost --sql --no-password -e 'select 1')
echo "$out"
grep -qx 1 <<<"$out" || fail "mysqlsh root@localhost --sql: no '1' row"
# both protocols explicitly
# tabbed output: a header line, then the value
expect 1 "$(shell_out --sql --mysql --user=root --no-password --socket="$sock" --result-format=tabbed \
  -e 'select 1' | tail -n1)" "classic protocol select 1"
expect 1 "$(shell_out --sql --mysqlx --user=root --no-password --host=127.0.0.1 --port=33060 \
  --result-format=tabbed -e 'select 1' | tail -n1)" "X protocol select 1"
shell_out --sql --mysql --user=root --no-password --socket="$sock" -e 'select @@version, @@version_comment'

step "JavaScript against the server (the operator's mysqlsh --js usage)"
expect 1 "$(shell_out --js --mysql --user=root --no-password --socket="$sock" \
  -e 'print(session.runSql("select 1").fetchOne()[0])')" "mysqlsh --js session.runSql"

step "shutdown"
mysqladmin --no-defaults --user=root --socket="$sock" shutdown
wait "$pid" || fail "mysqld exited non-zero on shutdown"
pid=

echo
echo "SMOKE PASS"
