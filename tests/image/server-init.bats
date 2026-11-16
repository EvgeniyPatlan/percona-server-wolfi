#!/usr/bin/env bats
# Entrypoint initialisation behaviour of the -dev image (docker-entrypoint.sh = official ps-entry.sh + Wolfi patches).
# Needs IMAGE (default localhost:5000/percona-server:9.7-dev) and a docker daemon; see docs/BUILD-HOST.md.

# The images under test come from the registry (apko publishes there, nothing is in the local docker): pull them once;
# a failed pull fails every test of the suite instead of skipping it.
setup_file() {
  load helpers
  ps_pull_images "$PS_IMAGE"
}

setup() {
  load helpers
  ps_require_dev
  unset PS_SQL_USER PS_SQL_PASSWORD
}

teardown() {
  ps_cleanup
}

@test "MYSQL_ROOT_PASSWORD: root logs in with it" {
  cid=$(ps_start rootpw -e MYSQL_ROOT_PASSWORD=x)
  ps_wait_ready "$cid"
  PS_SQL_PASSWORD=x run ps_sql "$cid" 'SELECT 1'
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  # a wrong password must be refused
  PS_SQL_PASSWORD=wrong run ps_sql "$cid" 'SELECT 1'
  [ "$status" -ne 0 ]
}

@test "MYSQL_RANDOM_ROOT_PASSWORD: generated password is logged and works" {
  cid=$(ps_start random -e MYSQL_RANDOM_ROOT_PASSWORD=yes)
  ps_wait_ready "$cid"
  line=$(ps_logs "$cid" | grep -m1 'GENERATED ROOT PASSWORD:')
  [ -n "$line" ]
  pw=${line#*GENERATED ROOT PASSWORD: }
  # od-based generator (docs/deviations.md): 24 bytes as hex
  [[ $pw =~ ^[0-9a-f]{48}$ ]]
  PS_SQL_PASSWORD=$pw run ps_sql "$cid" 'SELECT 1'
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
}

@test "MYSQL_ALLOW_EMPTY_PASSWORD: root logs in without a password" {
  cid=$(ps_start empty -e MYSQL_ALLOW_EMPTY_PASSWORD=yes)
  ps_wait_ready "$cid"
  run ps_sql "$cid" 'SELECT 1'
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
}

@test "MYSQL_ONETIME_PASSWORD: root@% password is expired" {
  cid=$(ps_start onetime -e MYSQL_ROOT_PASSWORD=x -e MYSQL_ONETIME_PASSWORD=yes)
  ps_wait_ready "$cid"
  PS_SQL_PASSWORD=x run ps_sql "$cid" "SELECT password_expired FROM mysql.user WHERE user='root' AND host='%'"
  [ "$status" -eq 0 ]
  [ "$output" = Y ]
}

@test "MYSQL_DATABASE/MYSQL_USER/MYSQL_PASSWORD: the user can USE the database" {
  cid=$(ps_start user -e MYSQL_ROOT_PASSWORD=x -e MYSQL_DATABASE=db -e MYSQL_USER=u -e MYSQL_PASSWORD=p)
  ps_wait_ready "$cid"
  PS_SQL_USER=u PS_SQL_PASSWORD=p run ps_sql "$cid" 'USE db; SELECT DATABASE()'
  [ "$status" -eq 0 ]
  [ "$output" = db ]
}

@test "/docker-entrypoint-initdb.d: .sql, .sql.gz and .sh run in name order" {
  d=$BATS_TEST_TMPDIR/initdb
  mkdir -p "$d"
  cat > "$d/a.sql" <<'SQL'
CREATE DATABASE initdb;
CREATE TABLE initdb.t (id INT AUTO_INCREMENT PRIMARY KEY, src VARCHAR(8));
INSERT INTO initdb.t (src) VALUES ('a');
SQL
  printf "INSERT INTO initdb.t (src) VALUES ('b');\n" | gzip -c > "$d/b.sql.gz"
  # sourced by the entrypoint: ${mysql[@]} is the client command line
  printf '%s\n' "echo \"INSERT INTO initdb.t (src) VALUES ('c');\" | \"\${mysql[@]}\"" > "$d/c.sh"
  chmod 755 "$d"
  chmod 644 "$d"/*
  cid=$(ps_start initdb -e MYSQL_ROOT_PASSWORD=x -v "$d:/docker-entrypoint-initdb.d:ro")
  ps_wait_ready "$cid"
  PS_SQL_PASSWORD=x run ps_sql "$cid" 'SELECT GROUP_CONCAT(src ORDER BY id) FROM initdb.t'
  [ "$status" -eq 0 ]
  [ "$output" = a,b,c ]
}

@test "no password option on an empty datadir: exits non-zero with the official error text" {
  # the text is the one in the pinned percona-docker ps-entry.sh (commit 9139159); check the image still has it
  want='error: database is uninitialized and password option is not specified'
  want2='You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
  c=$(ps_docker create --name "$(ps_prefix)-script" "$PS_IMAGE")
  ps_track containers "$(ps_prefix)-script"
  ps_docker cp "$c:/docker-entrypoint.sh" "$BATS_TEST_TMPDIR/entry.sh"
  grep -qF "$want" "$BATS_TEST_TMPDIR/entry.sh"
  grep -qF "$want2" "$BATS_TEST_TMPDIR/entry.sh"
  cid=$(ps_start nopw)
  run ps_wait_exit "$cid" 60
  [ "$status" -eq 0 ]
  [ "$output" -ne 0 ]
  logs=$(ps_logs "$cid")
  [[ $logs == *"$want"* ]]
  [[ $logs == *"$want2"* ]]
}

@test "MYSQL_INIT_ONLY: exits 0 after initialisation" {
  cid=$(ps_start initonly -e MYSQL_ROOT_PASSWORD=x -e MYSQL_INIT_ONLY=1)
  run ps_wait_exit "$cid" 180
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
  ps_logs "$cid" | grep -q 'Initialization complete, now exiting!'
}

@test "--user 4242:0 on an empty volume: initialises and serves queries" {
  vol=$(ps_volume arbuid)
  cid=$(ps_start arbuid --user 4242:0 -v "$vol:/var/lib/mysql" -e MYSQL_ROOT_PASSWORD=x)
  ps_wait_ready "$cid"
  PS_SQL_PASSWORD=x run ps_sql "$cid" 'SELECT 1'
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  run ps_peek "$cid" sh -c "stat -c %u /proc/1"
  [ "$output" = 4242 ]
  # restart on the same volume with the same arbitrary uid, no env
  ps_docker stop "$cid" > /dev/null
  ps_rm "$cid"
  cid=$(ps_start arbuid2 --user 4242:0 -v "$vol:/var/lib/mysql")
  ps_wait_ready "$cid"
  PS_SQL_PASSWORD=x run ps_sql "$cid" 'SELECT 1'
  [ "$output" = 1 ]
}
