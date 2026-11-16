#!/usr/bin/env bash
# Group replication helpers for tests/image/mysqlsh.bats and tests/image/router.bats. Sourced with `load gr-lib` after
# `load helpers`. The pure functions are unit-tested in tests/unit/gr-lib.bats; the docker ones at the bottom use the
# helpers' ps_* functions and $PS_IMAGE (the -dev image: mysqlsh is needed).

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

# ---- docker helpers ----

# sh_js <container> <host> <js>: run JavaScript in mysqlsh inside <container>, connected to root@<host>.
# HOME of uid 1001 does not exist, so the shell's config directory goes to /tmp.
sh_js() {
  ps_docker exec -e MYSQLSH_USER_CONFIG_HOME=/tmp "$1" \
    mysqlsh --js --no-wizard --uri "root:x@$2:3306" -e "$3"
}

# gr_member <net> <n>: start group replication member <n> (ready, root@% with password x); prints the container id
gr_member() {
  local name=n$2 full cid
  full=$(ps_prefix)-$name
  local -a args
  mapfile -t args < <(gr_mysqld_args "$2" "$full")
  cid=$(ps_start "$name" --network "$1" --hostname "$full" -e MYSQL_ROOT_PASSWORD=x -e 'MYSQL_ROOT_HOST=%' -- "${args[@]}") || return 1
  ps_wait_ready "$cid" 180 || return 1
  printf '%s\n' "$cid"
}

# gr_cluster <net>: a three-member InnoDB Cluster 'c' on <net>, all members ONLINE: dba.configureInstance on each,
# RESET BINARY LOGS AND GTIDS (entrypoint init leaves local GTIDs that incremental recovery would see as errant),
# createCluster on n1, addInstance n2 and n3 (incremental). Sets the arrays GR_CIDS and GR_HOSTS (n1 = primary).
gr_cluster() {
  local net=$1 i h c cid n=0
  GR_CIDS=() GR_HOSTS=()
  for i in 1 2 3; do
    cid=$(gr_member "$net" "$i") || return 1
    GR_CIDS+=("$cid")
    GR_HOSTS+=("$(ps_prefix)-n$i")
  done
  for h in "${GR_HOSTS[@]}"; do
    sh_js "${GR_CIDS[0]}" "$h" "dba.configureInstance('root:x@$h:3306', {restart: false})" > /dev/null || return 1
  done
  for c in "${GR_CIDS[@]}"; do ps_sql "$c" 'RESET BINARY LOGS AND GTIDS' || return 1; done
  sh_js "${GR_CIDS[0]}" "${GR_HOSTS[0]}" "dba.createCluster('c', {gtidSetIsComplete: true})" > /dev/null || return 1
  for h in "${GR_HOSTS[@]:1}"; do
    sh_js "${GR_CIDS[0]}" "${GR_HOSTS[0]}" \
      "dba.getCluster('c').addInstance('root:x@$h:3306', {recoveryMethod: 'incremental'})" > /dev/null || return 1
  done
  for _ in $(seq 1 60); do
    n=$(sh_js "${GR_CIDS[0]}" "${GR_HOSTS[0]}" "$(gr_online_js)" | gr_online_count) || n=0
    [[ $n == 3 ]] && return 0
    sleep 2
  done
  echo "gr_cluster: only $n member(s) ONLINE" >&2
  return 1
}
