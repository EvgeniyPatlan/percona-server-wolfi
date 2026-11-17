#!/usr/bin/env bash
# smoke.sh: melange `test:` for the percona-binlog-server package.
# Runs inside the melange test container with percona-binlog-server, percona-server-server and percona-server-client
# installed (normally as root; works unprivileged too). The recipe copies this file in through the staged source dir
# (scripts/melange-build.sh) and runs:
#   PBS_VERSION=<x.y.z> bash tests/smoke.sh
#
# Env:
#   PBS_VERSION   required, e.g. 0.4.1 (`binlog_server version` must print exactly that)
#   SKIP_SERVER   set to 1 to skip the fetch from a throwaway mysqld
set -euo pipefail

PBS_VERSION=${PBS_VERSION:?PBS_VERSION (e.g. 0.4.1) must be set}
PORT=${PORT:-3307}

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
  if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  if ((rc != 0)); then
    for f in "$work/error.log" "$work/binsrv.log" "$work/out.json"; do
      [[ -f $f ]] || continue
      echo "--- last 60 lines of $f ---" >&2
      tail -n 60 "$f" >&2 || true
    done
  fi
  rm -rf "$work"
  exit "$rc"
}
trap cleanup EXIT

sql() { mysql --no-defaults --user=root --socket="$sock" --batch --skip-column-names -e "$1"; }

# write_config <file> <storage-dir>: the configuration the Percona Operator generates (pkg/binlogserver/config.go),
# with the file backend instead of s3 and the throwaway server
write_config() {
  cat > "$1" <<EOF
{
  "logger": { "level": "info", "file": "$work/binsrv.log" },
  "connection": {
    "host": "127.0.0.1", "port": $PORT, "user": "pbs", "password": "pbs-Secret1",
    "connect_timeout": 10, "read_timeout": 10, "write_timeout": 10,
    "ssl": { "mode": "required" }
  },
  "replication": {
    "server_id": 4242, "idle_time": 1, "verify_checksum": true, "mode": "gtid",
    "rewrite": { "base_file_name": "binlog", "file_size": "128M" }
  },
  "storage": {
    "backend": "file", "uri": "file://$2",
    "checkpoint_size": "1M", "checkpoint_interval": "5s"
  }
}
EOF
}

step "version and usage"
v=$(binlog_server version)
[[ $v == "$PBS_VERSION" ]] || fail "binlog_server version printed '$v', expected '$PBS_VERSION'"
echo "ok: version $v"
if binlog_server > "$work/usage" 2>&1; then fail "binlog_server without arguments exited 0"; fi
grep -q '^usage: binlog_server (fetch|pull)' "$work/usage" || fail "no usage text: $(cat "$work/usage")"
for m in list search_by_timestamp search_by_gtid_set purge_binlogs version; do
  grep -q "binlog_server $m" "$work/usage" || fail "usage lacks the $m mode"
done
echo "ok: usage lists every operation mode"

step "shipped configuration (RPM %config /etc/percona-binlog-server/main_config.json)"
cfg=/etc/percona-binlog-server/main_config.json
[[ $(stat -c '%a %u:%g' "$cfg") == "640 0:0" ]] || fail "$cfg: mode/owner $(stat -c '%a %u:%g' "$cfg"), expected 640 0:0"
# the example config with its paths moved into the work dir, and the upstream example keyring (keyring_data.json)
mkdir -p "$work/vault" "$work/buffer"
sed -e "s#/home/user/keyring/keyring/keyring_data.json#$work/keyring.json#" -e "s#/home/user/vault#$work/vault#" \
  -e "s#/tmp/binsrv#$work/buffer#" -e "s#\"binsrv.log\"#\"$work/binsrv.log\"#" "$cfg" > "$work/main.json"
