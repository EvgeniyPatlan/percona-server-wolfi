#!/usr/bin/env bash
# smoke.sh: melange `test:` for the percona-xtradb-cluster package.
# Runs inside the melange test container (normally as root) with percona-xtradb-cluster-server, -client, -galera,
# -garbd, -test, -scripts and perl installed. The recipe copies this file in through the staged source dir
# (scripts/melange-build.sh) and runs it with the env below.
#
# Env (all required):
#   PXC_VERSION        e.g. 9.7.2-2.1 (must appear in `mysqld --version`)
#   PXC_WSREP_VERSION  e.g. 26.1.4.3 (in version_comment)
#   GALERA_VERSION     e.g. 4.27 (wsrep_provider_version, garbd --version)
#   GALERA_REVISION    e.g. 13ff9ed
set -euo pipefail

PXC_VERSION=${PXC_VERSION:?PXC_VERSION (e.g. 9.7.2-2.1) must be set}
PXC_WSREP_VERSION=${PXC_WSREP_VERSION:?PXC_WSREP_VERSION must be set}
GALERA_VERSION=${GALERA_VERSION:?GALERA_VERSION must be set}
GALERA_REVISION=${GALERA_REVISION:?GALERA_REVISION must be set}
PROVIDER=/usr/lib64/galera4/libgalera_smm.so

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
    echo "--- last 80 lines of mysqld error log ---" >&2
    tail -n 80 "$work/error.log" >&2 || true
  fi
  rm -rf "$work"
  exit "$rc"
}
trap cleanup EXIT

sql() { mysql --no-defaults --user=root --socket="$sock" --batch --skip-column-names -e "$1"; }
status() { sql "SELECT variable_value FROM performance_schema.global_status WHERE variable_name='$1'"; }

step "versions"
ver=$(mysqld --version)
echo "$ver"
[[ $ver == *"$PXC_VERSION"* ]] || fail "mysqld --version lacks $PXC_VERSION"
gv=$(garbd --version 2>&1)
echo "$gv"
[[ $gv == *"$GALERA_VERSION"* ]] || fail "garbd --version lacks $GALERA_VERSION"
[[ $gv == *"$GALERA_REVISION"* ]] || fail "garbd --version lacks revision $GALERA_REVISION"

step "drop-in paths (RPM layout through Wolfi's merged /usr)"
for f in /usr/sbin/mysqld /usr/bin/mysql /etc/my.cnf /usr/share/percona-xtradb-cluster/english/errmsg.sys \
  /usr/share/mysql/charsets/Index.xml "$PROVIDER" /usr/lib64/libgalera_smm.so /usr/lib64/mysql/libgalera_smm.so \
  /usr/bin/wsrep_sst_xtrabackup-v2 /usr/bin/wsrep_sst_common /usr/bin/clustercheck /etc/sysconfig/garb \
  /usr/share/doc/percona-xtradb-cluster-galera/COPYING /usr/share/doc/percona-xtradb-cluster-garbd-3/COPYING; do
  [[ -e $f ]] || fail "missing $f"
done
echo "ok: RPM paths present"
grep -qx 'wsrep_provider=/usr/lib64/galera4/libgalera_smm.so' /etc/my.cnf || fail "/etc/my.cnf is not the RPM file"

step "SST tools: pxc_extra/pxb-9.7 resolves to this repository's XtraBackup"
x=/usr/bin/pxc_extra/pxb-9.7
[[ -x $x/bin/xtrabackup && -x $x/bin/xbstream ]] || fail "$x/bin/{xtrabackup,xbstream} missing"
[[ -d $x/lib/plugin ]] || fail "$x/lib/plugin missing"
"$x/bin/xtrabackup" --version 2>&1 | grep -q 'version 9\.7\.' || fail "$x/bin/xtrabackup is not a 9.7 xtrabackup"
command -v socat > /dev/null || fail "socat missing (SST streamer)"
echo "ok: $x"

