#!/usr/bin/env bats
# Percona Toolkit image, the way the official percona/percona-toolkit is used: tools run against a server over the
# network, and the Percona Operator for MySQL runs its pt-heartbeat sidecar from it (command
# /opt/percona/heartbeat-entrypoint.sh, datadir volume mounted at /var/lib/mysql, socket connection).
# tests/fixtures/heartbeat-entrypoint.sh is that script, verbatim from percona/percona-server-mysql-operator v1.3.0
# (commit e399eb71e9f5fcb53314ed1bfb4b021142ffd5b9, build/heartbeat-entrypoint.sh; Apache-2.0).
#
# Environment: IMAGE (the -dev server image, for the server), TOOLKIT_IMAGE (default
# localhost:5000/percona-toolkit:3.7). Docker only, no network access.

setup_file() {
  load helpers
  # shellcheck disable=SC2153 # PS_IMAGE comes from helpers.bash
  ps_pull_images "$PS_IMAGE" "${TOOLKIT_IMAGE:-localhost:5000/percona-toolkit:3.7}"
}

setup() {
  load helpers
  ps_require_dev
  unset PS_SQL_USER
  export PS_SQL_PASSWORD=x
  TOOLKIT_IMAGE=${TOOLKIT_IMAGE:-localhost:5000/percona-toolkit:3.7}
  VERSION_FILE=${VERSION_FILE:-$PS_ROOT/versions/9.7.yaml}
  PT_FULL=$(vars_get "$VERSION_FILE" pt_version)-$(vars_get "$VERSION_FILE" pt_release)
}

teardown() {
  ps_cleanup
}

# tk_run [docker-run-args...] -- [cmd...]: docker run --rm of the toolkit image (its own user); prints both streams
tk_run() {
  local -a dargs=()
  while (($#)) && [[ $1 != -- ]]; do dargs+=("$1"); shift; done
  if (($#)); then shift; fi
  ps_docker run --rm "${dargs[@]}" "$TOOLKIT_IMAGE" "$@" 2>&1
}

# server_on <net>: a server from the -dev image on <net> (root password x, root from anywhere); prints "<cid> <host>"
server_on() {
  local host cid
  host=$(ps_prefix)-db
  cid=$(ps_start db --network "$1" --hostname "$host" -e MYSQL_ROOT_PASSWORD=x -e 'MYSQL_ROOT_HOST=%' "${@:2}") || return 1
  ps_wait_ready "$cid" 180 || return 1
  printf '%s %s\n' "$cid" "$host"
}

@test "toolkit: user, command and environment of the official image" {
  run ps_docker image inspect -f '{{.Config.User}}|{{json .Config.Entrypoint}}|{{json .Config.Cmd}}|{{.Config.WorkingDir}}' "$TOOLKIT_IMAGE"
  echo "$output"
  [ "$output" = '1001|null|["/bin/bash"]|/' ]
  run ps_docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$TOOLKIT_IMAGE"
  echo "$output"
  [[ $output == *"PT_VERSION=$PT_FULL.wolfi"* ]]
  [[ $output == *"PS_VERSION=$(vars_get "$VERSION_FILE" ps_version)-$(vars_get "$VERSION_FILE" ps_release).wolfi"* ]]
  [[ $output == *"container=oci"* ]]
  run tk_run -- bash -c 'id; test -f /licenses/LICENSE.Dockerfile && echo license'
  echo "$output"
  [ "${lines[0]}" = "uid=1001(perconatoolkit) gid=0(root) groups=0(root)" ]
  [ "${lines[1]}" = license ]
}

@test "toolkit: every pt-* tool of the rpm prints its version; the operator sidecar's commands exist" {
  # shellcheck disable=SC2016 # expanded by bash in the container
  run tk_run -e PT_FULL="$PT_FULL" -- bash -c 'n=0; for t in /usr/bin/pt-*; do o=$("$t" --version 2>&1); case $o in *"$PT_FULL"*) n=$((n+1)) ;; *) echo "BAD $t: $o" ;; esac; done; echo "count=$n"'
  echo "$output"
  [[ $output != *BAD* ]]
  [[ $output == *"count=42"* ]]
  run tk_run -- bash -c 'command -v bash timeout mysql sed tr sleep cat kill pt-heartbeat perl'
  echo "$output"
  [ "$status" -eq 0 ]
  # on Wolfi /usr/sbin is a symlink to /usr/bin and comes first in PATH: either spelling is the same file
  [[ ${lines[1]} == /usr/bin/timeout || ${lines[1]} == /usr/sbin/timeout ]]
  [[ ${lines[2]} == /usr/bin/mysql || ${lines[2]} == /usr/sbin/mysql ]]
}

@test "toolkit: DBD::mysql loads and connects over TCP with TLS to a server from the -dev image" {
  net=$(ps_network tk)
  read -r cid host < <(server_on "$net")
  [ -n "$host" ]
  # shellcheck disable=SC2016 # Perl code, expanded in the container
  run tk_run --network "$net" -e DBHOST="$host" -- bash -c 'perl -MDBI -e '\''
    my $d = DBI->connect("DBI:mysql:host=$ENV{DBHOST};port=3306;mysql_ssl=1", "root", "x", {RaiseError => 1});
    my ($v) = $d->selectrow_array("SELECT VERSION()");
    my (undef, $c) = $d->selectrow_array("SHOW SESSION STATUS LIKE \x27Ssl_cipher\x27");
    print "DBD $DBD::mysql::VERSION server $v cipher $c\n";
  '\'''
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"DBD $(vars_get "$VERSION_FILE" dbd_mysql_version) server $(vars_get "$VERSION_FILE" ps_version)"* ]]
  [[ $output =~ cipher\ [A-Z0-9_-]+ ]]
}

@test "toolkit: pt-mysql-summary, pt-summary, pt-show-grants and pt-duplicate-key-checker against the server" {
  net=$(ps_network tk)
  read -r cid host < <(server_on "$net")
  [ -n "$host" ]
  ps_sql "$cid" 'CREATE DATABASE tk; CREATE TABLE tk.t (id INT PRIMARY KEY, v INT); INSERT INTO tk.t VALUES (1,1),(2,2)'
  run tk_run --network "$net" -- pt-mysql-summary --host "$host" --user root --password x
  echo "$output" | head -n 20
  [ "$status" -eq 0 ]
  [[ $output == *"# Percona Toolkit MySQL Summary Report"* ]]
  [[ $output == *"$(vars_get "$VERSION_FILE" ps_version)"* ]]
  run tk_run -- pt-summary
  echo "$output" | head -n 20
  [[ $output == *"# Percona Toolkit System Summary Report"* ]]
  run tk_run --network "$net" -- pt-show-grants --host "$host" --user root --password x
  echo "$output" | head -n 5
  [ "$status" -eq 0 ]
  [[ $output == *"GRANT"* ]]
  ps_sql "$cid" 'ALTER TABLE tk.t ADD KEY a (v), ADD KEY b (v)'
  run tk_run --network "$net" -- pt-duplicate-key-checker --host "$host" --user root --password x --databases tk
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"ALTER TABLE \`tk\`.\`t\` DROP INDEX"* ]]
}