cat > "$work/keyring.json" <<'EOF'
{ "version": 1, "keys": [ { "id": "alpha", "cipher": "AES-128-ECB", "data_hex": "00112233445566778899AABBCCDDEEFF" } ] }
EOF
binlog_server list "$work/main.json" > "$work/out.json" || fail "list on the shipped config failed: $(cat "$work/out.json")"
grep -q '"status": *"success"' "$work/out.json" || fail "list: no success status: $(cat "$work/out.json")"
echo "ok: the shipped config parses (list on an empty storage succeeds)"
# a broken config is reported as an error response, not a crash
printf '{ "logger": ' > "$work/broken.json"
if binlog_server list "$work/broken.json" > "$work/out.json" 2>&1; then fail "list on a broken config exited 0"; fi
grep -q '"status": *"error"' "$work/out.json" || fail "broken config: no error response: $(cat "$work/out.json")"
echo "ok: a broken config is rejected"

if [[ ${SKIP_SERVER:-0} == 1 ]]; then
  echo "SKIP_SERVER=1: no fetch from a server"
  exit 0
fi

step "throwaway Percona Server with GTID binary logs"
datadir=$work/data
mysqld --no-defaults "${as_user[@]}" --datadir="$datadir" --log-error="$work/error.log" --initialize-insecure ||
  fail "mysqld --initialize-insecure failed"
mkdir -p "$work/files"
mysqld --no-defaults "${as_user[@]}" --datadir="$datadir" --socket="$sock" --port="$PORT" --bind-address=127.0.0.1 \
  --mysqlx=OFF --server-id=1 --log-bin=mysql-bin --gtid-mode=ON --enforce-gtid-consistency=ON \
  --pid-file="$work/mysqld.pid" --log-error="$work/error.log" --secure-file-priv="$work/files" &
pid=$!
for _ in $(seq 1 120); do
  if mysqladmin --no-defaults --user=root --socket="$sock" ping >/dev/null 2>&1; then break; fi
  kill -0 "$pid" 2>/dev/null || fail "mysqld exited during startup"
  sleep 1
done
mysqladmin --no-defaults --user=root --socket="$sock" ping >/dev/null 2>&1 || fail "mysqld not ready after 120s"
# the operator's replication user has REPLICATION SLAVE (and more); this is the minimum binlog_server documents
sql "CREATE USER 'pbs'@'%' IDENTIFIED BY 'pbs-Secret1'; GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'pbs'@'%';
  CREATE DATABASE pbs; CREATE TABLE pbs.t (id INT PRIMARY KEY, v VARCHAR(64));
  INSERT INTO pbs.t VALUES (1, 'one'), (2, 'two'); FLUSH BINARY LOGS; INSERT INTO pbs.t VALUES (3, 'three');"
uuid=$(sql 'SELECT @@server_uuid')
executed=$(sql 'SELECT @@gtid_executed' | tr -d '\n')
echo "gtid_executed: $executed"

step "binlog_server fetch -> local directory storage"
mkdir -p "$work/store"
write_config "$work/pbs.json" "$work/store"
binlog_server fetch "$work/pbs.json" > "$work/fetch.out" 2>&1 || fail "fetch failed: $(cat "$work/fetch.out")"
ls -la "$work/store"
[[ -s $work/store/binlog.000001 ]] || fail "no binlog.000001 in the storage directory"
# a binary log starts with the magic bytes fe 62 69 6e
[[ $(head -c 4 "$work/store/binlog.000001" | od -An -tx1 | tr -d ' \n') == fe62696e ]] || fail "binlog.000001 is not a binary log"
echo "ok: binlog files written"

step "list and search_by_gtid_set on the storage"
binlog_server list "$work/pbs.json" > "$work/out.json" || fail "list failed: $(cat "$work/out.json")"
cat "$work/out.json"
grep -q '"status": *"success"' "$work/out.json" || fail "list: no success status"
grep -q '"name": *"binlog.000001"' "$work/out.json" || fail "list does not show binlog.000001"
grep -q "$uuid" "$work/out.json" || fail "list shows no GTID of the source ($uuid)"
binlog_server search_by_gtid_set "$work/pbs.json" "$uuid:1-3" > "$work/out.json" ||
  fail "search_by_gtid_set failed: $(cat "$work/out.json")"
grep -q '"status": *"success"' "$work/out.json" || fail "search_by_gtid_set: no success status"
echo "ok: storage queries"

mysqladmin --no-defaults --user=root --socket="$sock" shutdown
wait "$pid" || fail "mysqld exited non-zero on shutdown"
pid=
echo
echo "SMOKE OK"
