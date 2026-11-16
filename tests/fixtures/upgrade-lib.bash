#!/usr/bin/env bash
# Pure helpers of the upgrade gate (tests/fixtures/make-upgrade-datadir.sh, tests/image/upgrade.bats).
# Sourced; no docker here, so tests/unit/upgrade-lib.bats can exercise it with a stub SQL runner.
#
# The "state" of a fixture datadir is a list of sorted key=value lines (the .expect file format):
#   rows.innodb / checksum.innodb / checksum.rocksdb / checksum.encrypted / encrypted.option / js.f (only when the
#   fixture image has component_js_lang) / user.<name>

# upgrade_state <sqlfn>: print the state. <sqlfn> is a command that takes one SQL string and prints the
# `mysql -N -B` result (the fixture passes one for the official image, the bats for the Wolfi image).
upgrade_state() {
  local sqlfn=$1 t out
  out=$("$sqlfn" 'SELECT COUNT(*) FROM up.t_innodb') || return 1
  printf 'rows.innodb=%s\n' "$out"
  for t in innodb rocksdb encrypted; do
    out=$("$sqlfn" "CHECKSUM TABLE up.t_$t") || return 1
    printf 'checksum.%s=%s\n' "$t" "${out##*[[:space:]]}"
  done
  out=$("$sqlfn" "SELECT create_options LIKE '%ENCRYPTION=%Y%' FROM information_schema.tables WHERE table_schema='up' AND table_name='t_encrypted'") || return 1
  printf 'encrypted.option=%s\n' "$out"
  # js.f only when the fixture has the JS function: the fixture image may lack component_js_lang (the official image
  # does not install percona-server-js)
  out=$("$sqlfn" "SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema='up' AND routine_name='f'") || return 1
  if [[ $out == 1 ]]; then
    out=$("$sqlfn" 'SELECT up.f()') || return 1
    printf 'js.f=%s\n' "$out"
  fi
  "$sqlfn" "SELECT CONCAT('user.', user, '=', plugin) FROM mysql.user WHERE user IN ('u_pam','u_sha2') ORDER BY user" || return 1
}

# expect_get <file> <key>: value of key (first match); fails when absent.
expect_get() {
  local line
  while IFS= read -r line; do
    if [[ $line == "$2="* ]]; then
      printf '%s\n' "${line#*=}"
      return 0
    fi
  done < "$1"
  return 1
}

# expect_compare <expected-file> <actual-file>: every expected key must be present in actual with the same value.
# Prints one line per mismatch; returns 1 on any mismatch or an empty expectation.
expect_compare() {
  local line key val got rc=0 n=0
  while IFS= read -r line; do
    [[ -n $line && $line != '#'* ]] || continue
    n=$((n + 1))
    key=${line%%=*}
    val=${line#*=}
    if got=$(expect_get "$2" "$key"); then
      [[ $got == "$val" ]] || {
        printf 'mismatch %s: expected %s, got %s\n' "$key" "$val" "$got"
        rc=1
      }
    else
      printf 'missing %s: expected %s\n' "$key" "$val"
      rc=1
    fi
  done < "$1"
  if ((n == 0)); then
    echo "empty expectation file $1"
    return 1
  fi
  return "$rc"
}

# upgrade_refusal_text <log-text-on-stdin>: the server's lines that say it refuses the version jump; fails
# (prints nothing) when the log holds no such refusal.
upgrade_refusal_text() {
  grep -E 'Invalid MySQL server upgrade|Cannot upgrade from|Cannot downgrade|[Dd]owngrade (is )?not (supported|allowed)|[Uu]pgrade (is )?not (supported|allowed)|Upgrading from .* is not supported'
}

# version_cmp <a> <b>: print -1, 0 or 1 comparing two Percona server versions ("9.7.2-2", "9.7.2-3.1", "9.7.2"):
# first the numeric core (9.7.2), then the Percona release suffix (-N[.M]); missing suffix counts as 0.
version_cmp() {
  local a=$1 b=$2 ca cb sa sb r
  ca=${a%%-*}
  cb=${b%%-*}
  sa=0 sb=0
  [[ $a == *-* ]] && sa=${a#*-}
  [[ $b == *-* ]] && sb=${b#*-}
  sa=${sa%%[!0-9.]*}
  sb=${sb%%[!0-9.]*}
  r=$(_dotted_cmp "$ca" "$cb")
  [[ $r != 0 ]] || r=$(_dotted_cmp "${sa:-0}" "${sb:-0}")
  printf '%s\n' "$r"
}

# _dotted_cmp <a> <b>: numeric component-wise comparison of dotted numbers.
_dotted_cmp() {
  local -a x y
  local i n
  IFS=. read -r -a x <<< "$1"
  IFS=. read -r -a y <<< "$2"
  n=${#x[@]}
  ((${#y[@]} > n)) && n=${#y[@]}
  for ((i = 0; i < n; i++)); do
    if ((10#${x[i]:-0} < 10#${y[i]:-0})); then
      echo -1
      return
    elif ((10#${x[i]:-0} > 10#${y[i]:-0})); then
      echo 1
      return
    fi
  done
  echo 0
}

# version_direction <fixture-version> <wolfi-version>: upgrade | same-version | downgrade, as seen from the datadir
# written by the fixture image to the Wolfi server (a newer Percona suffix on the same core counts as upgrade).
version_direction() {
  case $(version_cmp "$2" "$1") in
    1) echo upgrade ;;
    0) echo same-version ;;
    *) echo downgrade ;;
  esac
}

# server_upgrade_expected <fixture-version> <wolfi-version>: true only when the numeric server version (core,
# e.g. 9.7.2) is strictly newer, i.e. when mysqld runs its server upgrade; a Percona suffix change does not.
server_upgrade_expected() {
  [[ $(_dotted_cmp "${2%%-*}" "${1%%-*}") == 1 ]]
}

# keyring_global_mount <component>: docker -v argument giving <component> a global config in the plugin directory.
# A keyring component reads its global config there, and neither the official nor the Wolfi image ships one except
# component_keyring_vault.cnf; read-local-config.cnf only says read_local_config, so the datadir's <component>.cnf
# applies (as for the vault component). /usr/lib64 is a symlink to /usr/lib on Wolfi; docker resolves it.
keyring_global_mount() {
  printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/read-local-config.cnf:/usr/lib64/mysql/plugin/$1.cnf:ro"
}

# KEYRING_GLOBAL_MOUNT: the mount for component_keyring_file, used by every server started on a fixture datadir
KEYRING_GLOBAL_MOUNT=$(keyring_global_mount component_keyring_file)
export KEYRING_GLOBAL_MOUNT
