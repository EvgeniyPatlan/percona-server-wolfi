#!/usr/bin/env bats
# MySQL Shell in the -dev image, as the Percona Operator for MySQL uses it (mysqlsh --js): a three-member group
# replication cluster built with dba.createCluster/addInstance, and util.dumpInstance / util.loadDump.
# Needs IMAGE (the -dev image) and a docker daemon; no other images, no network access.

# The images under test come from the registry (apko publishes there, nothing is in the local docker): pull them once;
# a failed pull fails every test of the suite instead of skipping it.
setup_file() {
  load helpers
  ps_pull_images "$PS_IMAGE"
}

setup() {
  load helpers
  load gr-lib
  ps_require_dev
  unset PS_SQL_USER
  export PS_SQL_PASSWORD=x
}

teardown() {
  ps_cleanup
}

# sh_js <container> <host> <js>: run JavaScript in mysqlsh inside <container>, connected to root@<host>.
# HOME of uid 1001 does not exist, so the shell's config directory goes to /tmp.
sh_js() {
  ps_docker exec -e MYSQLSH_USER_CONFIG_HOME=/tmp "$1" \
    mysqlsh --js --no-wizard --uri "root:x@$2:3306" -e "$3"
}

# gr_member <net> <n>: start group replication member <n> (ready, root@% with password x); prints the container id
gr_member() {
  local name=n$2 full cid
  full=$(ps_prefix)-$name
  local -a args
  mapfile -t args < <(gr_mysqld_args "$2" "$full")
  cid=$(ps_start "$name" --network "$1" --hostname "$full" -e MYSQL_ROOT_PASSWORD=x -e 'MYSQL_ROOT_HOST=%' -- "${args[@]}") || return 1
  ps_wait_ready "$cid" 180 || return 1
  printf '%s\n' "$cid"
}

@test "mysqlsh: runs in JS mode and reports its version" {
  run ps_docker run --rm --entrypoint mysqlsh -e MYSQLSH_USER_CONFIG_HOME=/tmp "$PS_IMAGE" --js -e 'print("v=" + shell.version + "\n")'
  echo "$output"
  [ "$status" -eq 0 ]
  # shell.version is "Ver <x.y.z> for Linux on ... - for MySQL ..."
  [[ $output == *"v=Ver $(vars_get "${VERSION_FILE:-$PS_ROOT/versions/9.7.yaml}" mysqlsh_tag) "* ]]
  # the bundled plugins load (a failure is only a warning on stdout; Python modules such as certifi and yaml)
  [[ $output != *"errors loading plugins"* ]]
}

@test "mysqlsh: dba.createCluster + addInstance x2 gives 3 ONLINE members" {
  net=$(ps_network gr)
  c1=$(gr_member "$net" 1)
  c2=$(gr_member "$net" 2)
  c3=$(gr_member "$net" 3)
  h1=$(ps_prefix)-n1 h2=$(ps_prefix)-n2 h3=$(ps_prefix)-n3

  for h in "$h1:$c1" "$h2:$c2" "$h3:$c3"; do
    run sh_js "$c1" "${h%%:*}" "dba.configureInstance('root:x@${h%%:*}:3306', {restart: false})"
    echo "$output"
    [ "$status" -eq 0 ]
  done

  # entrypoint initialisation leaves local GTIDs; clear them so incremental recovery sees no errant transactions
  for c in "$c1" "$c2" "$c3"; do
    ps_sql "$c" 'RESET BINARY LOGS AND GTIDS'
  done

  run sh_js "$c1" "$h1" "var c = dba.createCluster('c', {gtidSetIsComplete: true}); print('created ' + c.getName() + '\n')"
  echo "$output"
  [ "$status" -eq 0 ]
  for h in "$h2" "$h3"; do
    run sh_js "$c1" "$h1" "dba.getCluster('c').addInstance('root:x@$h:3306', {recoveryMethod: 'incremental'})"
    echo "$output"
    [ "$status" -eq 0 ]
  done

  # members become ONLINE asynchronously after addInstance returns
  n=0
  for _ in $(seq 1 60); do
    n=$(sh_js "$c1" "$h1" "$(gr_online_js)" | gr_online_count) || n=0
    [ "$n" = 3 ] && break
    sleep 2
  done
  run sh_js "$c1" "$h1" 'print(JSON.stringify(dba.getCluster().status()))'
  echo "# final status: $output" >&3
  [ "$n" = 3 ]

  # a write on the primary reaches the other members
  ps_sql "$c1" 'CREATE DATABASE gr; CREATE TABLE gr.t (id INT PRIMARY KEY); INSERT INTO gr.t VALUES (1),(2),(3)'
  for c in "$c2" "$c3"; do
    for _ in $(seq 1 30); do
      [ "$(ps_sql "$c" 'SELECT COUNT(*) FROM gr.t' 2> /dev/null || true)" = 3 ] && break
      sleep 1
    done
    run ps_sql "$c" 'SELECT COUNT(*) FROM gr.t'
    [ "$output" = 3 ]
  done
}

