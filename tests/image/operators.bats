#!/usr/bin/env bats
# Operator images, checked the way Kubernetes uses them, without Kubernetes: the manager binary starts, the helper
# binaries and scripts are at the paths of the official images (build/Dockerfile of each operator repository), the
# image user is uid 2, and the init container (the same image, running *-init-entrypoint.sh into the shared volumes)
# installs everything it should.
#
# Environment: PS_OPERATOR_IMAGE (default localhost:5000/percona-server-mysql-operator:<ps_operator_version>),
# PXC_OPERATOR_IMAGE (default localhost:5000/percona-xtradb-cluster-operator:<pxc_operator_version>). Docker only, no
# network access.

setup_file() {
  load helpers
  local vf=${VERSION_FILE:-$PS_ROOT/versions/9.7.yaml}
  ps_pull_images \
    "${PS_OPERATOR_IMAGE:-localhost:5000/percona-server-mysql-operator:$(vars_get "$vf" ps_operator_version)}" \
    "${PXC_OPERATOR_IMAGE:-localhost:5000/percona-xtradb-cluster-operator:$(vars_get "$vf" pxc_operator_version)}"
}

setup() {
  load helpers
  VERSION_FILE=${VERSION_FILE:-$PS_ROOT/versions/9.7.yaml}
  PS_OPERATOR_IMAGE=${PS_OPERATOR_IMAGE:-localhost:5000/percona-server-mysql-operator:$(vars_get "$VERSION_FILE" ps_operator_version)}
  PXC_OPERATOR_IMAGE=${PXC_OPERATOR_IMAGE:-localhost:5000/percona-xtradb-cluster-operator:$(vars_get "$VERSION_FILE" pxc_operator_version)}
}

teardown() {
  ps_cleanup
}

# op_run <image> [docker-run-args...] -- [cmd...]: docker run --rm; prints both streams
op_run() {
  local img=$1
  shift
  local -a dargs=()
  while (($#)) && [[ $1 != -- ]]; do dargs+=("$1"); shift; done
  if (($#)); then shift; fi
  ps_docker run --rm "${dargs[@]}" "$img" "$@" 2>&1
}

# Helper tree of the PS operator image (Dockerfile: cp -a ... /opt/percona-server-mysql-operator/)
PS_HELPER_BINS="bootstrap healthcheck sidecar failover peer-list orc-handler mysql-state-monitor clusterset-replica-manager pitr"
PS_HELPER_FILES="ps-entrypoint.sh ps-pre-stop.sh heartbeat-entrypoint.sh router-entrypoint.sh router_readiness_check.sh
  router_startup_check.sh orc-entrypoint.sh orchestrator.conf.json orc-add_mysql_nodes.sh ps-init-entrypoint.sh
  run-backup.sh run-restore.sh prepare-s3-certs.sh haproxy-entrypoint.sh haproxy_add_mysql_nodes.sh
  haproxy_check_primary.sh haproxy_check_replicas.sh haproxy_liveness_check.sh haproxy_readiness_check.sh
  haproxy_startup_check.sh haproxy.cfg haproxy-global.cfg pmm-prerun.sh binlog-server-entrypoint.sh
  run-pitr-restore.sh run-prepare-restore.sh lib/util.sh logcollector/entrypoint.sh"
# Root of the PXC operator image (Dockerfile: COPY ... /<name>)
PXC_HELPER_BINS="peer-list pitr mysql-state-monitor xtrabackup-server-sidecar xtrabackup-run-backup"
PXC_HELPER_FILES="pxc-entrypoint.sh pxc-init-entrypoint.sh pitr-init-entrypoint.sh backup-init-entrypoint.sh
  pxc-configure-pxc.sh liveness-check.sh readiness-check.sh pmm-prerun.sh get-pxc-state wsrep_cmd_notify_handler.sh
  prepare_restored_cluster.sh haproxy-entrypoint.sh haproxy-init-entrypoint.sh haproxy_add_pxc_nodes.sh
  haproxy_check_pxc.sh haproxy_liveness_check.sh haproxy_readiness_check.sh haproxy.cfg haproxy-global.cfg
  proxysql-entrypoint.sh proxysql-init-entrypoint.sh proxysql.cnf proxysql-admin.cnf proxysql_add_cluster_nodes.sh
  proxysql_add_proxysql_nodes.sh proxysql_add_pxc_nodes.sh proxysql_scheduler_config.tmpl backup/backup.sh
  backup/run_backup.sh backup/lib/pxc/backup.sh logcollector/entrypoint.sh"

@test "ps operator: manager starts, user 2, image config as the official one" {
  run op_run "$PS_OPERATOR_IMAGE" -- percona-server-mysql-operator -h
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"-metrics-bind-address"* ]]
  run op_run "$PS_OPERATOR_IMAGE" -- id -u
  [ "$output" = 2 ]
  run ps_docker image inspect -f '{{.Config.User}} {{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$PS_OPERATOR_IMAGE"
  echo "$output"
  # no entrypoint (docker shows null or an empty list), CMD of the UBI base
  [[ $output == '2 null ["/bin/bash"]' || $output == '2 [] ["/bin/bash"]' ]]
  run op_run "$PS_OPERATOR_IMAGE" -- bash -c 'command -v percona-server-mysql-operator; test -f /licenses/LICENSE'
  [ "$status" -eq 0 ]
  [ "$output" = /usr/local/bin/percona-server-mysql-operator ]
}

@test "ps operator: helper binaries and scripts at /opt/percona-server-mysql-operator, the manager stamped with the pinned commit" {
  commit=$(vars_get "$VERSION_FILE" ps_operator_commit)
  # shellcheck disable=SC2016 # expanded in the container
  run op_run "$PS_OPERATOR_IMAGE" -- bash -c '
    d=/opt/percona-server-mysql-operator
    for b in '"$PS_HELPER_BINS"'; do test -x "$d/$b" || echo "missing binary $b"; done
    for f in '"$(tr '\n' ' ' <<< "$PS_HELPER_FILES")"'; do test -f "$d/$f" || echo "missing file $f"; done
    test -d "$d/logcollector/fluentbit" || echo "missing logcollector/fluentbit"
    grep -aqF '"$commit"' /usr/local/bin/percona-server-mysql-operator || echo "manager: no commit stamp"'
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # peer-list refuses to run unless it is pid 1 (a pod's entrypoint): as the container's command it is
  run op_run "$PS_OPERATOR_IMAGE" -- /opt/percona-server-mysql-operator/peer-list -h
  [ "$status" -eq 0 ]
  [[ $output == *"-on-change"* ]]
}

@test "ps operator: the init container installs the helpers into /opt/percona" {
  run op_run "$PS_OPERATOR_IMAGE" --tmpfs /opt/percona:mode=1777 -- bash -c \
    '/opt/percona-server-mysql-operator/ps-init-entrypoint.sh > /dev/null 2>&1 || exit 9
     cd /opt/percona && find . -type f | sort; stat -c "%u %a" ps-entrypoint.sh bootstrap'
  echo "$output"
  [ "$status" -eq 0 ]
  for f in ps-entrypoint.sh bootstrap healthcheck sidecar peer-list mysql-state-monitor pitr lib/util.sh \
    haproxy-global.cfg logcollector/entrypoint.sh; do
    [[ $output == *"./$f"* ]]
  done
  [ "${lines[-2]}" = "2 755" ]
  [ "${lines[-1]}" = "2 755" ]
}

@test "pxc operator: manager starts, user 2, image config as the official one" {
  run op_run "$PXC_OPERATOR_IMAGE" -- percona-xtradb-cluster-operator -h
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"-metrics-bind-address"* ]]
  run op_run "$PXC_OPERATOR_IMAGE" -- id -u
  [ "$output" = 2 ]
  run ps_docker image inspect -f '{{.Config.User}} {{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$PXC_OPERATOR_IMAGE"
  # no entrypoint (docker shows null or an empty list), CMD of the UBI base
  [[ $output == '2 null ["/bin/bash"]' || $output == '2 [] ["/bin/bash"]' ]]
  run op_run "$PXC_OPERATOR_IMAGE" -- bash -c 'command -v percona-xtradb-cluster-operator; test -f /licenses/LICENSE; test -f /usr/share/zoneinfo/UTC'
  [ "$status" -eq 0 ]
  [ "$output" = /usr/local/bin/percona-xtradb-cluster-operator ]
}

