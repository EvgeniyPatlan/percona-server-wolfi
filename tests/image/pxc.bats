#!/usr/bin/env bats
# Percona XtraDB Cluster images, the way the official percona/percona-xtradb-cluster:9.7 is used with docker: the
# entrypoint bootstraps the first node (MYSQL_ROOT_PASSWORD, CLUSTER_NAME), the others join it (CLUSTER_JOIN) and get
# their data by SST (xtrabackup-v2 through socat); garbd (the backup image, as the PXC operator runs it) joins as an
# arbitrator. Also: garbd in the XtraBackup image.
#
# Environment: PXC_IMAGE (default localhost:5000/percona-xtradb-cluster:9.7), PXC_BACKUP_IMAGE (default
# localhost:5000/percona-xtradb-cluster-backup:9.7), PXB_IMAGE (default localhost:5000/percona-xtrabackup:9.7).
# Docker only, no network access: the nodes talk on a private docker network. Cluster traffic encryption is off
# (pxc-encrypt-cluster-traffic=OFF): every node would otherwise need the same CA, which the official image's README
# also hands in from outside.

setup_file() {
  load helpers
  ps_pull_images "${PXC_IMAGE:-localhost:5000/percona-xtradb-cluster:9.7}" \
    "${PXC_BACKUP_IMAGE:-localhost:5000/percona-xtradb-cluster-backup:9.7}" \
    "${PXB_IMAGE:-localhost:5000/percona-xtrabackup:9.7}"
}

setup() {
  load helpers
  PXC_IMAGE=${PXC_IMAGE:-localhost:5000/percona-xtradb-cluster:9.7}
  PXC_BACKUP_IMAGE=${PXC_BACKUP_IMAGE:-localhost:5000/percona-xtradb-cluster-backup:9.7}
  PXB_IMAGE=${PXB_IMAGE:-localhost:5000/percona-xtrabackup:9.7}
  VERSION_FILE=${VERSION_FILE:-$PS_ROOT/versions/9.7.yaml}
  PXC_FULL=$(vars_get "$VERSION_FILE" pxc_version)-$(vars_get "$VERSION_FILE" pxc_release).$(vars_get "$VERSION_FILE" pxc_rpm_release)
  GALERA_VERSION=$(vars_get "$VERSION_FILE" galera_version)
}

teardown() {
  ps_cleanup
}

