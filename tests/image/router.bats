#!/usr/bin/env bats
# MySQL Router image, the way the official percona/percona-mysql-router:9.7 is used: the entrypoint bootstraps against
# MYSQL_HOST:MYSQL_PORT of an InnoDB Cluster and starts mysqlrouter; clients use 6446 (read-write, primary) and
# 6447 (read-only, secondaries). Also checks the tools the Percona Operator's router scripts call.
#
# Environment: IMAGE (the -dev server image, for the cluster members), ROUTER_IMAGE (default
# localhost:5000/percona-mysql-router:9.7). Docker only, no network access.

setup_file() {
  load helpers
  # shellcheck disable=SC2153 # PS_IMAGE comes from helpers.bash
  ps_pull_images "$PS_IMAGE" "${ROUTER_IMAGE:-localhost:5000/percona-mysql-router:9.7}"
}

setup() {
  load helpers
  load gr-lib
  ps_require_dev
  unset PS_SQL_USER
  export PS_SQL_PASSWORD=x
  ROUTER_IMAGE=${ROUTER_IMAGE:-localhost:5000/percona-mysql-router:9.7}
  VERSION_FILE=${VERSION_FILE:-$PS_ROOT/versions/9.7.yaml}
}

teardown() {
  ps_cleanup
}

# router_run [docker-run-args...] -- [cmd...]: docker run --rm of the router image; prints both streams
router_run() {
  local -a dargs=()
  while (($#)) && [[ $1 != -- ]]; do dargs+=("$1"); shift; done
  if (($#)); then shift; fi
  ps_docker run --rm "${dargs[@]}" "$ROUTER_IMAGE" "$@" 2>&1
}

# via <client-cid> <router-host> <port> <sql>: run SQL through the router from a cluster member's mysql client
via() {
  ps_docker exec "$1" mysql -h"$2" -P"$3" -uroot -px -N -B -e "$4" 2> /dev/null
}

@test "router: versions, and the tools the operator's router scripts call" {
  v=$(vars_get "$VERSION_FILE" ps_version)
  run router_run --entrypoint mysqlrouter -- --version
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"Ver $v"* ]]
  run router_run --entrypoint mysqlsh -e MYSQLSH_USER_CONFIG_HOME=/tmp -- --version
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"Ver $(vars_get "$VERSION_FILE" mysqlsh_tag) "* ]]
  # router-entrypoint.sh / router_*_check.sh of percona-server-mysql-operator: python3 urllib, curl, mysqlrouter_passwd
  run router_run --entrypoint python3 -- -c 'import urllib.parse; print(urllib.parse.quote("a b/c"))'
  [ "$status" -eq 0 ]
  [ "$output" = "a%20b/c" ]
  run router_run --entrypoint bash -- -c 'command -v curl mysqlrouter_passwd mysqlrouter_keyring dig openssl tar'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<< "$output")" -eq 6 ]
  run router_run --entrypoint id -- -u
  [ "$output" = 1001 ]
}

@test "router: the entrypoint refuses to start without the MYSQL_* settings" {
  run router_run
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"We require all of"* ]]
  [[ $output == *"MYSQL_PASSWORD"* ]]
}

@test "router: bootstraps against a 3-member cluster; 6446 reaches the primary, 6447 a secondary" {
  net=$(ps_network router)
  gr_cluster "$net"
  rname=$(ps_prefix)-router
  ps_track containers "$rname"
  ps_docker run -d --name "$rname" --network "$net" \
    -e MYSQL_HOST="${GR_HOSTS[0]}" -e MYSQL_PORT=3306 -e MYSQL_USER=root -e MYSQL_PASSWORD=x \
    "$ROUTER_IMAGE" > /dev/null

  rw=
  for _ in $(seq 1 60); do
    rw=$(via "${GR_CIDS[1]}" "$rname" 6446 'SELECT @@hostname, @@super_read_only') && [[ -n $rw ]] && break
    sleep 2
  done
  echo "# router logs: $(ps_docker logs "$rname" 2>&1 | tail -n 5)" >&3
  echo "RW: $rw"
  [ "$rw" = "${GR_HOSTS[0]}	0" ]
  ro=$(via "${GR_CIDS[0]}" "$rname" 6447 'SELECT @@hostname, @@super_read_only')
  echo "RO: $ro"
  [[ $ro == "${GR_HOSTS[1]}	1" || $ro == "${GR_HOSTS[2]}	1" ]]

  # a write through the read-write port is readable through the read-only port
  via "${GR_CIDS[1]}" "$rname" 6446 'CREATE DATABASE rt; CREATE TABLE rt.t (id INT PRIMARY KEY); INSERT INTO rt.t VALUES (1),(2)'
  n=
  for _ in $(seq 1 30); do
    n=$(via "${GR_CIDS[0]}" "$rname" 6447 'SELECT COUNT(*) FROM rt.t' || true)
    [[ $n == 2 ]] && break
    sleep 1
  done
  [ "$n" = 2 ]
  # the read-only port refuses writes
  run via "${GR_CIDS[0]}" "$rname" 6447 'INSERT INTO rt.t VALUES (3)'
  [ "$status" -ne 0 ]
}