step "libraries resolve"
for f in /usr/bin/mysqld /usr/bin/garbd "$PROVIDER" /usr/bin/mysql; do
  if ldd "$f" | grep 'not found'; then fail "$f: unresolved library"; fi
done
echo "ok: ldd"
# the official image's perl/python-free server: no shipped server file needs an interpreter other than sh/bash
# (wsrep_sst_common is a library the wsrep_sst_* scripts source: no #! line, nothing to check)
for f in /usr/bin/wsrep_sst_xtrabackup-v2 /usr/bin/wsrep_sst_common /usr/bin/clustercheck; do
  [[ $(head -c 2 "$f") == '#!' ]] || continue
  head -n1 "$f" | grep -Eq '^#! ?/(usr/)?bin/(env )?(ba)?sh' || fail "$f: unexpected interpreter $(head -n1 "$f")"
done

step "single-node cluster: bootstrap with the Galera provider"
mysqld --no-defaults "${as_user[@]}" --datadir="$work/data" --initialize-insecure \
  --log-error="$work/init.log" || { cat "$work/init.log" >&2; fail "initialize failed"; }
mysqld --no-defaults "${as_user[@]}" --datadir="$work/data" --socket="$sock" \
  --bind-address=127.0.0.1 --port=33306 --mysqlx=OFF --log-error="$work/error.log" --pid-file="$work/mysqld.pid" \
  --wsrep-provider="$PROVIDER" --wsrep-cluster-address=gcomm:// --wsrep-cluster-name=smoke \
  --wsrep-node-address=127.0.0.1 --wsrep-provider-options="gmcast.listen_addr=tcp://127.0.0.1:34567" \
  --binlog-format=ROW --innodb-autoinc-lock-mode=2 --pxc-strict-mode=ENFORCING &
pid=$!
for _ in $(seq 1 120); do
  st=$(status wsrep_local_state_comment 2> /dev/null || true)
  [[ $st == Synced ]] && break
  kill -0 "$pid" 2> /dev/null || fail "mysqld exited"
  sleep 1
done
expect Synced "$(status wsrep_local_state_comment)" wsrep_local_state_comment
expect 1 "$(status wsrep_cluster_size)" wsrep_cluster_size
expect ON "$(status wsrep_ready)" wsrep_ready
expect Primary "$(status wsrep_cluster_status)" wsrep_cluster_status
pv=$(status wsrep_provider_version)
[[ $pv == "$GALERA_VERSION"* ]] || fail "wsrep_provider_version '$pv' does not start with $GALERA_VERSION"
echo "ok: wsrep_provider_version = $pv"
vc=$(sql 'SELECT @@version_comment')
[[ $vc == *"WSREP version $PXC_WSREP_VERSION"* ]] || fail "version_comment '$vc' lacks WSREP version $PXC_WSREP_VERSION"
echo "ok: version_comment = $vc"
sql 'CREATE DATABASE s; CREATE TABLE s.t (id INT PRIMARY KEY, v VARCHAR(10)); INSERT INTO s.t VALUES (1, "a")'
expect 1 "$(sql 'SELECT COUNT(*) FROM s.t')" "row count after insert"
# tables without a primary key are refused: PXC 9.7 already at CREATE (sql_require_primary_key), otherwise
# pxc_strict_mode=ENFORCING at the first DML
if sql 'CREATE TABLE s.nopk (v INT)' 2> /dev/null; then
  if sql 'INSERT INTO s.nopk VALUES (1)' 2> /dev/null; then fail "a table without a PK accepted DML"; fi
  echo "ok: pxc_strict_mode refuses DML on a table without a PK"
else
  echo "ok: a table without a PK is refused at CREATE (sql_require_primary_key)"
fi
mysqladmin --no-defaults --user=root --socket="$sock" shutdown
wait "$pid" || true
pid=
grep -q 'safe_to_bootstrap: 1' "$work/data/grastate.dat" || fail "grastate.dat not safe_to_bootstrap after a clean shutdown"
echo "ok: clean shutdown, grastate.dat safe_to_bootstrap: 1"

step "smoke passed"