@test "pxc operator: helper binaries and scripts at /, /backup and /logcollector, the manager stamped with the pinned commit" {
  commit=$(vars_get "$VERSION_FILE" pxc_operator_commit)
  # shellcheck disable=SC2016 # expanded in the container
  run op_run "$PXC_OPERATOR_IMAGE" -- bash -c '
    for b in '"$PXC_HELPER_BINS"'; do test -x "/$b" || echo "missing binary $b"; done
    for f in '"$(tr '\n' ' ' <<< "$PXC_HELPER_FILES")"'; do test -f "/$f" || echo "missing file $f"; done
    grep -aqF '"$commit"' /mysql-state-monitor || echo "mysql-state-monitor: no commit stamp"
    grep -aqF '"$commit"' /usr/local/bin/percona-xtradb-cluster-operator || echo "manager: no commit stamp"'
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run op_run "$PXC_OPERATOR_IMAGE" -- /peer-list -h
  [ "$status" -eq 0 ]
  [[ $output == *"-on-change"* ]]
}

@test "pxc operator: the init containers install the helpers into /var/lib/mysql and /opt/percona" {
  run op_run "$PXC_OPERATOR_IMAGE" --tmpfs /var/lib/mysql:mode=1777 --tmpfs /opt/percona:mode=1777 -- bash -c \
    '/pxc-init-entrypoint.sh > /dev/null 2>&1 || exit 9
     find /var/lib/mysql /opt/percona -type f | sort; stat -c "%u %a" /var/lib/mysql/peer-list'
  echo "$output"
  [ "$status" -eq 0 ]
  for f in pxc-entrypoint.sh peer-list xtrabackup-server-sidecar get-pxc-state mysql-state-monitor \
    wsrep_cmd_notify_handler.sh; do
    [[ $output == *"/var/lib/mysql/$f"* ]]
  done
  [[ $output == *"/opt/percona/logcollector/entrypoint.sh"* ]]
  [ "${lines[-1]}" = "2 755" ]
}
