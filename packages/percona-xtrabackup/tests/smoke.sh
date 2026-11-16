#!/usr/bin/env bash
# smoke.sh: melange `test:` for the percona-xtrabackup package.
# Runs inside the melange test container with percona-xtrabackup, percona-xtrabackup-test, percona-server-server
# and percona-server-client installed (normally as root; works unprivileged too). The recipe copies this file in
# through the staged source dir (scripts/melange-build.sh) and runs:
#   PXB_VERSION=<ver>-<rel> PXB_REVISION=<8 hex> bash tests/smoke.sh
#
# Env:
#   PXB_VERSION   required, e.g. 9.7.2-2 (must appear in `xtrabackup --version`)
#   PXB_REVISION  optional, e.g. 59328573 (must appear as "revision id" in `xtrabackup --version`)
#   PLUGIN_DIR    default /usr/lib64/xtrabackup/plugin (RPM path; resolves through Wolfi's /usr/lib64 -> lib)
#   TEST_DIR      default /usr/share/percona-xtrabackup-test-97 (percona-xtrabackup-test)
#   SKIP_SERVER   set to 1 to skip the backup/prepare against a throwaway mysqld
set -euo pipefail

PXB_VERSION=${PXB_VERSION:?PXB_VERSION (e.g. 9.7.2-2) must be set}
PXB_REVISION=${PXB_REVISION:-}
PLUGIN_DIR=${PLUGIN_DIR:-/usr/lib64/xtrabackup/plugin}
TEST_DIR=${TEST_DIR:-/usr/share/percona-xtrabackup-test-97}

step() { printf '\n=== %s\n' "$*"; }
fail() {
  printf 'SMOKE FAIL: %s\n' "$*" >&2
  exit 1
}
expect() {
  local want=$1 got=$2 what=$3
  [[ $got == "$want" ]] || fail "$what: expected '$want', got '$got'"
  echo "ok: $what = $got"
}

# mysqld refuses to run as root without --user=root.
as_user=()
if [[ $(id -u) == 0 ]]; then as_user=(--user=root); fi

work=$(mktemp -d)
sock=$work/mysql.sock
pid=
cleanup() {
  local rc=$?
  if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  if ((rc != 0)); then
    for f in "$work/error.log" "$work/backup.log" "$work/prepare.log"; do
      [[ -f $f ]] || continue
      echo "--- last 60 lines of $f ---" >&2
      tail -n 60 "$f" >&2 || true
    done
  fi
  rm -rf "$work"
  exit "$rc"
}
trap cleanup EXIT

sql() { mysql --no-defaults --user=root --socket="$sock" --batch --skip-column-names -e "$1"; }

step "version"
# xtrabackup prints its version banner on stderr
ver=$(xtrabackup --version 2>&1)
echo "$ver"
[[ $ver == *"xtrabackup version $PXB_VERSION "* ]] || fail "xtrabackup --version lacks 'xtrabackup version $PXB_VERSION'"
if [[ -n $PXB_REVISION ]]; then
  [[ $ver == *"revision id: $PXB_REVISION"* ]] || fail "xtrabackup --version lacks 'revision id: $PXB_REVISION'"
fi

step "files (RPM layout through Wolfi's merged /usr)"
for b in xtrabackup xbstream xbcrypt xbcloud xbcloud_osenv; do
  [[ -x /usr/bin/$b ]] || fail "missing /usr/bin/$b"
  echo "ok: /usr/bin/$b"
done
for p in component_keyring_file.so component_keyring_vault.so component_keyring_kms.so component_keyring_kmip.so; do
  [[ -f $PLUGIN_DIR/$p ]] || fail "missing $PLUGIN_DIR/$p"
  echo "ok: $p"
done
[[ -d $TEST_DIR ]] || fail "missing $TEST_DIR (percona-xtrabackup-test)"
# compiled-in plugin dir must be the RPM one (xtrabackup loads keyring components from there)
pd=$(xtrabackup --no-defaults --help 2>/dev/null | awk '$1 == "xtrabackup-plugin-dir" { print $2; exit }') || true
# The option itself has no default ("(No default value)"); unset, xb_set_plugin_dir() falls back to the compiled-in
# PLUGINDIR, so check that path is what the binary carries.
if [[ -n $pd && $pd != "(No" ]]; then
  expect "$PLUGIN_DIR" "${pd%/}" "xtrabackup-plugin-dir default"
else
  grep -aqF -- "$PLUGIN_DIR" /usr/bin/xtrabackup || fail "compiled-in PLUGINDIR $PLUGIN_DIR not found in /usr/bin/xtrabackup"
  echo "ok: compiled-in PLUGINDIR = $PLUGIN_DIR (xtrabackup-plugin-dir unset)"
