#!/usr/bin/env bats
# shellcheck disable=SC2016 # the scripts in single quotes expand in the container
# Log collector image, the way the official percona/fluentbit is used by the Percona operators: one sidecar runs
# fluent-bit (tailing the server's logs to stdout), another runs `logrotate` under supercronic, whose postrotate
# script flushes the server's logs over the admin port as the monitor user. The operators may mount their own
# entrypoint and configs (percona-server-mysql-operator build/logcollector, percona-xtradb-cluster-operator
# build/logcollector): the tools those call, and a YAML config in their style, are checked too.
#
# Environment: IMAGE (the -dev server image, for the server whose logs are rotated), FLUENTBIT_IMAGE (default
# localhost:5000/percona-fluentbit:5.0). Docker only, no network access.

setup_file() {
  load helpers
  # shellcheck disable=SC2153 # PS_IMAGE comes from helpers.bash
  ps_pull_images "$PS_IMAGE" "${FLUENTBIT_IMAGE:-localhost:5000/percona-fluentbit:5.0}"
}

setup() {
  load helpers
  unset PS_SQL_USER
  export PS_SQL_PASSWORD=x
  FLUENTBIT_IMAGE=${FLUENTBIT_IMAGE:-localhost:5000/percona-fluentbit:5.0}
  VERSION_FILE=${VERSION_FILE:-$PS_ROOT/versions/9.7.yaml}
}

teardown() {
  ps_cleanup
}

