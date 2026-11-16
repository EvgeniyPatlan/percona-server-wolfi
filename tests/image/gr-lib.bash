#!/usr/bin/env bash
# Group replication helpers for tests/image/mysqlsh.bats. Sourced with `load gr-lib` after `load helpers`.
# Pure functions (no docker), unit-tested in tests/unit/gr-lib.bats.

# rand_secret [n=24]: n random hex characters (credentials are generated at test time, never committed).
rand_secret() {
  local n=${1:-24} s
  s=$(head -c "$n" /dev/urandom | od -An -tx1 | tr -d ' \n')
  printf '%s\n' "${s:0:n}"
}

# gr_mysqld_args <server-id> <report-host>: mysqld options (one per line) for a group replication member.
# Minimal correct set (the operator's exact flags were not confirmed): GTIDs on and enforced, row binary log with
# replica updates, a unique server id, report_host so the members find each other by name, and the plugin loaded.
# dba.configureInstance() persists the group_replication_* settings itself.
gr_mysqld_args() {
  printf '%s\n' \
    "--server-id=$1" \
    "--report-host=$2" \
    --gtid-mode=ON \
    --enforce-gtid-consistency=ON \
    --log-bin=binlog \
    --log-replica-updates=ON \
    --binlog-format=ROW \
    --relay-log=relay-bin \
    --plugin-load-add=group_replication.so
}

# gr_online_js: JavaScript (mysqlsh --js) that prints ONLINE_COUNT=<n> for the cluster connected to by `dba.getCluster()`.
gr_online_js() {
  printf '%s' "var t = dba.getCluster().status().defaultReplicaSet.topology; print('ONLINE_COUNT=' + Object.keys(t).filter(function (k) { return t[k].status == 'ONLINE'; }).length + '\\n');"
}

# gr_online_count <mysqlsh-output on stdin>: the number after the last ONLINE_COUNT=; fails when absent.
gr_online_count() {
  local line n=
  while IFS= read -r line; do
    [[ $line =~ ONLINE_COUNT=([0-9]+) ]] && n=${BASH_REMATCH[1]}
  done
  [[ -n $n ]] || return 1
  printf '%s\n' "$n"
}
