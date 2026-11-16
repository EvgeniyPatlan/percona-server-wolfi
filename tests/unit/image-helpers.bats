#!/usr/bin/env bats
# Unit tests for tests/image/helpers.bash with a stub DOCKER (no docker daemon needed).

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  TMP=$BATS_TEST_TMPDIR
  export STUB_LOG=$TMP/docker.log
  export STUB_PINGS=$TMP/pings
  : > "$STUB_LOG"
  cat > "$TMP/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case $1 in
  run) echo cid-abc123 ;;
  inspect)
    if [[ $* == *ExitCode* ]]; then echo 3; elif [[ ${STUB_RUNNING:-true} == false ]]; then echo false; else echo true; fi ;;
  exec)
    if [[ " $* " == *" mysqladmin "* ]]; then
      n=$(cat "$STUB_PINGS" 2>/dev/null || echo 0)
      echo $((n + 1)) > "$STUB_PINGS"
      [[ $n -ge ${STUB_PING_AFTER:-0} ]]
    elif [[ " $* " == *" mysql "* ]]; then
      [[ ${STUB_SQL_FAIL:-} == 1 ]] && { echo "ERROR 1045 denied" >&2; exit 1; }
      printf 'row1\nrow2\n'
      echo "mysql: [Warning] noise" >&2
    fi ;;
  logs) echo "line1"; echo "line2" >&2 ;;
  pull) [[ " ${STUB_PULL_FAIL:-} " != *" $2 "* ]] || { echo "pull failed: $2" >&2; exit 1; } ;;
  image) [[ " ${STUB_INSPECT_FAIL:-} " != *" ${*: -1} "* ]] || { echo "No such image" >&2; exit 1; } ;;
esac
STUB
  chmod +x "$TMP/docker"
  export DOCKER=$TMP/docker
  export IMAGE=example.com/ps:test
  export PS_POLL_INTERVAL=0
  export BATS_TEST_NUMBER=7
  load "$ROOT/tests/image/helpers"
}

@test "ps_start prefixes the name, appends the image, passes args and the command after --" {
  run ps_start db -e A=1 -v v:/var/lib/mysql -- --innodb-ft-min-token-size=1
  [ "$status" -eq 0 ]
  [ "$output" = cid-abc123 ]
  grep -q "^run -d --name psw-[0-9]*-7-db -e A=1 -v v:/var/lib/mysql example.com/ps:test --innodb-ft-min-token-size=1\$" "$STUB_LOG"
  grep -q 'psw-[0-9]*-7-db' "$PS_STATE_DIR/containers"
}

@test "ps_start without a command" {
  run ps_start db
  [ "$status" -eq 0 ]
  grep -q "^run -d --name psw-[0-9]*-7-db example.com/ps:test\$" "$STUB_LOG"
}

@test "ps_start honours a per-call PS_IMAGE" {
  PS_IMAGE=other/img:1 run ps_start x
  grep -q ' other/img:1$' "$STUB_LOG"
}

@test "ps_wait_ready polls until ping succeeds" {
  export STUB_PING_AFTER=3
  run ps_wait_ready cid1 30
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_PINGS")" -eq 4 ]
  grep -q 'exec cid1 mysqladmin --no-defaults --protocol=tcp -h127.0.0.1 -uroot ping' "$STUB_LOG"
}

@test "ps_wait_ready fails fast when the container is not running and shows its logs" {
  export STUB_RUNNING=false
  run ps_wait_ready cid1 30
  [ "$status" -eq 1 ]
  [[ $output == *"not running"* ]]
  [[ $output == *line1* ]]
  [ ! -s "$STUB_PINGS" ]
}

@test "ps_wait_ready times out" {
  export STUB_PING_AFTER=100000
  run ps_wait_ready cid1 1
  [ "$status" -eq 1 ]
  [[ $output == *"not ready after 1s"* ]]
}

@test "ps_sql runs the client with -N -B, the password in MYSQL_PWD, and hides stderr noise on success" {
  PS_SQL_PASSWORD=secret run ps_sql cid1 'SELECT 1'
  [ "$status" -eq 0 ]
  [ "$output" = $'row1\nrow2' ]
  grep -q 'exec -i -e MYSQL_PWD=secret cid1 mysql --no-defaults -N -B -uroot -e SELECT 1' "$STUB_LOG"
}

@test "ps_sql user override and failure shows the client error" {
  export STUB_SQL_FAIL=1
  PS_SQL_USER=u run ps_sql cid1 'SELECT 1'
  [ "$status" -eq 1 ]
  [[ $output == *"ERROR 1045"* ]]
  grep -q -- '-uu -e' "$STUB_LOG"
}