@test "toolkit: the operator's heartbeat sidecar writes heartbeats over the datadir socket and stops on SIGTERM" {
  vol=$(ps_volume data)
  net=$(ps_network tk)
  read -r cid host < <(server_on "$net" -v "$vol:/var/lib/mysql")
  [ -n "$host" ]
  ps_sql "$cid" "CREATE DATABASE sys_operator;
    CREATE USER 'monitor'@'%' IDENTIFIED BY 'mon'; GRANT SELECT, PROCESS ON *.* TO 'monitor'@'%';
    CREATE USER 'heartbeat'@'%' IDENTIFIED BY 'h,b'; CREATE USER 'heartbeat'@'localhost' IDENTIFIED BY 'h,b';
    GRANT ALL ON sys_operator.* TO 'heartbeat'@'%'; GRANT ALL ON sys_operator.* TO 'heartbeat'@'localhost';
    GRANT REPLICATION CLIENT ON *.* TO 'heartbeat'@'%'; GRANT REPLICATION CLIENT ON *.* TO 'heartbeat'@'localhost';
    CREATE USER 'monitor'@'localhost' IDENTIFIED BY 'mon'; GRANT SELECT, PROCESS ON *.* TO 'monitor'@'localhost'"
  sec=$BATS_TEST_TMPDIR/secret
  mkdir -p "$sec" && printf mon > "$sec/monitor" && chmod 0755 "$sec" && chmod 0644 "$sec/monitor"
  hb=$(ps_prefix)-hb
  ps_track containers "$hb"
  ps_docker run -d --name "$hb" -v "$vol:/var/lib/mysql" -v "$sec:/etc/mysql/mysql-users-secret:ro" \
    -v "$PS_ROOT/tests/fixtures/heartbeat-entrypoint.sh:/opt/percona/heartbeat-entrypoint.sh:ro" \
    -e HEARTBEAT_PASSWORD='h,b' "$TOOLKIT_IMAGE" bash /opt/percona/heartbeat-entrypoint.sh > /dev/null
  n=0
  for _ in $(seq 1 60); do
    n=$(ps_sql "$cid" 'SELECT COUNT(*) FROM sys_operator.heartbeat' 2> /dev/null || echo 0)
    [[ $n -ge 1 ]] && break
    sleep 2
  done
  echo "# heartbeat logs: $(ps_docker logs "$hb" 2>&1 | tail -n 5)" >&3
  [ "$n" -ge 1 ]
  t1=$(ps_sql "$cid" 'SELECT MAX(ts) FROM sys_operator.heartbeat')
  sleep 3
  t2=$(ps_sql "$cid" 'SELECT MAX(ts) FROM sys_operator.heartbeat')
  echo "ts $t1 -> $t2"
  [[ $t2 > $t1 ]]
  run ps_logs "$hb"
  [[ $output == *"starting pt-heartbeat"* ]]
  ps_docker stop -t 20 "$hb" > /dev/null
  [ "$(ps_docker inspect -f '{{.State.ExitCode}}' "$hb")" = 0 ]
}
