#!/usr/bin/env bash
# make-upgrade-datadir.sh <official-ref> <volume-name>
# Creates docker volume <volume-name> holding a datadir written by an official percona/percona-server image:
# InnoDB table (1000 rows), RocksDB table, component_keyring_file encrypted tablespace, a JavaScript stored
# function (only when the image ships component_js_lang), users on auth_pam and caching_sha2_password. The server is stopped cleanly afterwards, and the expected
# state is written to out/results/upgrade-<volume-name>.expect (see upgrade-lib.bash for the format).
#
# Environment: DOCKER (default docker; may be several words), ROOT_PW (default x).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
# shellcheck source=upgrade-lib.bash
source "$here/upgrade-lib.bash"

ref=${1:?usage: make-upgrade-datadir.sh <official-ref> <volume-name>}
vol=${2:?usage: make-upgrade-datadir.sh <official-ref> <volume-name>}
pw=${ROOT_PW:-x}
name=$vol-fixture
expect=$root/out/results/upgrade-$vol.expect

d() {
  # shellcheck disable=SC2086 # DOCKER may be a multi-word command
  ${DOCKER:-docker} "$@"
}
cleanup() { d rm -f -v "$name" > /dev/null 2>&1 || true; }
trap cleanup EXIT

sql() {
  d exec -e "MYSQL_PWD=$pw" "$name" mysql --no-defaults -N -B -uroot -e "$1"
}

wait_ready() {
  local i
  for ((i = 0; i < 180; i++)); do
    [[ $(d inspect -f '{{.State.Running}}' "$name") == true ]] || {
      d logs "$name" >&2
      echo "fixture container exited" >&2
      return 1
    }
    if d exec -e "MYSQL_PWD=$pw" "$name" mysqladmin --no-defaults --protocol=tcp -h127.0.0.1 -uroot ping > /dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  d logs "$name" >&2
  echo "fixture server not ready" >&2
  return 1
}

d volume create "$vol" > /dev/null
# first start initialises the datadir (INIT_ROCKSDB=1 enables the RocksDB engine and persists it)
d run -d --name "$name" -e "MYSQL_ROOT_PASSWORD=$pw" -e INIT_ROCKSDB=1 -v "$vol:/var/lib/mysql" -v "$KEYRING_GLOBAL_MOUNT" "$ref" > /dev/null
wait_ready
d stop -t 120 "$name" > /dev/null

# keyring component: manifest and config live in the datadir (same layout server-plugins.bats uses); the keyring
# file stays in the volume, so the Wolfi image reads the same keys.
d run --rm --user 0 -v "$vol:/d" --entrypoint sh "$ref" -ec '
  printf "%s" "{\"components\": \"file://component_keyring_file\"}" > /d/mysqld.my
  printf "%s" "{\"path\": \"/var/lib/mysql/component_keyring_file.data\", \"read_only\": false}" > /d/component_keyring_file.cnf
  chown 1001:0 /d/mysqld.my /d/component_keyring_file.cnf
  chmod 640 /d/mysqld.my /d/component_keyring_file.cnf' > /dev/null
d start "$name" > /dev/null
wait_ready

sql "SELECT status_value FROM performance_schema.keyring_component_status WHERE status_key='Component_status'" | grep -qx Active \
  || { echo "component_keyring_file is not active" >&2; exit 1; }
sql "INSTALL PLUGIN auth_pam SONAME 'auth_pam.so'"
# JS stored programs need component_js_lang, which the official image does not ship (docs/deviations.md: the
# percona-server-js subpackage): the function is created only when the image has it
js=0
if d exec "$name" test -f /usr/lib64/mysql/plugin/component_js_lang.so; then
  js=1
  sql "INSTALL COMPONENT 'file://component_js_lang'"
  sql "GRANT CREATE_JS_ROUTINE ON *.* TO 'root'@'localhost'"
fi
sql "CREATE DATABASE up;
  CREATE TABLE up.t_innodb (id INT PRIMARY KEY, v VARCHAR(40), n BIGINT) ENGINE=InnoDB;
  INSERT INTO up.t_innodb SELECT n, CONCAT('row-', n), n * 7919 FROM (
    WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 1000) SELECT n FROM s) q;
  CREATE TABLE up.t_rocksdb (id INT PRIMARY KEY, v VARCHAR(40)) ENGINE=ROCKSDB;
  INSERT INTO up.t_rocksdb SELECT n, CONCAT('rocks-', n) FROM (
    WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 100) SELECT n FROM s) q;
  CREATE TABLE up.t_encrypted (id INT PRIMARY KEY, v VARCHAR(40)) ENGINE=InnoDB ENCRYPTION='Y';
  INSERT INTO up.t_encrypted SELECT n, CONCAT('secret-', n) FROM (
    WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 100) SELECT n FROM s) q;
  CREATE USER 'u_pam'@'%' IDENTIFIED WITH auth_pam;
  CREATE USER 'u_sha2'@'%' IDENTIFIED WITH caching_sha2_password BY 'sha2pw';"
if ((js)); then
  # shellcheck disable=SC2016 # $$ is the SQL routine-body delimiter
  sql 'CREATE FUNCTION up.f() RETURNS INT DETERMINISTIC LANGUAGE JS AS $$ return 1+1 $$'
fi

mkdir -p "$(dirname "$expect")"
{
  upgrade_state sql
  printf 'server.version=%s\n' "$(sql 'SELECT @@version')"
} > "$expect.tmp"
mv "$expect.tmp" "$expect"
d exec -e "MYSQL_PWD=$pw" "$name" mysqladmin --no-defaults -uroot flush-tables > /dev/null
d stop -t 300 "$name" > /dev/null
echo "fixture volume $vol ready; expectations in $expect" >&2
