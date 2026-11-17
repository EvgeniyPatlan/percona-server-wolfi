#!/usr/bin/env bats
# Binlog Server image, the way the Percona Operator for MySQL runs perconalab/percona-binlog-server: the container runs
# `/usr/bin/binlog_server pull /etc/binlog_server/config/config.json` (through the operator's `exec $@` entrypoint) with
# the replication user against the primary, a buffer volume at /var/lib/binlogsrv and an S3 storage; the restore jobs
# run `binlog_server search_by_* <config> <arg>` with /bin/sh -c. Here the source is the -dev server image with GTID
# binary logs, the storage a local directory or MinIO.
#
# Environment: IMAGE (the -dev server image), PBS_IMAGE (default localhost:5000/percona-binlog-server:0.4).
# Docker only, no network access (MinIO from versions/tools.yaml).

setup_file() {
  load helpers
  # shellcheck disable=SC2153 # PS_IMAGE comes from helpers.bash
  ps_pull_images "$PS_IMAGE" "${PBS_IMAGE:-localhost:5000/percona-binlog-server:0.4}"
}

setup() {
  load helpers
  ps_require_dev
  unset PS_SQL_USER
  export PS_SQL_PASSWORD=x
  PBS_IMAGE=${PBS_IMAGE:-localhost:5000/percona-binlog-server:0.4}
  VERSION_FILE=${VERSION_FILE:-$PS_ROOT/versions/9.7.yaml}
  CFG_DIR=$BATS_TEST_TMPDIR/cfg
  mkdir -p "$CFG_DIR"
  chmod 755 "$CFG_DIR"
}

teardown() {
  ps_cleanup
}