@test "ps_logs merges both streams" {
  run ps_logs cid1
  [[ $output == *line1* && $output == *line2* ]]
  grep -q '^logs cid1$' "$STUB_LOG"
}

@test "ps_rm force-removes with volumes" {
  run ps_rm cid1
  [ "$status" -eq 0 ]
  grep -q '^rm -f -v cid1$' "$STUB_LOG"
}

@test "ps_cleanup removes tracked containers, networks, volumes (in that order) and never fails" {
  ps_start a > /dev/null
  ps_network n > /dev/null
  ps_volume v > /dev/null
  : > "$STUB_LOG"
  run ps_cleanup
  [ "$status" -eq 0 ]
  run cat "$STUB_LOG"
  [[ ${lines[0]} == "rm -f -v psw-"*"-7-a" ]]
  [[ ${lines[1]} == "network rm psw-"*"-7-n" ]]
  [[ ${lines[2]} == "volume rm -f psw-"*"-7-v" ]]
  # a second call has nothing left to do
  : > "$STUB_LOG"
  ps_cleanup
  [ ! -s "$STUB_LOG" ]
}

@test "ps_image_pair derives the distroless name from the -dev image and vice versa" {
  PS_IMAGE=r/p:9.7-dev
  ps_image_pair
  [ "$PS_IMAGE_DEV" = r/p:9.7-dev ]
  [ "$PS_IMAGE_DISTROLESS" = r/p:9.7 ]
  unset PS_IMAGE_DEV PS_IMAGE_DISTROLESS
  PS_IMAGE=r/p:9.7
  ps_image_pair
  [ "$PS_IMAGE_DEV" = r/p:9.7-dev ]
}

@test "ps_wait_exit prints the exit code of a stopped container" {
  export STUB_RUNNING=false
  run ps_wait_exit cid1 5
  [ "$status" -eq 0 ]
  [ "$output" = 3 ]
  grep -q "inspect -f {{.State.ExitCode}} cid1" "$STUB_LOG"
}

@test "ps_image_kind: by tag (-dev suffix), PS_IMAGE_KIND overrides, digest-only refs need PS_IMAGE_KIND" {
  run ps_image_kind localhost:5000/percona-server:9.7-dev
  [ "$output" = dev ]
  run ps_image_kind localhost:5000/percona-server:9.7
  [ "$output" = distroless ]
  run ps_image_kind localhost:5000/percona-server:9.7.2-2-dev@sha256:abc
  [ "$output" = dev ]
  run ps_image_kind localhost:5000/percona-server@sha256:abc
  [ "$status" -eq 1 ]
  [[ $output == *PS_IMAGE_KIND* ]]
  PS_IMAGE=localhost:5000/percona-server@sha256:abc PS_IMAGE_KIND=dev run ps_image_kind
  [ "$output" = dev ]
  PS_IMAGE=r/p:9.7 PS_IMAGE_KIND=bogus run ps_image_kind
  [ "$status" -eq 1 ]
  # never asks docker
  [ ! -s "$STUB_LOG" ]
}

@test "ps_require_dev: skips only for an image named distroless, fails when the kind is unknown" {
  PS_IMAGE=r/p:9.7-dev run ps_require_dev
  [ "$status" -eq 0 ]
  PS_IMAGE=r/p@sha256:abc run ps_require_dev
  [ "$status" -eq 1 ]
  # inspect failures no longer turn into a skip: docker is not consulted at all
  STUB_INSPECT_FAIL=r/p:9.7-dev PS_IMAGE=r/p:9.7-dev run ps_require_dev
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
}

@test "ps_pull_images pulls and inspects every ref; any failure is an error" {
  run ps_pull_images r/a:1 r/b:2
  [ "$status" -eq 0 ]
  grep -qx 'pull r/a:1' "$STUB_LOG"
  grep -qx 'pull r/b:2' "$STUB_LOG"
  grep -qx 'image inspect r/b:2' "$STUB_LOG"
  STUB_PULL_FAIL=r/b:2 run ps_pull_images r/a:1 r/b:2
  [ "$status" -eq 1 ]
  [[ $output == *"cannot pull r/b:2"* ]]
  STUB_INSPECT_FAIL=r/a:1 run ps_pull_images r/a:1
  [ "$status" -eq 1 ]
  # PS_PULL=0: no pull (images loaded by hand), but the image must still be present
  : > "$STUB_LOG"
  PS_PULL=0 run ps_pull_images r/a:1
  [ "$status" -eq 0 ]
  run grep -q '^pull' "$STUB_LOG"; [ "$status" -ne 0 ]
  STUB_INSPECT_FAIL=r/a:1 PS_PULL=0 run ps_pull_images r/a:1
  [ "$status" -eq 1 ]
  run ps_pull_images
  [ "$status" -eq 1 ]
}
