#!/usr/bin/env bats
# ProxySQL image, the way the official percona/proxysql3 is used by the PXC operator: /entrypoint.sh edits the shipped
# /etc/proxysql/proxysql.cnf and /etc/proxysql-admin.cnf from the environment and execs
# `proxysql -f -c /etc/proxysql/proxysql.cnf --reload`; the admin interface listens on 6032, clients on 3306 and
# 33062 (the entrypoint's MYSQL_INTERFACES; upstream's default 6033 is not used by this image). Backends are added
# through the admin interface with the mysql client, as the operator's add_*_nodes.sh and proxysql-admin do.
#
# Environment: IMAGE (the -dev server image, for the backend), PROXYSQL_IMAGE (default
# localhost:5000/percona-proxysql3:3.0). Docker only, no network access.

setup_file() {
  load helpers
  # shellcheck disable=SC2153 # PS_IMAGE comes from helpers.bash
  ps_pull_images "$PS_IMAGE" "${PROXYSQL_IMAGE:-localhost:5000/percona-proxysql3:3.0}"
}

setup() {
  load helpers
  ps_require_dev
  unset PS_SQL_USER
  export PS_SQL_PASSWORD=x
  PROXYSQL_IMAGE=${PROXYSQL_IMAGE:-localhost:5000/percona-proxysql3:3.0}
  VERSION_FILE=${VERSION_FILE:-$PS_ROOT/versions/9.7.yaml}
}

teardown() {
  ps_cleanup
}