# pbs_run [docker-run-args...] -- [cmd...]: docker run --rm of the binlog server image (its CMD is bash); prints both
# streams
pbs_run() {
  local -a dargs=()
  while (($#)) && [[ $1 != -- ]]; do dargs+=("$1"); shift; done
  if (($#)); then shift; fi
  ps_docker run --rm "${dargs[@]}" "$PBS_IMAGE" "$@" 2>&1
}

# write_config <name> <host> <storage-backend> <storage-uri>: config.json as the operator generates it
# (pkg/binlogserver/config.go: logger to stdout, replication user, gtid mode with rewrite, buffer /var/lib/binlogsrv)
write_config() {
  cat > "$CFG_DIR/$1" <<EOF
{
  "logger": { "level": "info", "file": "/dev/stdout" },
  "connection": {
    "host": "$2", "port": 3306, "user": "replication", "password": "repl-Secret1",
    "connect_timeout": 10, "read_timeout": 10, "write_timeout": 10,
    "ssl": { "mode": "required" }
  },
  "replication": {
    "server_id": 4242, "idle_time": 2, "verify_checksum": true, "mode": "gtid",
    "rewrite": { "base_file_name": "binlog", "file_size": "128M" }
  },
  "storage": {
    "backend": "$3", "uri": "$4", "fs_buffer_directory": "/var/lib/binlogsrv",
    "checkpoint_size": "16M", "checkpoint_interval": "2s"
  }
}
EOF
  chmod 644 "$CFG_DIR/$1"
}

# source_server <network>: -dev server with GTID binary logs, the operator's replication user and some data.
# Sets SRV_CID, SRV_NAME, SRV_UUID.
source_server() {
  SRV_CID=$(ps_start source --network "$1" -e MYSQL_ROOT_PASSWORD=x -- \
    --gtid-mode=ON --enforce-gtid-consistency=ON --server-id=1)
  ps_wait_ready "$SRV_CID" 180
  SRV_NAME=$(ps_prefix)-source
  ps_sql "$SRV_CID" "CREATE USER 'replication'@'%' IDENTIFIED BY 'repl-Secret1';
    GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'replication'@'%';
    CREATE DATABASE pbs; CREATE TABLE pbs.t (id INT PRIMARY KEY, v VARCHAR(64));
    INSERT INTO pbs.t VALUES (1, 'one'), (2, 'two'); FLUSH BINARY LOGS; INSERT INTO pbs.t VALUES (3, 'three')"
  SRV_UUID=$(ps_sql "$SRV_CID" 'SELECT @@server_uuid')
  [ -n "$SRV_UUID" ]
}

# gtid_last: last transaction number of the source server (its gtid_executed is <uuid>:1-<n>)
gtid_last() { ps_sql "$SRV_CID" 'SELECT @@gtid_executed' | tr -d '\n' | sed -n "s/^$SRV_UUID:1-\([0-9]*\)$/\1/p"; }

@test "binlog server: version, usage, user, paths and the shipped config" {
  run pbs_run -- binlog_server version
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "$(vars_get "$VERSION_FILE" pbs_version)" ]
  run pbs_run -- /usr/bin/binlog_server
  [ "$status" -eq 1 ]
  [[ $output == *"usage: binlog_server (fetch|pull)"* ]]
  [[ $output == *"search_by_gtid_set <json_config_file> <gtid_set>"* ]]
  # Dockerfile: USER 1001 (pbs, group 0); the operator's search container uses /bin/sh -c, its entrypoint is bash
  # shellcheck disable=SC2016 # expanded in the container
  run pbs_run -- bash -c 'id -u; id -g; id -un; command -v sh bash tar; echo "$PBS_VERSION"'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 1001 ]
  [ "${lines[1]}" = 0 ]
  [ "${lines[2]}" = pbs ]
  [ "${#lines[@]}" -eq 7 ]
  [ "${lines[6]}" = "$(vars_get "$VERSION_FILE" pbs_version)-$(vars_get "$VERSION_FILE" pbs_release).wolfi" ]
  run pbs_run --user 0 -- bash -c 'stat -c "%n %u:%g %a" /var/lib/binlog-server /var/lib/binlog-server/buffer \
    /var/lib/binlog-server/data /var/log/binlog-server /etc/percona-binlog-server/main_config.json; ls /licenses'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "/var/lib/binlog-server 1001:1001 775" ]
  [ "${lines[1]}" = "/var/lib/binlog-server/buffer 1001:1001 775" ]
  [ "${lines[2]}" = "/var/lib/binlog-server/data 1001:1001 775" ]
  [ "${lines[3]}" = "/var/log/binlog-server 1001:1001 775" ]
  [ "${lines[4]}" = "/etc/percona-binlog-server/main_config.json 0:0 640" ]
  [ "${lines[5]}" = LICENSE.Dockerfile ]
}

@test "binlog server: a CA bundle mounted at the RHEL path (operator caBundle) becomes the trusted bundle" {
  printf '%s\n' '# test bundle' > "$CFG_DIR/ca.pem"
  chmod 644 "$CFG_DIR/ca.pem"
  run pbs_run -v "$CFG_DIR/ca.pem:/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem:ro" -- \
    cat /etc/ssl/certs/ca-certificates.crt
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = '# test bundle' ]
  # without the mount, both paths are Wolfi's bundle
  run pbs_run -- bash -c 'cmp /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/ssl/certs/ca-certificates.crt &&
    grep -c "BEGIN CERTIFICATE" /etc/ssl/certs/ca-certificates.crt'
  [ "$status" -eq 0 ]
  [ "$output" -gt 50 ]
}

@test "binlog server: fetch over TLS into a local directory storage; list and search_by_gtid_set" {
  net=$(ps_network pbs)
  source_server "$net"
  store=$(ps_volume store)
  write_config file.json "$SRV_NAME" file file:///var/lib/binlog-server/data
  cfg=(-v "$CFG_DIR/file.json:/etc/binlog_server/config/config.json:ro")
  run pbs_run --network "$net" "${cfg[@]}" -v "$store:/var/lib/binlog-server/data" -- \
    binlog_server fetch /etc/binlog_server/config/config.json
  echo "$output" | tail -n 20
  [ "$status" -eq 0 ]
  run pbs_run -v "$store:/var/lib/binlog-server/data" -- bash -c \
    'cd /var/lib/binlog-server/data && ls && head -c 4 binlog.000001 | od -An -tx1 | tr -d " \n"'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *binlog.000001* ]]
  [ "${lines[-1]}" = fe62696e ]
  run pbs_run "${cfg[@]}" -v "$store:/var/lib/binlog-server/data" -- binlog_server list /etc/binlog_server/config/config.json
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *'"status":"success"'* ]]
  [[ $output == *'"name":"binlog.000001"'* ]]
  [[ $output == *"$SRV_UUID"* ]]
  # the restore job's form (pkg/binlogserver SearchContainer): /bin/sh -c <script> binlog-search <output> <cmd...>
  # shellcheck disable=SC2016 # expanded by the container's sh
  script='output_path=$1