fi

step "shared libraries resolve"
for f in /usr/bin/xtrabackup /usr/bin/xbstream /usr/bin/xbcrypt /usr/bin/xbcloud "$PLUGIN_DIR"/*.so; do
  missing=$(ldd "$f" 2>&1 | grep 'not found' || true)
  [[ -z $missing ]] || fail "$f: unresolved libraries: $missing"
done
echo "ok: ldd"

step "xbstream round trip"
mkdir -p "$work/in/sub" "$work/out"
head -c 1048576 /dev/urandom > "$work/in/sub/blob.bin"
printf 'hello xbstream\n' > "$work/in/hello.txt"
(cd "$work/in" && xbstream -c hello.txt sub/blob.bin) > "$work/stream.xbs"
xbstream -x -C "$work/out" < "$work/stream.xbs"
cmp "$work/in/hello.txt" "$work/out/hello.txt" || fail "xbstream: hello.txt differs after round trip"
cmp "$work/in/sub/blob.bin" "$work/out/sub/blob.bin" || fail "xbstream: sub/blob.bin differs after round trip"
echo "ok: xbstream -c / -x byte-identical"

step "xbcrypt round trip"
key=0123456789abcdef0123456789abcdef
xbcrypt --encrypt-algo=AES256 --encrypt-key="$key" -i "$work/in/sub/blob.bin" -o "$work/blob.xbcrypt"
xbcrypt -d --encrypt-algo=AES256 --encrypt-key="$key" -i "$work/blob.xbcrypt" -o "$work/blob.dec"
cmp "$work/in/sub/blob.bin" "$work/blob.dec" || fail "xbcrypt: decrypted file differs"
echo "ok: xbcrypt encrypt / decrypt byte-identical"

if [[ ${SKIP_SERVER:-0} == 1 ]]; then
  echo "server checks skipped"
  echo
  echo "SMOKE PASS"
  exit 0
fi

step "initialize and start a throwaway Percona Server"
datadir=$work/data
mysqld --no-defaults "${as_user[@]}" --datadir="$datadir" --log-error="$work/error.log" --initialize-insecure ||
  fail "mysqld --initialize-insecure failed"
# own --secure-file-priv dir: this test is about backups, not the server package's defaults (its smoke checks them)
mkdir -p "$work/files"
mysqld --no-defaults "${as_user[@]}" --datadir="$datadir" --socket="$sock" --skip-networking --mysqlx=OFF \
  --pid-file="$work/mysqld.pid" --log-error="$work/error.log" --secure-file-priv="$work/files" &
pid=$!
for _ in $(seq 1 120); do
  if mysqladmin --no-defaults --user=root --socket="$sock" ping >/dev/null 2>&1; then break; fi
  kill -0 "$pid" 2>/dev/null || fail "mysqld exited during startup"
  sleep 1
done
mysqladmin --no-defaults --user=root --socket="$sock" ping >/dev/null 2>&1 || fail "mysqld not ready after 120s"
sql 'SELECT @@version, @@version_comment'
sql 'CREATE DATABASE smoke'
sql 'CREATE TABLE smoke.t (id INT PRIMARY KEY, v VARCHAR(16)) ENGINE=InnoDB'
sql "INSERT INTO smoke.t VALUES (1, 'one'), (2, 'two'), (3, 'three')"

step "xtrabackup --backup"
target=$work/b
xtrabackup --no-defaults --backup --user=root --socket="$sock" --datadir="$datadir" --target-dir="$target" \
  > "$work/backup.log" 2>&1 || fail "xtrabackup --backup exited non-zero"
tail -n 3 "$work/backup.log"
[[ -f $target/smoke/t.ibd ]] || fail "backup lacks smoke/t.ibd"
grep -q '^backup_type = full-backuped$' "$target/xtrabackup_checkpoints" ||
  fail "xtrabackup_checkpoints: backup_type is not full-backuped"

step "xtrabackup --prepare"
xtrabackup --no-defaults --prepare --target-dir="$target" > "$work/prepare.log" 2>&1 ||
  fail "xtrabackup --prepare exited non-zero"
tail -n 3 "$work/prepare.log"
grep -q '^backup_type = full-prepared$' "$target/xtrabackup_checkpoints" ||
  fail "xtrabackup_checkpoints: backup_type is not full-prepared"
echo "ok: backup prepared"

step "shutdown"
mysqladmin --no-defaults --user=root --socket="$sock" shutdown
wait "$pid" || fail "mysqld exited non-zero on shutdown"
pid=

echo
echo "SMOKE PASS"
