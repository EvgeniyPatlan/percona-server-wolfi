#!/usr/bin/env bats
# shellcheck disable=SC2016 # the scripts in single quotes expand in the container
# HAProxy image, the way the official percona/haproxy is used by the Percona operators: the entrypoint starts haproxy
# in master-worker mode on /etc/haproxy/haproxy-global.cfg + /etc/haproxy/pxc/haproxy.cfg, add_pxc_nodes.sh rewrites
# the backend list from the operator's peer list and reloads through the master socket, and the check scripts query
# the MySQL admin port (33062) as the monitor user. The operators may replace the scripts with their own
# (percona-server-mysql-operator build/haproxy*, percona-xtradb-cluster-operator build/haproxy*): the tools those call
# are checked too.
#
# Environment: IMAGE (the -dev server image, for the backend server), HAPROXY_IMAGE (default
# localhost:5000/percona-haproxy:3.4). Docker only, no network access.

setup_file() {
  load helpers
  # shellcheck disable=SC2153 # PS_IMAGE comes from helpers.bash
  ps_pull_images "$PS_IMAGE" "${HAPROXY_IMAGE:-localhost:5000/percona-haproxy:3.4}"
}

setup() {
  load helpers
  HAPROXY_IMAGE=${HAPROXY_IMAGE:-localhost:5000/percona-haproxy:3.4}
  VERSION_FILE=${VERSION_FILE:-$PS_ROOT/versions/9.7.yaml}
}

teardown() {
  ps_cleanup
}