# px_run [docker-run-args...] -- [cmd...]: docker run --rm of the proxysql image; prints both streams
px_run() {
  local -a dargs=()
  while (($#)) && [[ $1 != -- ]]; do dargs+=("$1"); shift; done
  if (($#)); then shift; fi
  ps_docker run --rm "${dargs[@]}" "$PROXYSQL_IMAGE" "$@" 2>&1
}

# px_start <name> [docker-run-args...]: start the image with its default entrypoint and command; prints the name
px_start() {
  local name
  name=$(ps_prefix)-$1
  shift
  ps_track containers "$name"
  ps_docker run -d --name "$name" "$@" "$PROXYSQL_IMAGE" > /dev/null || return 1
  printf '%s\n' "$name"
}

# px_admin <container> <sql> [user] [password]: SQL on the admin interface (6032) from inside the container, as the
# operator's scripts do (the admin user may only connect locally)
px_admin() {
  ps_docker exec -e "MYSQL_PWD=${4:-admin}" "$1" mysql -h127.0.0.1 -P6032 "-u${3:-admin}" -N -B -e "$2" 2> /dev/null
}

# px_wait <container> [user] [password]: wait until the admin interface answers
px_wait() {
  local _
  for _ in $(seq 1 60); do
    if [[ $(px_admin "$1" 'SELECT 1' "${2:-admin}" "${3:-admin}") == 1 ]]; then return 0; fi
    if [[ $(ps_docker inspect -f '{{.State.Running}}' "$1" 2> /dev/null) != true ]]; then break; fi
    sleep 1
  done
  echo "proxysql $1 did not come up:" >&2
  ps_logs "$1" | tail -n 20 >&2
  return 1
}

@test "proxysql: versions, the admin tools and their helpers, uid 1001" {
  pv=$(vars_get "$VERSION_FILE" proxysql_version)
  run px_run -- proxysql --version
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"ProxySQL version $pv"* ]]
  pat=$(vars_get "$VERSION_FILE" pat_version)
  run px_run --entrypoint proxysql-admin -- --version
  [[ $output == *"proxysql-admin version $pat"* ]]
  run px_run --entrypoint percona-scheduler-admin -- --version
  [[ $output == *"percona-scheduler-admin Version: $pat"* ]]
  run px_run --entrypoint pxc_scheduler_handler -- --version
  [[ $output == *"PXC Scheduler Handler Version:  $pat"* ]]
  ps=$(vars_get "$VERSION_FILE" ps_version)
  run px_run --entrypoint mysql -- --version
  [[ $output == *"Ver $ps"* ]]
  run px_run --entrypoint my_print_defaults -- --version
  [[ $output == *"Ver $ps"* ]]
  # what entrypoint.sh, add_*_nodes.sh and proxysql-admin call
  run px_run --entrypoint bash -- -c 'command -v sed hostname timeout jq getopt column openssl curl add_pxc_nodes.sh add_proxysql_nodes.sh proxysql-status'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<< "$output")" -eq 11 ]
  run px_run --entrypoint id -- -u
  [ "$output" = 1001 ]
}

@test "proxysql: starts offline with the shipped configuration; the admin interface on 6032 answers" {
  px=$(px_start offline --network none -e PROXY_ADMIN_PASSWORD=s3cr.t -e MONITOR_PASSWORD=mon)
  px_wait "$px" admin s3cr.t
  v=$(px_admin "$px" 'SELECT version()' admin s3cr.t)
  echo "version: $v"
  [[ $v == "$(vars_get "$VERSION_FILE" proxysql_version)"* ]]
  # the entrypoint's edits, as loaded from the configuration file (--reload)
  ifaces=$(px_admin "$px" "SELECT variable_value FROM runtime_global_variables WHERE variable_name='mysql-interfaces'" admin s3cr.t)
  [ "$ifaces" = '0.0.0.0:3306;0.0.0.0:33062' ]
  mon=$(px_admin "$px" "SELECT variable_value FROM global_variables WHERE variable_name='mysql-monitor_password'" admin s3cr.t)
  [ "$mon" = mon ]
  # the default password no longer works
  run px_admin "$px" 'SELECT 1'
  [ "$status" -ne 0 ]
  # proxysql-admin.cnf carries the same credentials for the admin tools
  run ps_docker exec "$px" grep -c -e "PROXYSQL_PASSWORD='s3cr.t'" -e "WRITERS_ARE_READERS='yes'" /etc/proxysql-admin.cnf
  [ "$output" = 2 ]
  # the datadir is the writable /var/lib/proxysql
  ps_docker exec "$px" test -s /var/lib/proxysql/proxysql.db
  [ "$(ps_docker inspect -f '{{.State.Running}}' "$px")" = true ]
}

@test "proxysql: a backend from the -dev server image, added on 6032, is queried through 3306 and 33062" {
  net=$(ps_network px)
  db=$(ps_start db --network "$net" -e MYSQL_ROOT_PASSWORD=x)
  ps_wait_ready "$db" 180
  # the backend is addressed by its container name; @@hostname is what a query through ProxySQL must return
  dbname=$(ps_prefix)-db
  dbhost=$(ps_sql "$db" 'SELECT @@hostname')
  ps_sql "$db" "CREATE USER app@'%' IDENTIFIED BY 'apppw'; GRANT ALL ON *.* TO app@'%'; CREATE USER monitor@'%' IDENTIFIED BY 'monitor'; GRANT USAGE, REPLICATION CLIENT ON *.* TO monitor@'%'"
  px=$(px_start proxy --network "$net")
  px_wait "$px"
  # caching_sha2_password backend accounts: ProxySQL talks TLS to the server (use_ssl=1)
  px_admin "$px" "INSERT INTO mysql_servers (hostgroup_id, hostname, port, use_ssl) VALUES (0, '$dbname', 3306, 1);
    INSERT INTO mysql_users (username, password, default_hostgroup) VALUES ('app', 'apppw', 0);
    LOAD MYSQL SERVERS TO RUNTIME; LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK; SAVE MYSQL USERS TO DISK"
  [ "$(px_admin "$px" 'SELECT status FROM runtime_mysql_servers')" = ONLINE ]

  got=
  for _ in $(seq 1 30); do
    got=$(ps_docker exec -e MYSQL_PWD=apppw "$db" mysql -h"$px" -P3306 -uapp -N -B -e 'SELECT @@hostname' 2> /dev/null) && [[ -n $got ]] && break
    sleep 1
  done
  echo "through 3306: $got (backend $dbhost)"
  [ "$got" = "$dbhost" ]
  ps_docker exec -e MYSQL_PWD=apppw "$db" mysql -h"$px" -P33062 -uapp -e \
    'CREATE DATABASE pt; CREATE TABLE pt.t (id INT PRIMARY KEY); INSERT INTO pt.t VALUES (1),(2),(3)'
  [ "$(ps_sql "$db" 'SELECT COUNT(*) FROM pt.t')" = 3 ]
  n=$(ps_docker exec -e MYSQL_PWD=apppw "$db" mysql -h"$px" -P3306 -uapp -N -B -e 'SELECT SUM(id) FROM pt.t' 2> /dev/null)
  [ "$n" = 6 ]
  # ProxySQL counted the queries it routed to the backend
  q=$(px_admin "$px" 'SELECT SUM(Queries) FROM stats_mysql_connection_pool')
  echo "queries routed: $q"
  ((q >= 3))
}
