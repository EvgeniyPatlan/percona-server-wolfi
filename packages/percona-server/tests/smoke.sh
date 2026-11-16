#!/usr/bin/env bash
# smoke.sh: melange `test:` for the percona-server package.
# Runs inside the melange test container (as root) with percona-server-server, -client, -rocksdb, -js,
# -test, mecab-ipadic and perl installed (normally as root; works unprivileged too). The recipe copies this file in through the staged source dir
# (scripts/melange-build.sh) and runs: PS_VERSION=<ver>-<rel> bash tests/smoke.sh
#
# Env:
#   PS_VERSION   required, e.g. 9.7.2-2 (must appear in `mysqld --version`)
#   PLUGIN_DIR   default /usr/lib64/mysql/plugin (RPM path; resolves through Wolfi's /usr/lib64 -> lib)
#   MTR_TESTS    default "main.1st main.mysqldump rocksdb.rocksdb"; empty string skips MTR
#   SKIP_MTR     set to 1 to skip MTR (quick local runs)
set -euo pipefail

PS_VERSION=${PS_VERSION:?PS_VERSION (e.g. 9.7.2-2) must be set}
PLUGIN_DIR=${PLUGIN_DIR:-/usr/lib64/mysql/plugin}
MTR_TESTS=${MTR_TESTS-main.1st main.mysqldump rocksdb.rocksdb}
MTR_DIR=${MTR_DIR:-/usr/share/mysql-test}

step() { printf '\n=== %s\n' "$*"; }
fail() {
  printf 'SMOKE FAIL: %s\n' "$*" >&2
  exit 1
}

# mysqld refuses to run as root without --user=root, and warns about --user when not root.
as_user=()
if [[ $(id -u) == 0 ]]; then as_user=(--user=root); fi

work=$(mktemp -d)
sock=$work/mysql.sock
pid=
cleanup() {
  local rc=$?
  if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  if ((rc != 0)) && [[ -f $work/error.log ]]; then
    echo "--- last 60 lines of mysqld error log ---" >&2
    tail -n 60 "$work/error.log" >&2 || true
  fi
  rm -rf "$work"
  exit "$rc"
}
trap cleanup EXIT

# sql <statements>: run as root over the socket; tab-separated, no column names.
sql() { mysql --no-defaults --user=root --socket="$sock" --batch --skip-column-names -e "$1"; }

expect() {
  local want=$1 got=$2 what=$3
  [[ $got == "$want" ]] || fail "$what: expected '$want', got '$got'"
  echo "ok: $what = $got"
}

step "version"
ver=$(mysqld --version)
echo "$ver"
[[ $ver == *"$PS_VERSION"* ]] || fail "mysqld --version lacks $PS_VERSION"
[[ $ver == *"Percona Server (GPL)"* ]] || fail "mysqld --version lacks 'Percona Server (GPL)'"

step "drop-in paths (RPM layout through Wolfi's merged /usr)"
for f in /usr/sbin/mysqld /usr/bin/mysqld /usr/bin/mysql /etc/my.cnf /usr/share/percona-server/english/errmsg.sys \
  /usr/share/mysql/charsets/Index.xml; do
  [[ -e $f ]] || fail "missing $f"
done
[[ -d /etc/my.cnf.d ]] || fail "missing /etc/my.cnf.d"
# compiled-in defaults must be the RPM ones (the official image's SHOW VARIABLES)
defaults=$(mysqld --no-defaults --verbose --help 2>/dev/null)
# opt <name>: value from the "Variables (--variable-name=value)" table at the end of the help output (it starts after
# the dashed separator line); option descriptions above it can wrap onto lines starting with a variable name
# (e.g. "socket creation.").
opt() { awk -v k="$1" 'table && $1 == k { print $2; exit } /^-+ +-+/ { table = 1 }' <<<"$defaults"; }
expect /usr/lib64/mysql/plugin/ "$(opt plugin-dir)" plugin-dir
expect /var/lib/mysql/mysql.sock "$(opt socket)" socket
expect /usr/share/percona-server/ "$(opt lc-messages-dir)" lc-messages-dir
expect /usr/share/percona-server/charsets/ "$(opt character-sets-dir)" character-sets-dir
expect /var/lib/mysql-files "$(opt secure-file-priv)" secure-file-priv
[[ -d /var/lib/mysql-files ]] || fail "missing /var/lib/mysql-files (the default secure-file-priv; RPM ships it)"
echo "ok: /var/lib/mysql-files exists"

