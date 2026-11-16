#!/usr/bin/env bats
# XtraBackup image round trips, the way the Percona Operator for MySQL uses it: the xtrabackup container mounts the
# server's datadir volume (uid 1001) and connects to the running server over its network namespace.
# Fixture: tests/fixtures/make-upgrade-datadir.sh builds the datadir (InnoDB 1000 rows, RocksDB, keyring-encrypted
# table, ...) with the image under test, so the checksums of the restored server can be compared with upgrade-lib.bash.
#
# Environment: IMAGE (the -dev server image), PXB_IMAGE (default localhost:5000/percona-xtrabackup:9.7),
# OFFICIAL_PXB_IMAGE / OFFICIAL_PS_IMAGE (default: the digests of versions/9.7.yaml; pulled by the cross tests only).

# The images under test come from the registry (apko publishes there, nothing is in the local docker): pull them once;
# a failed pull fails every test of the suite instead of skipping it.
setup_file() {
  load helpers
  # shellcheck disable=SC2153 # PS_IMAGE comes from helpers.bash
  ps_pull_images "$PS_IMAGE" "${PXB_IMAGE:-localhost:5000/percona-xtrabackup:9.7}"
}

setup() {
  load helpers
  load xb-lib
  ps_require_dev
  unset PS_SQL_USER
  export PS_SQL_PASSWORD=x
  # shellcheck source=../fixtures/upgrade-lib.bash
  source "$PS_ROOT/tests/fixtures/upgrade-lib.bash"
  VERSION_FILE=${VERSION_FILE:-$PS_ROOT/versions/9.7.yaml}
  PXB_IMAGE=${PXB_IMAGE:-localhost:5000/percona-xtrabackup:9.7}
  OFFICIAL_PXB_IMAGE=${OFFICIAL_PXB_IMAGE:-$(vars_get "$VERSION_FILE" official_pxb_image)}
  OFFICIAL_PS_IMAGE=${OFFICIAL_PS_IMAGE:-$(vars_get "$VERSION_FILE" official_ps_image)}
  KR=--component-keyring-config=/var/lib/mysql/component_keyring_file.cnf
}

teardown() {
  ps_cleanup
}

wolfi_sql() { ps_sql "$WOLFI_CID" "$1"; }