shift
if ! "$@" > "$output_path"; then
	cat "$output_path" >&2
	exit 1
fi
cat "$output_path"'
  run pbs_run "${cfg[@]}" -v "$store:/var/lib/binlog-server/data" -- /bin/sh -c "$script" binlog-search \
    /tmp/search.json /usr/bin/binlog_server search_by_gtid_set /etc/binlog_server/config/config.json "$SRV_UUID:1-3"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *'"status":"success"'* ]]
  [[ $output == *'binlog.000001'* ]]
}

@test "binlog server: pull streams new transactions into MinIO (S3 backend), as the operator runs it" {
  net=$(ps_network pbs)
  access=minio$RANDOM$RANDOM
  secret=secret$RANDOM$RANDOM$RANDOM
  mdata=$(ps_volume minio)
  # a directory in the data dir is a bucket
  ps_docker run --rm --user 0 -v "$mdata:/d" --entrypoint bash "$PBS_IMAGE" -c 'mkdir -p /d/binlogs && chmod -R 777 /d' > /dev/null
  minio=$(ps_prefix)-minio
  ps_track containers "$minio"
  ps_docker run -d --name "$minio" --network "$net" -e "MINIO_ROOT_USER=$access" -e "MINIO_ROOT_PASSWORD=$secret" \
    -v "$mdata:/data" "$(ps_tool_image minio)" server /data > /dev/null
  for _ in $(seq 1 60); do
    ps_docker run --rm --network "$net" --entrypoint bash "$PBS_IMAGE" -c \
      "exec 3<>/dev/tcp/$minio/9000 && printf 'GET /minio/health/live HTTP/1.1\\r\\nHost: $minio:9000\\r\\nConnection: close\\r\\n\\r\\n' >&3 && head -1 <&3 | grep -q ' 200'" \
      > /dev/null 2>&1 && break
    sleep 1
  done
  source_server "$net"
  write_config s3.json "$SRV_NAME" s3 "http://$access:$secret@$minio:9000/binlogs/cluster1"
  cfg=(-v "$CFG_DIR/s3.json:/etc/binlog_server/config/config.json:ro")
  buf=$(ps_volume buffer)
  ps_docker run --rm --user 0 -v "$buf:/b" --entrypoint bash "$PBS_IMAGE" -c 'chown 1001:0 /b' > /dev/null
  pull=$(ps_prefix)-pull
  ps_track containers "$pull"
  ps_docker run -d --name "$pull" --network "$net" "${cfg[@]}" -v "$buf:/var/lib/binlogsrv" "$PBS_IMAGE" \
    /usr/bin/binlog_server pull /etc/binlog_server/config/config.json > /dev/null

  # list_s3: the storage as the restore jobs see it
  list_s3() { pbs_run --network "$net" "${cfg[@]}" -- binlog_server list /etc/binlog_server/config/config.json; }
  # wait_gtid <n>: the storage has the source's transactions up to <n>
  wait_gtid() {
    local i out
    for i in $(seq 1 60); do
      out=$(list_s3) || true
      [[ $out == *"$SRV_UUID:1-$1\""* ]] && return 0
      sleep 2
    done
    echo "storage never reached $SRV_UUID:1-$1; last list: $out" >&2
    ps_docker logs "$pull" 2>&1 | tail -n 30 >&2
    return 1
  }
  wait_gtid "$(gtid_last)"
  # a transaction committed while pull runs reaches the storage
  ps_sql "$SRV_CID" "INSERT INTO pbs.t VALUES (4, 'four'), (5, 'five'); FLUSH BINARY LOGS; INSERT INTO pbs.t VALUES (6, 'six')"
  n=$(gtid_last)
  wait_gtid "$n"
  run list_s3
  echo "$output"
  [[ $output == *'"status":"success"'* ]]
  [[ $output == *'"name":"binlog.000001"'* ]]
  # still running, then a clean stop on SIGTERM
  [ "$(ps_docker inspect -f '{{.State.Running}}' "$pull")" = true ]
  ps_docker stop -t 30 "$pull" > /dev/null
  echo "# pull exit code: $(ps_docker inspect -f '{{.State.ExitCode}}' "$pull")" >&3
  run ps_docker logs "$pull"
  [[ $output != *"ERROR"* ]] || { echo "$output" | grep ERROR; false; }
}
