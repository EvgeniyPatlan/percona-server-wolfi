#!/usr/bin/env bats
# Runtime behaviour of the server images: restart, graceful shutdown, user, jemalloc, telemetry, listeners,
# and the distroless image on a datadir initialised by -dev. Needs IMAGE and a docker daemon.

# The images under test come from the registry (apko publishes there, nothing is in the local docker): pull them once;
# a failed pull fails every test of the suite instead of skipping it.
setup_file() {
  load helpers
  ps_image_pair
  ps_pull_images "$PS_IMAGE_DEV" "$PS_IMAGE_DISTROLESS"
}

setup() {
  load helpers
  ps_image_pair
  unset PS_SQL_USER PS_SQL_PASSWORD
}

teardown() {
  ps_cleanup
}

@test "restart on the same volume without env: ready, data present, no init messages" {
  ps_require_dev
  vol=$(ps_volume restart)
  cid=$(ps_start first -e MYSQL_ROOT_PASSWORD=x -v "$vol:/var/lib/mysql")
  ps_wait_ready "$cid"
  export PS_SQL_PASSWORD=x
  ps_sql "$cid" 'CREATE DATABASE keep; CREATE TABLE keep.t (n INT); INSERT INTO keep.t VALUES (42)'
  ps_docker stop "$cid" > /dev/null
  ps_rm "$cid"

  cid2=$(ps_start second -v "$vol:/var/lib/mysql")
  ps_wait_ready "$cid2"
  run ps_sql "$cid2" 'SELECT n FROM keep.t'
  [ "$status" -eq 0 ]
  [ "$output" = 42 ]
  logs=$(ps_logs "$cid2")
  [[ $logs != *'Initializing database'* ]]
  [[ $logs != *'MySQL init process'* ]]
  [[ $logs != *'GENERATED ROOT PASSWORD'* ]]
}

# Server log lines at verbosity 3 include InnoDB's "Starting crash recovery" marker when recovery is needed.
@test "docker stop is a clean shutdown: no crash recovery on the next start" {
  ps_require_dev
  cid=$(ps_start clean -e MYSQL_ROOT_PASSWORD=x -- --log-error-verbosity=3)
  ps_wait_ready "$cid"
  export PS_SQL_PASSWORD=x
  ps_sql "$cid" 'CREATE DATABASE c; CREATE TABLE c.t (n INT); INSERT INTO c.t VALUES (1)'
  ps_docker stop "$cid" > /dev/null # default 10 s grace period
  [ "$(ps_docker inspect -f '{{.State.ExitCode}}' "$cid")" -eq 0 ]
  ps_logs "$cid" | grep -q 'Shutdown complete'
  before=$(ps_logs "$cid" | wc -l)
  ps_docker start "$cid" > /dev/null
  ps_wait_ready "$cid"
  after=$(ps_logs "$cid" | tail -n +"$((before + 1))")
  [[ $after != *'Starting crash recovery'* ]]
  run ps_sql "$cid" 'SELECT n FROM c.t'
  [ "$output" = 1 ]
}

# Positive control: the marker the test above relies on really appears after an unclean stop.
@test "kill -9 is followed by crash recovery (control for the clean-shutdown test)" {
  ps_require_dev
  cid=$(ps_start crash -e MYSQL_ROOT_PASSWORD=x -- --log-error-verbosity=3)
  ps_wait_ready "$cid"
  export PS_SQL_PASSWORD=x
  ps_sql "$cid" 'CREATE DATABASE c; CREATE TABLE c.t (n INT); INSERT INTO c.t VALUES (1)'
  ps_docker kill -s KILL "$cid" > /dev/null
  before=$(ps_logs "$cid" | wc -l)
  ps_docker start "$cid" > /dev/null
  ps_wait_ready "$cid"
  after=$(ps_logs "$cid" | tail -n +"$((before + 1))")
  [[ $after == *'Starting crash recovery'* ]]
}

@test "runs as uid 1001 with mysqld as pid 1" {
  ps_require_dev
  cid=$(ps_start ident -e MYSQL_ALLOW_EMPTY_PASSWORD=yes)
  ps_wait_ready "$cid"
  run ps_docker exec "$cid" id -u
  [ "$output" = 1001 ]
  run ps_peek "$cid" sh -c "tr '\\0' ' ' < /proc/1/cmdline"
  [ "$status" -eq 0 ]
  [[ $output == mysqld* ]]
}