# pxb_run <image> [docker args...] -- <bash script>: run the script in the xtrabackup image as uid 1001, entrypoint
# bypassed (bash), telemetry off; output of the script (both streams) is printed, failure shows it on stderr.
pxb_run() {
  local img=$1 out
  shift
  local -a dargs=()
  while (($#)) && [[ $1 != -- ]]; do
    dargs+=("$1")
    shift
  done
  shift
  out=$(ps_docker run --rm --user 1001 -e PERCONA_TELEMETRY_DISABLE=1 "${dargs[@]}" --entrypoint bash "$img" -o pipefail -ec "$1" 2>&1) || {
    # the script may carry the generated MinIO secret: never print it
    out=${out//"${XB_MASK:-@@none@@}"/***}
    printf '%s\n' "$out" >&2
    return 1
  }
  printf '%s\n' "$out"
}

# pxb_ok: pxb_run, and the output must contain xtrabackup's "completed OK!"
pxb_ok() {
  local out
  out=$(pxb_run "$@") || return 1
  printf '%s\n' "$out" | xb_completed_ok || {
    printf '%s\n' "$out" >&2
    echo "pxb_ok: no 'completed OK!' in the output" >&2
    return 1
  }
}

# minio_live <network> <ip>: MinIO health endpoint answers 200, probed with bash /dev/tcp from a separate container
# (the xtrabackup image's own tools are not assumed). HTTP/1.1 with a Host header: current MinIO answers 400 without one.
minio_live() {
  ps_docker run --rm --network "$1" --entrypoint bash "$PXB_IMAGE" -c \
    "exec 3<>/dev/tcp/$2/9000 && printf 'GET /minio/health/live HTTP/1.1\\r\\nHost: $2:9000\\r\\nConnection: close\\r\\n\\r\\n' >&3 && head -1 <&3 | grep -q ' 200'" > /dev/null 2>&1
}

# log_versions <pxb-image>: xtrabackup and server versions, for cross-test diagnostics
log_versions() {
  echo "# xtrabackup: $(pxb_run "$1" -- 'xtrabackup --version 2>&1 | tail -1')" >&3
  echo "# server: $(ps_sql "$SRV_CID" 'SELECT VERSION()')" >&3
}

# new_volume <name>: empty volume owned by uid 1001
new_volume() {
  local v
  v=$(ps_volume "$1") || return 1
  ps_docker run --rm --user 0 -v "$v:/d" --entrypoint bash "$PXB_IMAGE" -c 'chown 1001:0 /d && chmod 775 /d' > /dev/null || return 1
  printf '%s\n' "$v"
}

# make_server <server-image> [network]: datadir volume from the fixture (written by <server-image>) and a running
# server on it. Sets SRV_VOL, SRV_CID, EXPECT.
make_server() {
  local img=$1 net=${2:-}
  SRV_VOL=$(ps_volume data)
  ps_track containers "$SRV_VOL-fixture"
  DOCKER=${DOCKER:-docker} "$PS_ROOT/tests/fixtures/make-upgrade-datadir.sh" "$img" "$SRV_VOL"
  EXPECT=$PS_ROOT/out/results/upgrade-$SRV_VOL.expect
  [ -s "$EXPECT" ]
  local -a netargs=()
  [[ -z $net ]] || netargs=(--network "$net")
  SRV_CID=$(PS_IMAGE=$img ps_start server "${netargs[@]}" -e MYSQL_ROOT_PASSWORD=x -v "$SRV_VOL:/var/lib/mysql" -v "$KEYRING_GLOBAL_MOUNT")
  PS_IMAGE=$img ps_wait_ready "$SRV_CID" 300
}

# backup_args: options every xtrabackup --backup run needs; extra args (server version check) from $1
backup_args() {
  printf '%s' "--backup --host=127.0.0.1 --user=root --password=x --datadir=/var/lib/mysql $KR $*"
}

# copy_state <src-volume> <dst-volume>: keyring manifest, config and data are not part of a backup (the operator
# mounts them from secrets); copy them next to the restored datadir
copy_keyring() {
  ps_docker run --rm --user 1001 -v "$1:/src:ro" -v "$2:/var/lib/mysql" --entrypoint bash "$PXB_IMAGE" \
    -ec 'cp -p /src/mysqld.my /src/component_keyring_file.cnf /src/component_keyring_file.data /var/lib/mysql/' > /dev/null
}

# verify_restored <data-volume>: start the Wolfi server on it and compare every fixture checksum
verify_restored() {
  local cid actual=$BATS_TEST_TMPDIR/actual
  cid=$(ps_start restored -e MYSQL_ROOT_PASSWORD=x -v "$1:/var/lib/mysql" -v "$KEYRING_GLOBAL_MOUNT")
  ps_wait_ready "$cid" 300
  WOLFI_CID=$cid
  upgrade_state wolfi_sql > "$actual"
  run xb_restore_state_matches "$EXPECT" "$actual"
  echo "$output"
  if ((status != 0)); then
    echo "# restored server log (keyring, component, encryption lines):"
    ps_logs "$cid" | grep -iE 'keyring|component|encrypt|manifest' || true
    return 1
  fi
  # explicit assertions so an empty expectation cannot pass
  [ "$(expect_get "$actual" rows.innodb)" = 1000 ]
  [ "$(expect_get "$actual" encrypted.option)" = 1 ]
  run wolfi_sql 'SELECT COUNT(*) FROM up.t_rocksdb'
  [ "$output" = 100 ]
  run wolfi_sql 'SELECT COUNT(*) FROM up.t_encrypted'
  [ "$output" = 100 ]
}

# stop_server: clean stop so the volume is free for prepare (the keyring file is read from it)
stop_server() { ps_docker stop -t 120 "$SRV_CID" > /dev/null; }

@test "xtrabackup: backup, prepare, copy-back; restored server has equal checksums (InnoDB, RocksDB, encrypted)" {
  # shellcheck disable=SC2153 # PS_IMAGE comes from helpers.bash
  make_server "$PS_IMAGE"
  bk=$(new_volume backup)
  prep=$(new_volume prepared)
  out=$(new_volume restored)

  pxb_ok "$PXB_IMAGE" --network "container:$SRV_CID" -v "$SRV_VOL:/var/lib/mysql" -v "$bk:/backup" -- \
    "xtrabackup $(backup_args) --target-dir=/backup/full"
  stop_server
  # prepare in a separate volume
  pxb_run "$PXB_IMAGE" -v "$bk:/src:ro" -v "$prep:/backup" -- 'cp -a /src/full /backup/full'
  pxb_ok "$PXB_IMAGE" -v "$SRV_VOL:/var/lib/mysql" -v "$prep:/backup" -- \
    "xtrabackup --prepare $KR --target-dir=/backup/full"
  # copy-back into an empty volume
  pxb_ok "$PXB_IMAGE" -v "$prep:/backup" -v "$out:/var/lib/mysql" -- \
    'xtrabackup --copy-back --target-dir=/backup/full --datadir=/var/lib/mysql'
  copy_keyring "$SRV_VOL" "$out"
  verify_restored "$out"
}

# stream_roundtrip <algo>: xbstream with --compress=<algo> -> extract -> decompress -> prepare
stream_roundtrip() {
  local algo=$1 bk prep
  # shellcheck disable=SC2153 # PS_IMAGE comes from helpers.bash
  make_server "$PS_IMAGE"
  bk=$(new_volume stream)
  prep=$(new_volume prepared)
  pxb_ok "$PXB_IMAGE" --network "container:$SRV_CID" -v "$SRV_VOL:/var/lib/mysql" -v "$bk:/backup" -- \
    "xtrabackup $(backup_args) --stream=xbstream --compress=$algo --target-dir=/tmp/xb > /backup/full.xbstream"
  [ "$(pxb_run "$PXB_IMAGE" -v "$bk:/backup:ro" -- 'stat -c %s /backup/full.xbstream')" -gt 0 ]
  stop_server
  pxb_run "$PXB_IMAGE" -v "$bk:/src:ro" -v "$prep:/backup" -- 'mkdir /backup/full && xbstream -x -C /backup/full < /src/full.xbstream'
  # compressed files are present after the extract (.zst / .lz4)
  run pxb_run "$PXB_IMAGE" -v "$prep:/backup:ro" -- "find /backup/full -name '*.$([[ $algo == zstd ]] && echo zst || echo lz4)' | head -3"
  echo "$output"
  [ -n "$output" ]
  pxb_ok "$PXB_IMAGE" -v "$prep:/backup" -- 'xtrabackup --decompress --remove-original --target-dir=/backup/full'
  pxb_ok "$PXB_IMAGE" -v "$SRV_VOL:/var/lib/mysql" -v "$prep:/backup" -- \
    "xtrabackup --prepare $KR --target-dir=/backup/full"
}

@test "xtrabackup: --stream=xbstream --compress=zstd, extract, decompress, prepare" {
  stream_roundtrip zstd
}

@test "xtrabackup: --stream=xbstream --compress=lz4, extract, decompress, prepare" {
  stream_roundtrip lz4
}

@test "xbcloud: put to and get from MinIO, restored backup prepares" {
  net=$(ps_network xbcloud)
  access=$(rand_secret 16)
  secret=$(rand_secret 32)
  XB_MASK=$secret
  mdata=$(ps_volume minio)
  # a directory in the data dir is a bucket
  ps_docker run --rm --user 0 -v "$mdata:/d" --entrypoint bash "$PXB_IMAGE" -c 'mkdir -p /d/xbtest && chmod -R 777 /d' > /dev/null
  minio=$(ps_prefix)-minio
  ps_track containers "$minio"
  ps_docker run -d --name "$minio" --network "$net" -e "MINIO_ROOT_USER=$access" -e "MINIO_ROOT_PASSWORD=$secret" \
    -v "$mdata:/data" "$(ps_tool_image minio)" server /data > /dev/null
  ip=$(ps_docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$minio")
  [ -n "$ip" ]
  for _ in $(seq 1 60); do
    minio_live "$net" "$ip" && break
    sleep 1
  done
  minio_live "$net" "$ip"

  make_server "$PS_IMAGE" "$net"
  mapfile -t s3 < <(xbcloud_s3_args "http://$ip:9000" xbtest "$access" "$secret")
  prep=$(new_volume prepared)
  pxb_ok "$PXB_IMAGE" --network "container:$SRV_CID" -v "$SRV_VOL:/var/lib/mysql" -- \
    "xtrabackup $(backup_args) --stream=xbstream --target-dir=/tmp/xb | xbcloud put ${s3[*]} cloud-full"
  stop_server
  pxb_run "$PXB_IMAGE" --network "$net" -v "$prep:/backup" -- \
    "mkdir /backup/full && xbcloud get ${s3[*]} cloud-full | xbstream -x -C /backup/full"
  pxb_ok "$PXB_IMAGE" -v "$SRV_VOL:/var/lib/mysql" -v "$prep:/backup" -- \
    "xtrabackup --prepare $KR --target-dir=/backup/full"
}

@test "cross: Wolfi xtrabackup backs up and prepares an official server datadir" {
  ps_docker pull "$OFFICIAL_PS_IMAGE" > /dev/null
  make_server "$OFFICIAL_PS_IMAGE"
  prep=$(new_volume prepared)
  log_versions "$PXB_IMAGE"
  # the official server may be newer than our xtrabackup build: skip the version check
  pxb_ok "$PXB_IMAGE" --network "container:$SRV_CID" -v "$SRV_VOL:/var/lib/mysql" -v "$prep:/backup" -- \
    "xtrabackup $(backup_args --no-server-version-check) --target-dir=/backup/full"
  stop_server
  pxb_ok "$PXB_IMAGE" -v "$SRV_VOL:/var/lib/mysql" -v "$prep:/backup" -- \
    "xtrabackup --prepare $KR --target-dir=/backup/full"
}

@test "cross: official xtrabackup backs up and prepares a Wolfi server datadir" {
  ps_docker pull "$OFFICIAL_PXB_IMAGE" > /dev/null
  # shellcheck disable=SC2153 # PS_IMAGE comes from helpers.bash
  make_server "$PS_IMAGE"
  prep=$(new_volume prepared)
  log_versions "$OFFICIAL_PXB_IMAGE"
  pxb_ok "$OFFICIAL_PXB_IMAGE" --network "container:$SRV_CID" -v "$SRV_VOL:/var/lib/mysql" -v "$prep:/backup" -- \
    "xtrabackup $(backup_args --no-server-version-check) --target-dir=/backup/full"
  stop_server
  pxb_ok "$OFFICIAL_PXB_IMAGE" -v "$SRV_VOL:/var/lib/mysql" -v "$prep:/backup" -- \
    "xtrabackup --prepare $KR --target-dir=/backup/full"
}