step "plugins and components in $PLUGIN_DIR"
for p in auth_pam.so auth_pam_compat.so authentication_ldap_simple.so authentication_ldap_sasl.so \
  authentication_ldap_sasl_client.so authentication_kerberos_client.so authentication_webauthn_client.so \
  ha_rocksdb.so libpluginmecab.so component_keyring_vault.so component_keyring_kmip.so \
  component_percona_telemetry.so component_encryption_udf.so component_js_lang.so; do
  [[ -f $PLUGIN_DIR/$p ]] || fail "missing plugin $PLUGIN_DIR/$p"
  echo "ok: $p"
done

step "initialize and start a throwaway server"
datadir=$work/data
mkdir -p "$work/files"
mysqld --no-defaults "${as_user[@]}" --datadir="$datadir" --secure-file-priv="$work/files" \
  --log-error="$work/error.log" --initialize-insecure ||
  fail "mysqld --initialize-insecure failed"
# No mecab_rc_file override: the compiled-in default (RPM path /usr/lib64/mysql/mecab/etc/mecabrc, a symlink to
# /etc/mecabrc, or libmecab's own default) is what the image uses, so the test exercises it.
# innodb-ft-min-token-size=1: MeCab splits 日本語 into 日本 + 語, below the default minimum of 3.
mysqld --no-defaults "${as_user[@]}" --datadir="$datadir" --socket="$sock" --skip-networking --mysqlx=OFF \
  --pid-file="$work/mysqld.pid" --secure-file-priv="$work/files" --log-error="$work/error.log" \
  --innodb-ft-min-token-size=1 &
pid=$!
for _ in $(seq 1 120); do
  if mysqladmin --no-defaults --user=root --socket="$sock" ping >/dev/null 2>&1; then break; fi
  kill -0 "$pid" 2>/dev/null || fail "mysqld exited during startup"
  sleep 1
done
mysqladmin --no-defaults --user=root --socket="$sock" ping >/dev/null 2>&1 || fail "mysqld not ready after 120s"

step "SQL"
expect 1 "$(sql 'SELECT 1')" "SELECT 1"
sql "SELECT @@version, @@version_comment"
sql 'CREATE DATABASE smoke'

step "RocksDB"
sql "INSTALL PLUGIN rocksdb SONAME 'ha_rocksdb.so'"
sql 'CREATE TABLE smoke.r (id INT PRIMARY KEY, v VARCHAR(16)) ENGINE=ROCKSDB'
sql "INSERT INTO smoke.r VALUES (1, 'one'), (2, 'two')"
expect ROCKSDB "$(sql "SELECT engine FROM information_schema.tables WHERE table_schema='smoke' AND table_name='r'")" "engine of smoke.r"
expect 2 "$(sql 'SELECT COUNT(*) FROM smoke.r')" "rows in smoke.r"

step "JavaScript stored function (component_js_lang)"
sql "INSTALL COMPONENT 'file://component_js_lang'"
sql "GRANT CREATE_JS_ROUTINE ON *.* TO 'root'@'localhost'"
# shellcheck disable=SC2016 # $$ is the SQL routine-body delimiter, not shell
sql 'CREATE FUNCTION smoke.f() RETURNS INT DETERMINISTIC LANGUAGE JS AS $$ return 1+1 $$'
expect 2 "$(sql 'SELECT smoke.f()')" "JS smoke.f()"

step "full-text index WITH PARSER mecab"
sql "INSTALL PLUGIN mecab SONAME 'libpluginmecab.so'"
sql 'CREATE TABLE smoke.ft (id INT PRIMARY KEY, body TEXT, FULLTEXT KEY (body) WITH PARSER mecab) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4'
sql "INSERT INTO smoke.ft VALUES (1, '日本語のテキストです'), (2, 'English only')"
expect 1 "$(sql "SELECT COUNT(*) FROM smoke.ft WHERE MATCH(body) AGAINST('日本' IN BOOLEAN MODE)")" "mecab full-text match"

step "shutdown"
mysqladmin --no-defaults --user=root --socket="$sock" shutdown
wait "$pid" || fail "mysqld exited non-zero on shutdown"
pid=

if [[ ${SKIP_MTR:-0} == 1 || -z $MTR_TESTS ]]; then
  echo "MTR skipped"
else
  step "MTR: $MTR_TESTS"
  cd "$MTR_DIR"
  mtr_user=()
  if ((${#as_user[@]})); then mtr_user=(--mysqld=--user=root); fi
  # shellcheck disable=SC2086 # MTR_TESTS is a space-separated test list
  perl ./mysql-test-run.pl --force --max-test-fail=0 --retry=0 --parallel=1 --vardir="$work/mtr" \
    "${mtr_user[@]}" $MTR_TESTS || fail "MTR reported failures"
fi

echo
echo "SMOKE PASS"