# Ruling R8: like the official image, neither image preloads jemalloc by default; the library is only shipped.
# check_no_preload <cid>: mysqld (pid 1) has no jemalloc mapped and no LD_PRELOAD in its environment.
check_no_preload() {
  run ps_peek "$1" cat /proc/1/maps
  [ "$status" -eq 0 ]
  [[ $output != *libjemalloc* ]]
  run ps_peek "$1" sh -c "tr '\\0' '\\n' < /proc/1/environ"
  [ "$status" -eq 0 ]
  [[ $output != *LD_PRELOAD* ]]
}

@test "jemalloc: libjemalloc.so.2 shipped, not preloaded (-dev)" {
  ps_require_dev
  cid=$(ps_start jem -e MYSQL_ALLOW_EMPTY_PASSWORD=yes)
  ps_wait_ready "$cid"
  ps_has_file "$cid" /usr/lib/libjemalloc.so.2
  check_no_preload "$cid"
}

@test "jemalloc: libjemalloc.so.2 shipped, not preloaded (distroless)" {
  vol=$(ps_volume jemdl)
  PS_IMAGE=$PS_IMAGE_DEV ps_init_volume "$vol"
  cid=$(PS_IMAGE=$PS_IMAGE_DISTROLESS ps_start jemdl -v "$vol:/var/lib/mysql")
  ps_wait_ready "$cid"
  ps_has_file "$cid" /usr/lib/libjemalloc.so.2
  check_no_preload "$cid"
}

@test "PERCONA_TELEMETRY_DISABLE=1: no telemetry agent process" {
  ps_require_dev
  cid=$(ps_start telemoff -e MYSQL_ALLOW_EMPTY_PASSWORD=yes -e PERCONA_TELEMETRY_DISABLE=1)
  ps_wait_ready "$cid"
  sleep 15 # the supervisor would have started it by now
  run ps_docker top "$cid"
  [ "$status" -eq 0 ]
  [[ $output != *percona-telemetry-agent* ]]
}

@test "telemetry enabled (default): agent process runs" {
  ps_require_dev
  cid=$(ps_start telemon -e MYSQL_ALLOW_EMPTY_PASSWORD=yes)
  ps_wait_ready "$cid"
  found=
  for _ in $(seq 1 30); do
    if ps_docker top "$cid" | grep -q percona-telemetry-agent; then
      found=1
      break
    fi
    sleep 1
  done
  [ -n "$found" ]
}

@test "socket exists; 3306 and 33060 are listening" {
  ps_require_dev
  cid=$(ps_start listen -e MYSQL_ALLOW_EMPTY_PASSWORD=yes)
  ps_wait_ready "$cid"
  ps_docker exec "$cid" test -S /var/lib/mysql/mysql.sock
  run ps_peek "$cid" python3 -c 'import socket
for p in (3306, 33060):
    socket.create_connection(("127.0.0.1", p), 5).close()'
  [ "$status" -eq 0 ]
}

@test "distroless: starts on a datadir initialised by -dev, SELECT 1 works, no /bin/sh" {
  ps_image_pair
  vol=$(ps_volume distroless)
  PS_IMAGE=$PS_IMAGE_DEV ps_init_volume "$vol"
  cid=$(PS_IMAGE=$PS_IMAGE_DISTROLESS ps_start distroless -v "$vol:/var/lib/mysql")
  ps_wait_ready "$cid"
  PS_SQL_PASSWORD=x run ps_sql "$cid" 'SELECT 1'
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  run ps_peek "$cid" sh -c "tr '\\0' ' ' < /proc/1/cmdline"
  [ "$status" -eq 0 ]
  [[ $output == /usr/sbin/mysqld* || $output == mysqld* ]]
  for f in /bin/sh /usr/bin/sh /bin/busybox /bin/bash; do
    run ps_has_file "$cid" "$f"
    [ "$status" -ne 0 ]
  done
  run ps_docker exec "$cid" /bin/sh -c true
  [ "$status" -ne 0 ]
}
