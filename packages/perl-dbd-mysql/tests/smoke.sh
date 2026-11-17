#!/usr/bin/env bash
# smoke.sh: melange `test:` for the perl-dbd-mysql package.
# Runs inside the melange test container with perl-dbd-mysql, percona-server-server and percona-server-client
# installed (normally as root; works unprivileged too). The recipe copies this file in through the staged source dir
# (scripts/melange-build.sh) and runs:
#   DBD_MYSQL_VERSION=<ver> PS_VERSION=<x.y.z> bash tests/smoke.sh
# Checks: the module loads with the expected version and client library, then connects to a throwaway mysqld over
# the socket and over TCP with TLS (caching_sha2_password user), runs placeholders, a transaction and a server error.
set -euo pipefail

DBD_MYSQL_VERSION=${DBD_MYSQL_VERSION:?DBD_MYSQL_VERSION must be set}
PS_VERSION=${PS_VERSION:?PS_VERSION must be set}

step() { printf '\n=== %s\n' "$*"; }
fail() {
  printf 'SMOKE FAIL: %s\n' "$*" >&2
  exit 1
}

as_user=()
if [[ $(id -u) == 0 ]]; then as_user=(--user=root); fi

work=$(mktemp -d)
sock=$work/mysql.sock
port=${SMOKE_PORT:-33306}
pid=
cleanup() {
  local rc=$?
  if [[ -n $pid ]] && kill -0 "$pid" 2> /dev/null; then
    kill "$pid" 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
  fi
  if ((rc != 0)) && [[ -f $work/error.log ]]; then
    echo "--- last 60 lines of $work/error.log ---" >&2
    tail -n 60 "$work/error.log" >&2 || true
  fi
  rm -rf "$work"
  exit "$rc"
}
trap cleanup EXIT

step "module"
v=$(perl -MDBD::mysql -e 'print $DBD::mysql::VERSION')
[[ $v == "$DBD_MYSQL_VERSION" ]] || fail "DBD::mysql version $v, expected $DBD_MYSQL_VERSION"
echo "ok: DBD::mysql $v"
perl -MDBI -e 'my @d = DBI->available_drivers; exit((grep { $_ eq "mysql" } @d) ? 0 : 1)' ||
  fail "DBI does not list the mysql driver"
echo "ok: DBI lists the mysql driver"

step "throwaway Percona Server"
mysqld --no-defaults "${as_user[@]}" --datadir="$work/data" --log-error="$work/error.log" --initialize-insecure ||
  fail "mysqld --initialize-insecure failed"
mkdir -p "$work/files"
mysqld --no-defaults "${as_user[@]}" --datadir="$work/data" --socket="$sock" --bind-address=127.0.0.1 \
  --port="$port" --mysqlx=OFF --pid-file="$work/mysqld.pid" --log-error="$work/error.log" \
  --secure-file-priv="$work/files" &
pid=$!
for _ in $(seq 1 120); do
  if mysqladmin --no-defaults --user=root --socket="$sock" ping > /dev/null 2>&1; then break; fi
  kill -0 "$pid" 2> /dev/null || fail "mysqld exited during startup"
  sleep 1
done
mysqladmin --no-defaults --user=root --socket="$sock" ping > /dev/null 2>&1 || fail "mysqld not ready after 120s"
mysql --no-defaults --user=root --socket="$sock" -e \
  "CREATE USER 'smoke'@'%' IDENTIFIED WITH caching_sha2_password BY 'sm,oke'; GRANT ALL ON *.* TO 'smoke'@'%'"

step "connect over the socket and over TCP with TLS"
SOCK=$sock PORT=$port PS_VERSION=$PS_VERSION perl -MDBI -e '
  use strict; use warnings;
  my %o = (RaiseError => 1, PrintError => 0, AutoCommit => 1);
  my $s = DBI->connect("DBI:mysql:mysql_socket=$ENV{SOCK}", "root", "", \%o);
  my ($ver) = $s->selectrow_array("SELECT VERSION()");
  die "server version $ver\n" unless index($ver, $ENV{PS_VERSION}) == 0;
  print "ok: socket, server $ver, client $s->{mysql_clientversion}\n";
  my $t = DBI->connect("DBI:mysql:host=127.0.0.1;port=$ENV{PORT};mysql_ssl=1", "smoke", "sm,oke", \%o);
  my (undef, $cipher) = $t->selectrow_array("SHOW SESSION STATUS LIKE \x27Ssl_cipher\x27");
  die "no TLS on the TCP connection\n" unless $cipher;
  print "ok: TCP + TLS ($cipher) as a caching_sha2_password user\n";
  $t->do("CREATE DATABASE smoke");
  $t->do("CREATE TABLE smoke.t (id INT PRIMARY KEY, v VARCHAR(32)) ENGINE=InnoDB");
  my $ins = $t->prepare("INSERT INTO smoke.t VALUES (?, ?)");
  $ins->execute($_, "v\x27$_") for 1 .. 3;
  $t->begin_work; $t->do("DELETE FROM smoke.t WHERE id = 3"); $t->rollback;
  my ($n, $v2) = $t->selectrow_array("SELECT COUNT(*), MAX(v) FROM smoke.t WHERE id > ?", undef, 0);
  die "rows $n / $v2\n" unless $n == 3 && $v2 eq "v\x273";
  print "ok: placeholders and a rolled back transaction\n";
  eval { $t->do("SELECT * FROM smoke.missing") };
  die "no error for a missing table\n" unless $t->err && $t->err == 1146;
  print "ok: server error ", $t->err, " reported\n";
  $_->disconnect for $s, $t;
' || fail "DBI/DBD::mysql against the throwaway server"

echo
echo "perl-dbd-mysql smoke: all checks passed"