# ha_run [docker-run-args...] -- <bash script>: run the script in the image (image user, entrypoint bypassed);
# prints both streams
ha_run() {
  local -a dargs=()
  while (($#)) && [[ $1 != -- ]]; do dargs+=("$1"); shift; done
  if (($#)); then shift; fi
  ps_docker run --rm "${dargs[@]}" --entrypoint bash "$HAPROXY_IMAGE" -c "$1" 2>&1
}

# ha_start <name> [docker-run-args...]: docker run -d of the image with its default command; prints the container id
ha_start() {
  local full
  full=$(ps_prefix)-$1
  shift
  ps_track containers "$full"
  ps_docker run -d --name "$full" "$@" "$HAPROXY_IMAGE"
}

# ha_wait_socket <cid> <path> [timeout=30]: wait until haproxy has created the unix socket
ha_wait_socket() {
  local i
  for ((i = 0; i < ${3:-30}; i++)); do
    ps_docker exec "$1" test -S "$2" 2> /dev/null && return 0
    sleep 1
  done
  ps_logs "$1" >&2
  return 1
}

@test "haproxy: versions, uid, no file capabilities, and the tools of the official and operator scripts" {
  v=$(vars_get "$VERSION_FILE" haproxy_version)
  # --cap-drop ALL: a binary with file capabilities cannot even be exec'ed (the -nocaps build is used)
  run ha_run --cap-drop ALL -- 'haproxy -v'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"HAProxy version $v"* ]]
  run ha_run -- 'haproxy -vv'
  [[ $output == *"prometheus-exporter"* ]]
  [[ $output == *"Built with Lua"* ]]
  run ha_run -- 'mysql --version'
  [[ $output == *"$(vars_get "$VERSION_FILE" ps_version)"* ]]
  run ha_run -- 'id -u; id -g; readlink -f /bin/sh'
  [ "${lines[0]}" = 1001 ]
  [ "${lines[1]}" = 1001 ]
  [ "${lines[2]}" = /usr/bin/bash ]
  # entrypoint.sh, add_pxc_nodes.sh, check_pxc.sh, liveness/readiness checks (official); haproxy-entrypoint.sh,
  # haproxy_add_*_nodes.sh, haproxy_check_*.sh (operators): absolute paths as they are called
  run ha_run -- 'for c in /usr/bin/date /usr/bin/timeout /usr/bin/mysql /usr/bin/grep /usr/bin/sed /usr/bin/tr /bin/cat \
    socat haproxy cut sort uniq awk cp install id ps tar which; do command -v "$c" > /dev/null || echo "missing $c"; done
    date +"%d/%b/%Y:%H:%M:%S.%3N" | grep -qE "^[0-9]{2}/[A-Z][a-z]{2}/[0-9]{4}:[0-9:]{8}\.[0-9]{3}$" || echo "date %3N"
    [ "$(printf "%s\n" a-10 a-9 a-2 | sort --version-sort -r | head -n1)" = a-10 ] || echo "sort -V"
    ulimit -n 1024 || echo ulimit
    a=x; a+=y; [ "$a" = xy ] || echo "+="'
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "haproxy: files, owners and licenses as in the official image" {
  # owners as in the official image (checked): 1001 owns the writable dirs, the configs and check_pxc.sh
  run ha_run -- 'stat -c "%u:%g %n" /etc/haproxy/pxc /etc/haproxy-custom /run /etc/haproxy/haproxy.cfg \
    /etc/haproxy/haproxy-global.cfg /usr/local/bin/check_pxc.sh'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -vc '^1001:1001 ' <<< "$output")" -eq 0 ]
  [ "$(wc -l <<< "$output")" -eq 6 ]
  run ha_run -- 'for f in /entrypoint.sh /usr/bin/add_pxc_nodes.sh /usr/local/bin/liveness-check.sh \
    /usr/local/bin/readiness-check.sh /usr/local/bin/check_pxc.sh /usr/sbin/haproxy; do test -x "$f" || echo "$f"; done
    for f in /licenses/LICENSE.Dockerfile /licenses/LICENSE.haproxy; do test -s "$f" || echo "$f"; done
    touch /etc/haproxy/pxc/w /etc/haproxy-custom/w /run/w || echo "not writable"'
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "haproxy: add_pxc_nodes.sh turns a peer list into a backend config that passes haproxy -c" {
  run ha_run -- 'printf "%s\n" c-pxc-0.c-pxc.ns.svc c-pxc-1.c-pxc.ns.svc c-pxc-2.c-pxc.ns.svc | /usr/bin/add_pxc_nodes.sh &&
    echo "--- cfg" && cat /etc/haproxy/pxc/haproxy.cfg && echo "--- nodes $(cat /etc/haproxy/pxc/AVAILABLE_NODES)"'
  echo "$output"
  [ "$status" -eq 0 ]
  # errexit: the haproxy -c of the generated config passed
  [[ $output == *"number of available nodes are 3"* ]]
  [[ $output == *"--- nodes 3"* ]]
  # node 0 is the active server, the others are backups; the replica backend gets the readers only
  grep -qE '^ *server c-pxc-0 c-pxc-0.c-pxc.ns.svc:3306 +resolvers kubernetes .* on-marked-up shutdown-backup-sessions$' <<< "$output"
  grep -qE '^ *server c-pxc-1 c-pxc-1.c-pxc.ns.svc:33062 .* backup$' <<< "$output"
  [ "$(sed -n '/backend galera-replica-nodes/,/backend galera-mysqlx-nodes/p' <<< "$output" | grep -c '^ *server ')" -eq 2 ]
}

@test "haproxy: the entrypoint starts haproxy (master socket, stats socket, /metrics); reload keeps it serving" {
  cid=$(ha_start run)
  ha_wait_socket "$cid" /etc/haproxy/pxc/haproxy-main.sock
  ha_wait_socket "$cid" /etc/haproxy/pxc/haproxy.sock
  run ps_docker exec "$cid" bash -c 'echo "show info" | socat stdio /etc/haproxy/pxc/haproxy.sock'
  [[ $output == *"Version: $(vars_get "$VERSION_FILE" haproxy_version)"* ]]
  ps_docker exec "$cid" test -s /etc/haproxy/pxc/haproxy.pid
  # what add_pxc_nodes.sh does after rewriting the config
  run ps_docker exec "$cid" bash -c 'printf "%s\n" c-pxc-0.c-pxc c-pxc-1.c-pxc | /usr/bin/add_pxc_nodes.sh'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"reload | socat stdio /etc/haproxy/pxc/haproxy-main.sock"* ]]
  # the new worker serves the rewritten backends (show stat: "<backend>,<server>,...")
  run ps_docker exec "$cid" bash -c 'for i in $(seq 1 20); do
      echo "show stat" | socat stdio /etc/haproxy/pxc/haproxy.sock | grep -q "^galera-nodes,c-pxc-1," && exit 0; sleep 1
    done; exit 1'
  [ "$status" -eq 0 ]
  run ps_docker exec "$cid" bash -c 'echo "show proc" | socat stdio /etc/haproxy/pxc/haproxy-main.sock'
  echo "$output"
  [[ $output == *worker* ]]
  run ps_docker exec "$cid" bash -c 'exec 3<> /dev/tcp/127.0.0.1/8404; printf "GET /metrics HTTP/1.0\r\n\r\n" >&3; cat <&3'
  [[ $output == *"200 OK"* ]]
  [[ $output == *"haproxy_process_"* ]]
  ps_logs "$cid" | grep -q '"message": "haproxy -W -db -f /etc/haproxy/haproxy-global.cfg -f /etc/haproxy/pxc/haproxy.cfg'
}

@test "haproxy: an invalid custom global config is logged and ignored" {
  d=$BATS_TEST_TMPDIR/custom
  mkdir -p "$d"
  printf 'global\n  no-such-keyword\n' > "$d/haproxy-global.cfg"
  chmod 755 "$d"
  chmod 644 "$d/haproxy-global.cfg"
  cid=$(ha_start custom -v "$d:/etc/haproxy-custom:ro")
  ha_wait_socket "$cid" /etc/haproxy/pxc/haproxy-main.sock
  run ps_logs "$cid"
  echo "$output"
  [[ $output == *"The custom config /etc/haproxy-custom/haproxy-global.cfg is not valid and will be ignored."* ]]
  [[ $output == *"-f /etc/haproxy/haproxy-global.cfg"* ]]
}

@test "haproxy: liveness-check.sh and the operators' monitor queries against a server's admin port" {
  srv=$(ps_start srv -e MYSQL_ROOT_PASSWORD=x -- --admin-address=127.0.0.1 --admin-port=33062)
  ps_wait_ready "$srv"
  PS_SQL_PASSWORD=x ps_sql "$srv" "CREATE USER monitor@'%' IDENTIFIED BY 'mon'; GRANT SERVICE_CONNECTION_ADMIN, PROCESS, REPLICATION CLIENT ON *.* TO monitor@'%'; GRANT SELECT ON performance_schema.* TO monitor@'%'"
  d=$BATS_TEST_TMPDIR/secret
  mkdir -p "$d"
  printf mon > "$d/monitor"
  chmod 755 "$d"
  chmod 644 "$d/monitor"
  ns=(--network "container:$srv" -v "$d:/etc/mysql/mysql-users-secret:ro")
  run ha_run "${ns[@]}" -- '/usr/local/bin/liveness-check.sh && /usr/local/bin/readiness-check.sh'
  echo "$output"
  [ "$status" -eq 0 ]
  # the PS operator's haproxy_check_primary.sh query form (-BnN, MYSQL_PWD, timeout)
  run ha_run "${ns[@]}" -- 'MYSQL_PWD=mon /usr/bin/timeout 10 /usr/bin/mysql -BnN -umonitor -h 127.0.0.1 -P 33062 \
    -e "select concat(@@global.read_only,\",\",@@global.super_read_only)"'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "0,0" ]
  # check_pxc.sh: a Percona Server (no wsrep) is reported "not ok" with the values it read
  run ha_run "${ns[@]}" -e HAPROXY_PROXY_NAME=galera-nodes -- '/usr/local/bin/check_pxc.sh "" "" 127.0.0.1'
  echo "$output"
  [ "$status" -eq 1 ]
  [[ $output == *"pxc_maint_mod is"*"is not ok"* ]]
  # a wrong password fails the liveness check
  printf bad > "$d/monitor"
  run ha_run "${ns[@]}" -- '/usr/local/bin/liveness-check.sh'
  [ "$status" -eq 1 ]
}