# img_run <image> [docker-run-args...] -- [cmd...]: docker run --rm; prints both streams
img_run() {
  local img=$1
  shift
  local -a dargs=()
  while (($#)) && [[ $1 != -- ]]; do dargs+=("$1"); shift; done
  if (($#)); then shift; fi
  ps_docker run --rm "${dargs[@]}" "$img" "$@" 2>&1
}

# pxc_node <name> <network> [env...]: start a node of $PXC_IMAGE (container name = host name = <prefix>-<name>, so
# the other nodes reach it by name); prints the full name. Telemetry off (no network in tests).
pxc_node() {
  local name=$1 net=$2 full
  shift 2
  local -a envs=()
  for e in "$@"; do envs+=(-e "$e"); done
  full=$(ps_prefix)-$name
  ps_track containers "$full"
  ps_docker run -d --name "$full" --hostname "$full" --network "$net" -e PERCONA_TELEMETRY_DISABLE=1 \
    -e MYSQL_ROOT_PASSWORD=x "${envs[@]}" "$PXC_IMAGE" --pxc-encrypt-cluster-traffic=OFF > /dev/null || return 1
  printf '%s\n' "$full"
}

# pxc_sql <container> <sql>: as root over the socket of /etc/mysql/node.cnf ([client] socket=/tmp/mysql.sock)
pxc_sql() { ps_docker exec -e MYSQL_PWD=x "$1" mysql -uroot -N -B -e "$2" 2> /dev/null; }

# pxc_status <container> <variable>
pxc_status() {
  pxc_sql "$1" "SELECT variable_value FROM performance_schema.global_status WHERE variable_name='$2'"
}

# pxc_wait_synced <container> [timeout=300]: wsrep_local_state_comment = Synced (fails at once if the container exits)
pxc_wait_synced() {
  local c=$1 timeout=${2:-300} deadline st
  deadline=$((SECONDS + timeout))
  while :; do
    if [[ $(ps_docker inspect -f '{{.State.Running}}' "$c" 2> /dev/null) != true ]]; then
      echo "pxc_wait_synced: $c is not running" >&2
      ps_logs "$c" | tail -n 60 >&2
      return 1
    fi
    st=$(pxc_status "$c" wsrep_local_state_comment || true)
    [[ $st == Synced ]] && return 0
    if ((SECONDS >= deadline)); then
      echo "pxc_wait_synced: $c is '$st' after ${timeout}s" >&2
      ps_logs "$c" | tail -n 60 >&2
      return 1
    fi
    sleep 2
  done
}

# wait_value <want> <timeout> <cmd...>: poll until the command prints <want>
wait_value() {
  local want=$1 timeout=$2 got deadline
  shift 2
  deadline=$((SECONDS + timeout))
  while :; do
    got=$("$@" || true)
    [[ $got == "$want" ]] && return 0
    if ((SECONDS >= deadline)); then
      echo "wait_value: '$*' is '$got', expected '$want' after ${timeout}s" >&2
      return 1
    fi
    sleep 1
  done
}

@test "pxc: versions, user, Galera provider, SST tools and the operator's tools" {
  run img_run "$PXC_IMAGE" --entrypoint mysqld -- --version
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"$PXC_FULL"* ]]
  run img_run "$PXC_IMAGE" --entrypoint id -- -u
  [ "$output" = 1001 ]
  # shellcheck disable=SC2016 # expanded in the container
  run img_run "$PXC_IMAGE" --entrypoint bash -- -c 'echo "$PXC_VERSION $OS_VER"'
  [ "$output" = "$PXC_FULL wolfi" ]
  # node.cnf's provider path, the SST script, XtraBackup as wsrep_sst_xtrabackup-v2 looks it up, its streamers, the
  # tools of the entrypoint and of the operator (Dockerfile.k8s: iproute), the allocator preload targets
  # shellcheck disable=SC2016 # expanded in the container
  run img_run "$PXC_IMAGE" --entrypoint bash -- -ec '
    test -f /usr/lib64/galera4/libgalera_smm.so
    test -x /usr/bin/wsrep_sst_xtrabackup-v2
    /usr/bin/pxc_extra/pxb-9.7/bin/xtrabackup --version
    test -d /usr/bin/pxc_extra/pxb-9.7/lib/plugin
    command -v socat xbstream pv nc ip jq curl hostname diff mysql_tzinfo_to_sql clustercheck.sh configure-pxc.sh peer-list || true
    test -e /usr/lib64/libjemalloc.so.2
    test -e /usr/lib64/libtcmalloc.so
    test "$(readlink /etc/my.cnf.d)" = /etc/mysql/conf.d
    test -w /etc/mysql/node.cnf'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"xtrabackup version 9.7."* ]]
  for t in socat xbstream pv nc ip jq curl hostname diff mysql_tzinfo_to_sql clustercheck.sh configure-pxc.sh; do
    grep -q "/$t\$" <<< "$output" || { echo "missing: $t"; false; }
  done
}

@test "pxc: the entrypoint refuses an uninitialized datadir without a password option" {
  run img_run "$PXC_IMAGE" -e PERCONA_TELEMETRY_DISABLE=1 --
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"password option is not specified"* ]]
}

