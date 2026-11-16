#!/usr/bin/env bats
# Upgrade gate: the Wolfi -dev image must start on a datadir written by the official percona/percona-server images
# (official_ps_image and official_ps_prev_image of the version file). Needs IMAGE, a docker daemon and network access
# to pull the two official images (~1 GB each). Fixture: tests/fixtures/make-upgrade-datadir.sh.

# The images under test come from the registry (apko publishes there, nothing is in the local docker): pull them once;
# a failed pull fails every test of the suite instead of skipping it.
setup_file() {
  load helpers
  ps_pull_images "$PS_IMAGE"
}

setup() {
  load helpers
  ps_require_dev
  unset PS_SQL_USER
  export PS_SQL_PASSWORD=x
  # shellcheck source=../fixtures/upgrade-lib.bash
  source "$PS_ROOT/tests/fixtures/upgrade-lib.bash"
  VERSION_FILE=${VERSION_FILE:-$PS_ROOT/versions/9.7.yaml}
}

teardown() {
  ps_cleanup
}

wolfi_sql() { ps_sql "$WOLFI_CID" "$1"; }

# check_upgrade <key-in-version-file>
check_upgrade() {
  local ref vol cid expect actual log refusal old target direction running
  ref=$(vars_get "$VERSION_FILE" "$1")
  vol=$(ps_volume "upg-$1")
  ps_track containers "$vol-fixture"
  DOCKER=${DOCKER:-docker} "$PS_ROOT/tests/fixtures/make-upgrade-datadir.sh" "$ref" "$vol"
  expect=$PS_ROOT/out/results/upgrade-$vol.expect
  [ -s "$expect" ]

  old=$(expect_get "$expect" server.version)
  cid=$(ps_start wolfi -e MYSQL_ROOT_PASSWORD=x -v "$vol:/var/lib/mysql" -v "$KEYRING_GLOBAL_MOUNT")
  # the Wolfi version is only known once the server runs; the target is the version file's ps_version-ps_release
  target=$(vars_get "$VERSION_FILE" ps_version)-$(vars_get "$VERSION_FILE" ps_release)
  direction=$(version_direction "$old" "$target")
  echo "# $1: fixture $old -> wolfi $target ($direction)" >&3
  if ! ps_wait_ready "$cid" 300 2> "$BATS_TEST_TMPDIR/wait.err"; then
    log=$(ps_logs "$cid" || true)
    refusal=$(printf '%s\n' "$log" | upgrade_refusal_text || true)
    if [ -n "$refusal" ] && [ "$direction" != same-version ]; then
      skip "server refuses the $direction $old -> $target (dropped from the matrix): $refusal"
    fi
    printf '%s\n' "$log" >&2
    cat "$BATS_TEST_TMPDIR/wait.err" >&2
    return 1
  fi
  WOLFI_CID=$cid

  actual=$BATS_TEST_TMPDIR/actual
  upgrade_state wolfi_sql > "$actual"
  grep -v '^server.version=' "$expect" > "$BATS_TEST_TMPDIR/expected"
  run expect_compare "$BATS_TEST_TMPDIR/expected" "$actual"
  echo "$output"
  [ "$status" -eq 0 ]

  # explicit assertions, so a bad expectation file cannot make the comparison vacuous
  [ "$(expect_get "$actual" rows.innodb)" = 1000 ]
  # JS stored function: from the fixture when its image had component_js_lang, else created on the upgraded datadir
  if ! expect_get "$actual" js.f > /dev/null; then
    wolfi_sql "INSTALL COMPONENT 'file://component_js_lang'"
    wolfi_sql "GRANT CREATE_JS_ROUTINE ON *.* TO 'root'@'localhost'"
    # shellcheck disable=SC2016 # $$ is the SQL routine-body delimiter
    wolfi_sql 'CREATE FUNCTION up.f() RETURNS INT DETERMINISTIC LANGUAGE JS AS $$ return 1+1 $$'
  fi
  run wolfi_sql 'SELECT up.f()'
  [ "$output" = 2 ]
  [ "$(expect_get "$actual" encrypted.option)" = 1 ]
  run wolfi_sql 'SELECT COUNT(*) FROM up.t_encrypted'
  [ "$output" = 100 ]
  run wolfi_sql 'SELECT COUNT(*) FROM up.t_rocksdb'
  [ "$output" = 100 ]
  run wolfi_sql "SELECT support FROM information_schema.engines WHERE engine='ROCKSDB'"
  [ "$output" = YES ]
  # caching_sha2_password user can log in with its password
  run ps_docker exec -e MYSQL_PWD=sha2pw "$cid" mysql --no-defaults -N -B -uu_sha2 -h127.0.0.1 -e 'SELECT 1'
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]

  # the running server is the Wolfi build; mysqld runs its server upgrade only when the numeric version is
  # strictly newer than the datadir's (a downgrade within the series or a same-version start does not)
  run wolfi_sql 'SELECT @@version'
  [[ $output == "$(vars_get "$VERSION_FILE" ps_version)"* ]]
  running=$output
  if server_upgrade_expected "$old" "$running"; then
    ps_logs "$cid" | grep -Eq 'Server upgrade.*(completed|complete)|upgrade.*completed'
  fi
  # upgrade metadata in the datadir (history file) mentions the running version when the server wrote one
  if ps_has_file "$cid" /var/lib/mysql/mysql_upgrade_history; then
    ps_docker cp "$cid:/var/lib/mysql/mysql_upgrade_history" - | grep -aq "$running"
  fi
  run ps_logs "$cid"
  [[ $output != *"[ERROR] [MY-013"*pgrade*ailed* ]]
}

@test "upgrade from official_ps_image datadir" {
  check_upgrade official_ps_image
}

@test "upgrade from official_ps_prev_image datadir" {
  check_upgrade official_ps_prev_image
}