# fb_run [docker-run-args...] -- <bash script>: run the script in the image (image user, entrypoint bypassed);
# prints both streams
fb_run() {
  local -a dargs=()
  while (($#)) && [[ $1 != -- ]]; do dargs+=("$1"); shift; done
  if (($#)); then shift; fi
  # PATH as both entrypoints set it (the fluent-bit rpm installs into /opt/fluent-bit/bin)
  ps_docker run --rm "${dargs[@]}" --entrypoint bash "$FLUENTBIT_IMAGE" -c "export PATH=\$PATH:/opt/fluent-bit/bin; $1" 2>&1
}

# fb_start <name> [docker-run-args...] [-- cmd...]: docker run -d of the image (its entrypoint); prints the container id
fb_start() {
  local full
  full=$(ps_prefix)-$1
  shift
  local -a dargs=()
  while (($#)) && [[ $1 != -- ]]; do dargs+=("$1"); shift; done
  if (($#)); then shift; fi
  ps_track containers "$full"
  ps_docker run -d --name "$full" "${dargs[@]}" "$FLUENTBIT_IMAGE" "$@"
}

# wait_for <seconds> <cmd...>: retry the command once a second until it succeeds
wait_for() {
  local n=$1 i
  shift
  for ((i = 0; i < n; i++)); do
    "$@" && return 0
    sleep 1
  done
  return 1
}

@test "fluentbit: versions, uid, and the tools of the official and operator scripts" {
  v=$(vars_get "$VERSION_FILE" fluentbit_version)
  run fb_run -- 'fluent-bit --version; /opt/fluent-bit/bin/fluent-bit --version'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -c "^Fluent Bit v$v" <<< "$output")" -eq 2 ]
  run fb_run -- 'mysql --version'
  [[ $output == *"$(vars_get "$VERSION_FILE" ps_version)"* ]]
  run fb_run -- 'id -u; id -g; readlink -f /bin/sh; [ -f /usr/bin/supercronic ] && echo supercronic'
  [ "${lines[0]}" = 1001 ]
  [ "${lines[1]}" = 1001 ]
  [ "${lines[2]}" = /usr/bin/bash ]
  [ "${lines[3]}" = supercronic ]
  # entrypoint.sh / postrotate-mysql.sh (official, PXC operator), the PS operator's logcollector entrypoint
  run fb_run -- 'for c in supercronic logrotate fluent-bit /usr/bin/find /usr/bin/timeout /usr/bin/mysql hostname awk \
    grep sed cat cp mkdir touch basename tar ps; do command -v "$c" > /dev/null || echo "missing $c"; done
    read -r ip _ <<< "$(hostname -I)"; [[ $ip =~ ^[0-9.]+$ ]] || echo "hostname -I: $ip"
    fluent-bit --version | grep -qE "^Fluent Bit v[0-9]+\." || echo "version line"
    a=x; a+=y; [[ $a == xy ]] || echo "+="'
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fluentbit: files, owners and modes as in the official image" {
  run fb_run -- 'stat -c "%u:%g %a %n" /etc/passwd /usr/local/bin /usr/local/bin/postrotate-mysql.sh /opt/percona \
    /opt/percona/logrotate /opt/percona/logrotate/logrotate-mysql.conf /etc/fluentbit /etc/fluentbit/fluentbit.conf \
    /etc/fluentbit/fluentbit_pxc.conf /etc/fluentbit/parsers_multiline.conf /entrypoint.sh /licenses/LICENSE.Dockerfile'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "0:0 664 /etc/passwd" ]
  [ "${lines[1]}" = "1001:1001 755 /usr/local/bin" ]
  [ "${lines[2]}" = "1001:1001 755 /usr/local/bin/postrotate-mysql.sh" ]
  [ "${lines[3]}" = "1001:1001 775 /opt/percona" ]
  [ "${lines[4]}" = "1001:1001 775 /opt/percona/logrotate" ]
  [ "${lines[5]}" = "1001:1001 775 /opt/percona/logrotate/logrotate-mysql.conf" ]
  [[ ${lines[6]} == "1001:1001 "*" /etc/fluentbit" ]]
  [[ ${lines[7]} == "1001:1001 644 /etc/fluentbit/fluentbit.conf" ]]
  [[ ${lines[10]} == "0:0 755 /entrypoint.sh" ]]
}

@test "fluentbit: the shipped config and an operator-style YAML config pass fluent-bit --dry-run" {
  run fb_run -e LOG_DATA_DIR=/tmp -e POD_NAMESPASE=ns -e POD_NAME=pod -- 'fluent-bit --dry-run -c /etc/fluentbit/fluentbit.conf'
  echo "$output"
  [ "$status" -eq 0 ]
  # the shape of percona-server-mysql-operator build/logcollector/fluentbit/fluentbit.yaml: includes, service with the
  # HTTP server, tail inputs with the multiline parser of the shipped parsers file, stdout json_lines
  run fb_run -e LOG_DIR=/tmp -e POD_NAMESPACE=ns -e POD_NAME=pod -- 'mkdir -p /tmp/fb/custom && touch /tmp/fb/custom/default.yaml
    cat > /tmp/fb/fluentbit.yaml <<EOF
includes:
  - /tmp/fb/custom/*.yaml
service:
  flush: 1
  log_level: error
  parsers_file: /etc/fluentbit/parsers_multiline.conf
  http_server: on
  http_listen: 0.0.0.0
  http_port: 2020
pipeline:
  inputs:
    - name: tail
      path: \${LOG_DIR}/*.log,\${LOG_DIR}/*.err
      tag: \${POD_NAMESPACE}.\${POD_NAME}.mysql
      multiline.parser: multiline-regex-test
      refresh_interval: 5
      db: \${LOG_DIR}/flb_mysql_v5.db
      ignore_older: 1d
      read_from_head: true
      path_key: file
      skip_long_lines: on
  outputs:
    - name: stdout
      match: "*"
      format: json_lines
      json_date_key: false
EOF
    fluent-bit --dry-run -c /tmp/fb/fluentbit.yaml'
  echo "$output"
  [ "$status" -eq 0 ]
  # an invalid file fails the dry run (the PS operator's entrypoint relies on this to skip bad custom configs)
  run fb_run -- 'printf "pipeline:\n  inputs:\n    - name: no-such-plugin\n" > /tmp/bad.yaml; fluent-bit --dry-run -c /tmp/bad.yaml'
  [ "$status" -ne 0 ]
}

@test "fluentbit: the entrypoint runs fluent-bit on the shipped config; a new error log line reaches stdout" {
  cid=$(fb_start fb -e LOG_DATA_DIR=/tmp -e POD_NAMESPASE=ns -e POD_NAME=pod)
  sleep 2
  ps_docker exec "$cid" bash -c 'printf "%s\n" "2026-11-17T10:00:00.000000Z 0 [Note] [MY-000000] [Server] fb-test-line" >> /tmp/mysqld-error.log'
  logs_have() { ps_logs "$cid" | grep -q "$1"; }
  wait_for 30 logs_have 'fb-test-line'
  run ps_logs "$cid"
  # json_lines record of the tail input, with the multiline parser and the Path_Key
  grep 'fb-test-line' <<< "$output" | grep -q '"file":"/tmp/mysqld-error.log"'
  [[ $output == *"fluent-bit -c /etc/fluentbit/fluentbit.conf"* ]]
}

@test "fluentbit: logrotate mode runs supercronic with the daily logrotate job, also as an arbitrary UID" {
  cid=$(fb_start lr -e SERVICE_TYPE=mysql -- logrotate)
  crontab_ready() { ps_docker exec "$cid" test -s /tmp/crontab; }
  wait_for 20 crontab_ready
  run ps_docker exec "$cid" cat /tmp/crontab
  echo "$output"
  [[ $output == "0 0 * * * logrotate -s /opt/percona/logrotate/logrotate.status /opt/percona/logrotate/logrotate-mysql.conf;/usr/bin/find /var/lib/mysql/ -name 'GRA_*.log' -mtime +7 -delete" ]]
  [ "$(ps_docker exec "$cid" cat /proc/1/comm)" = supercronic ]
  # OpenShift style: a random UID in the root group; the entrypoint points the 1001 passwd entry at it
  cid2=$(fb_start lr-uid --user 4242:0 -e SERVICE_TYPE=mysql -- logrotate)
  crontab2_ready() { ps_docker exec "$cid2" test -s /tmp/crontab; }
  wait_for 20 crontab2_ready
  run ps_docker exec "$cid2" grep ':x:4242:1001:' /etc/passwd
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(ps_docker exec "$cid2" cat /proc/1/comm)" = supercronic ]
}

@test "fluentbit: logrotate with postrotate-mysql.sh rotates a server log and flushes the server's logs" {
  # postrotate-mysql.sh connects to the first address of `hostname -I` (the pod IP); the admin port cannot listen on a
  # wildcard address, so it is bound to the container's own name (resolved to that address through /etc/hosts)
  h=$(ps_prefix)-srv
  vol=$(ps_volume data)
  srv=$(ps_start srv --hostname "$h" -v "$vol:/var/lib/mysql" -e MYSQL_ROOT_PASSWORD=x -- --admin-address="$h" --admin-port=33062)
  ps_wait_ready "$srv"
  ps_sql "$srv" "CREATE USER monitor@'%' IDENTIFIED BY 'mon'; GRANT RELOAD, SERVICE_CONNECTION_ADMIN, PROCESS ON *.* TO monitor@'%'"
  ps_docker exec "$srv" bash -c 'head -c 11000000 /dev/zero | tr "\0" "x" > /var/lib/mysql/fb-test.log'
  run fb_run --network "container:$srv" -v "$vol:/var/lib/mysql" -e MONITOR_PASSWORD=mon -- \
    'logrotate -v -f -s /tmp/logrotate.status /opt/percona/logrotate/logrotate-mysql.conf && ls /var/lib/mysql'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"fb-test.log.1"* ]]
  [[ $output == *"running postrotate script"* ]]
  # the flush itself, as postrotate-mysql.sh runs it (wrong password: the script fails)
  run fb_run --network "container:$srv" -e MONITOR_PASSWORD=bad -- '/usr/local/bin/postrotate-mysql.sh'
  [ "$status" -ne 0 ]
}