@test "pxc: single node bootstrap through the entrypoint" {
  net=$(ps_network pxc1)
  n1=$(pxc_node n1 "$net" CLUSTER_NAME=one)
  pxc_wait_synced "$n1"
  [ "$(pxc_status "$n1" wsrep_cluster_size)" = 1 ]
  [ "$(pxc_status "$n1" wsrep_cluster_status)" = Primary ]
  [ "$(pxc_sql "$n1" 'SELECT @@wsrep_cluster_name')" = one ]
  pv=$(pxc_status "$n1" wsrep_provider_version)
  echo "provider: $pv"
  [[ $pv == "$GALERA_VERSION"* ]]
  # users the entrypoint creates (as the official one): root@%, xtrabackup, monitor, clustercheck
  users=$(pxc_sql "$n1" "SELECT CONCAT(user, '@', host) FROM mysql.user ORDER BY 1" | tr '\n' ' ')
  echo "users: $users"
  for u in root@% root@localhost xtrabackup@localhost monitor@localhost clustercheck@localhost; do
    [[ " $users " == *" $u "* ]]
  done
  # wsrep_node_address comes from `hostname -i` (patched from -I): the container's address on the network
  ip=$(ps_docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$n1")
  [ "$(pxc_sql "$n1" 'SELECT @@wsrep_node_address')" = "$ip" ]
}

@test "pxc: three nodes (SST by xtrabackup), a write replicated to all, garbd joins as arbitrator" {
  net=$(ps_network pxc3)
  n1=$(pxc_node n1 "$net" CLUSTER_NAME=c3)
  pxc_wait_synced "$n1"
  n2=$(pxc_node n2 "$net" CLUSTER_NAME=c3 "CLUSTER_JOIN=$n1")
  pxc_wait_synced "$n2"
  n3=$(pxc_node n3 "$net" CLUSTER_NAME=c3 "CLUSTER_JOIN=$n1,$n2")
  pxc_wait_synced "$n3"
  for n in "$n1" "$n2" "$n3"; do
    [ "$(pxc_status "$n" wsrep_cluster_size)" = 3 ]
  done
  # the joiners got their data by SST with xtrabackup-v2 (not IST: they had no data)
  for n in "$n2" "$n3"; do
    logs=$(ps_logs "$n")
    grep -q 'wsrep_sst_xtrabackup-v2' <<< "$logs"
    if grep -qi 'xtrabackup.*\(failed\|error:\)' <<< "$logs"; then echo "$logs" | grep -i xtrabackup | tail -n 20; false; fi
  done
  # root@% exists on the joiners: it came with the donor's data
  [ "$(pxc_sql "$n3" "SELECT COUNT(*) FROM mysql.user WHERE user='root' AND host='%'")" = 1 ]

  # a write on one node is on every node; writes on two nodes (multi-primary) are on all three
  pxc_sql "$n1" 'CREATE DATABASE r; CREATE TABLE r.t (id INT PRIMARY KEY, v VARCHAR(20)); INSERT INTO r.t VALUES (1, "n1")'
  pxc_sql "$n3" 'INSERT INTO r.t VALUES (3, "n3")'
  for n in "$n1" "$n2" "$n3"; do
    wait_value "1:n1 3:n3" 30 pxc_sql "$n" "SELECT GROUP_CONCAT(id, ':', v ORDER BY id SEPARATOR ' ') FROM r.t"
  done
  [ "$(pxc_sql "$n2" 'SELECT @@wsrep_cluster_name')" = c3 ]

  # garbd from the backup image (as the operator's backup job starts it, without the SST request): the cluster
  # counts it as a member, and it leaves cleanly
  g=$(ps_prefix)-garbd
  ps_track containers "$g"
  ps_docker run -d --name "$g" --hostname "$g" --network "$net" "$PXC_BACKUP_IMAGE" \
    garbd --address "gcomm://$n1,$n2?gmcast.listen_addr=tcp://0.0.0.0:4567" --group c3 --options 'pc.weight=0' > /dev/null
  wait_value 4 60 pxc_status "$n2" wsrep_cluster_size
  ps_logs "$g" | grep -E 'Shifting|SYNCED|JOINED|member' | tail -n 5 || true
  ps_docker stop -t 20 "$g" > /dev/null
  wait_value 3 60 pxc_status "$n1" wsrep_cluster_size
  # the cluster still takes writes after the arbitrator left
  pxc_sql "$n2" 'INSERT INTO r.t VALUES (2, "n2")'
  wait_value 3 30 pxc_sql "$n1" 'SELECT COUNT(*) FROM r.t'
}

@test "pxc backup image: garbd, xtrabackup, client and the backup scripts" {
  # shellcheck disable=SC2016 # expanded in the container
  run img_run "$PXC_BACKUP_IMAGE" -- bash -ec '
    garbd --version
    xtrabackup --version
    mysql --version
    for f in backup.sh run_backup.sh recovery-cloud.sh recovery-pvc-donor.sh recovery-pvc-joiner.sh get-pxc-state; do
      test -x /usr/bin/$f
    done
    for f in backup.sh vault.sh aws.sh check-version.sh; do test -f /usr/lib/pxc/$f; done
    test -d /backup -a -w /backup
    command -v socat aws jq curl ps xbcloud xbstream
    id -u'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"$GALERA_VERSION"* ]]
  [[ $output == *"xtrabackup version 9.7."* ]]
  [ "$(tail -n1 <<< "$output")" = 1001 ]
}

@test "xtrabackup image: garbd is installed" {
  run img_run "$PXB_IMAGE" --entrypoint garbd -- --version
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"$GALERA_VERSION"* ]]
}