@test "mysqlsh: util.dumpInstance and util.loadDump keep row counts" {
  net=$(ps_network dump)
  dumpvol=$(ps_volume dump)
  src=$(ps_start src --network "$net" --hostname "$(ps_prefix)-src" -e MYSQL_ROOT_PASSWORD=x -e 'MYSQL_ROOT_HOST=%')
  dst=$(ps_start dst --network "$net" --hostname "$(ps_prefix)-dst" -e MYSQL_ROOT_PASSWORD=x -e 'MYSQL_ROOT_HOST=%')
  ps_wait_ready "$src" 180
  ps_wait_ready "$dst" 180

  ps_sql "$src" "CREATE DATABASE dd;
    CREATE TABLE dd.a (id INT PRIMARY KEY, v VARCHAR(40)) ENGINE=InnoDB;
    CREATE TABLE dd.b (id INT PRIMARY KEY, n BIGINT) ENGINE=InnoDB;
    INSERT INTO dd.a SELECT n, CONCAT('row-', n) FROM (WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 500) SELECT n FROM s) q;
    INSERT INTO dd.b SELECT n, n * 7919 FROM (WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 250) SELECT n FROM s) q"
  want_a=$(ps_sql "$src" 'SELECT COUNT(*) FROM dd.a')
  want_b=$(ps_sql "$src" 'SELECT COUNT(*) FROM dd.b')
  want_sum=$(ps_sql "$src" 'CHECKSUM TABLE dd.a')
  [ "$want_a" = 500 ]
  [ "$want_b" = 250 ]

  # the dump volume is written by uid 1001
  ps_docker run --rm --user 0 -v "$dumpvol:/dump" --entrypoint sh "$PS_IMAGE" -c 'chown 1001:0 /dump && chmod 775 /dump' > /dev/null
  shell() {
    ps_docker run --rm --user 1001 --network "$net" -v "$dumpvol:/dump" -e MYSQLSH_USER_CONFIG_HOME=/tmp \
      --entrypoint mysqlsh "$PS_IMAGE" --js --no-wizard --uri "root:x@$1:3306" -e "$2"
  }
  run shell "$(ps_prefix)-src" "util.dumpInstance('/dump/out', {threads: 2, users: false, showProgress: false})"
  echo "$output"
  [ "$status" -eq 0 ]
  # loadDump loads with LOAD DATA LOCAL INFILE; local_infile is OFF by default (MySQL 8.0+, official image too)
  ps_sql "$dst" 'SET GLOBAL local_infile = ON'
  run shell "$(ps_prefix)-dst" "util.loadDump('/dump/out', {threads: 2, showProgress: false, loadUsers: false})"
  echo "$output"
  [ "$status" -eq 0 ]

  run ps_sql "$dst" 'SELECT COUNT(*) FROM dd.a'
  [ "$output" = "$want_a" ]
  run ps_sql "$dst" 'SELECT COUNT(*) FROM dd.b'
  [ "$output" = "$want_b" ]
  run ps_sql "$dst" 'CHECKSUM TABLE dd.a'
  [ "$output" = "$want_sum" ]
}
