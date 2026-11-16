#!/usr/bin/env bash
# Compatibility diff: official percona/percona-server vs our Wolfi image.
#
#   compare.sh <official-ref> <wolfi-ref> [--allowlist F] [--out F]   collect from both images (docker), then compare
#   compare.sh --dirs <official-dir> <wolfi-dir> [--allowlist F] [--out F]   compare two fixture directories (pure, no docker)
#
# A fixture directory (written by collect.sh) holds one TSV per kind, "<name><TAB><value>" per line:
#   variable.tsv  SHOW GLOBAL VARIABLES        plugin.tsv  SHOW PLUGINS (name, status, type, library, license)
#   component.tsv mysql.component              file.tsv    find over plugin_dir (relative path, type[, link target])
#   env.tsv       docker inspect Config.Env    config.tsv  Entrypoint, Cmd, User, ExposedPorts, Volumes, WorkingDir (JSON)
# Differences (value differs, or present on one side only) must be matched by an allowlist entry
# (kind + name, exact or glob, mandatory reason), otherwise the exit status is 1.
# Allowlist names: must contain a literal character (a bare `*` is rejected); for kind file a glob never crosses "/".
# Output: out/results/compat-<ts>.diff unless --out is given. Exit: 0 match, 1 differences or invalid allowlist, 2 usage/fixtures/collection failure.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KINDS=(variable plugin component file env config)
ABSENT='<absent>'

usage() {
  sed -n '2,5p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

# load_allowlist <file>: fills AL_KIND/AL_NAME/AL_REASON; returns 1 (messages on stderr) when invalid.
AL_KIND=() AL_NAME=() AL_REASON=()
load_allowlist() {
  local file=$1 line key val n=-1 bad=0 k
  [[ -f $file ]] || { echo "compare: allowlist not found: $file" >&2; return 1; }
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    [[ $line =~ ^entries:[[:space:]]*$ ]] && continue
    if [[ $line =~ ^[[:space:]]*-[[:space:]]+([a-z]+):[[:space:]]*(.*)$ ]]; then
      n=$((n + 1)); AL_KIND[n]='' AL_NAME[n]='' AL_REASON[n]=''
      key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
    elif [[ $line =~ ^[[:space:]]+([a-z]+):[[:space:]]*(.*)$ ]] && ((n >= 0)); then
      key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
    else
      echo "compare: allowlist: cannot parse line: $line" >&2; return 1
    fi
    if [[ $val =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ || $val =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
      val=${BASH_REMATCH[1]}
    else
      val=${val%%[[:space:]]#*}
      val=${val%"${val##*[![:space:]]}"}
    fi
    case $key in
      kind) AL_KIND[n]=$val ;;
      name) AL_NAME[n]=$val ;;
      reason) AL_REASON[n]=$val ;;
      *) echo "compare: allowlist entry $((n + 1)): unknown field '$key'" >&2; bad=1 ;;
    esac
  done < "$file"
  for ((k = 0; k <= n; k++)); do
    if [[ " ${KINDS[*]} " != *" ${AL_KIND[k]} "* ]]; then
      echo "compare: allowlist entry $((k + 1)) (${AL_NAME[k]:-?}): kind must be one of ${KINDS[*]}" >&2; bad=1
    fi
    if [[ -z ${AL_NAME[k]} ]]; then
      echo "compare: allowlist entry $((k + 1)): name is required" >&2; bad=1
    elif [[ -z ${AL_NAME[k]//[\*\?\[\]]/} ]]; then
      echo "compare: allowlist entry $((k + 1)) (${AL_NAME[k]}): name needs at least one literal character (too broad)" >&2; bad=1
    fi
    [[ -n ${AL_REASON[k]} ]] || { echo "compare: allowlist entry $((k + 1)) (${AL_NAME[k]}): reason is required" >&2; bad=1; }
  done
  return "$bad"
}

# allowed_reason <kind> <name>: sets REASON from the first matching entry and marks it used; status 1 when none matches.
# For kind file a glob never crosses a "/" (the name and the pattern need the same number of path segments).
declare -A AL_USED=()
REASON=
allowed_reason() {
  local k pat slashes
  for k in "${!AL_KIND[@]}"; do
    [[ ${AL_KIND[k]} == "$1" ]] || continue
    pat=${AL_NAME[k]}
    if [[ $1 == file ]]; then
      slashes=${2//[^\/]/}
      [[ ${pat//[^\/]/} == "$slashes" ]] || continue
    fi
    # shellcheck disable=SC2053 # the allowlist name is a glob on purpose
    if [[ $2 == $pat ]]; then
      REASON=${AL_REASON[k]}
      AL_USED[$k]=1
      return 0
    fi
  done
  return 1
}

# read_tsv <file> <array-name>: loads "name<TAB>value" lines into an associative array.
read_tsv() {
  local -n _map=$2
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -n $line ]] || continue
    # shellcheck disable=SC2004 # _map is an associative array: keys are strings
    if [[ $line == *$'\t'* ]]; then _map[${line%%$'\t'*}]=${line#*$'\t'}; else _map[$line]=''; fi
  done < "$1"
}

# compare_dirs <official-dir> <wolfi-dir> <out-file>: returns 1 when a difference is not allowlisted.
compare_dirs() {
  local a=$1 b=$2 out=$3 kind name va vb reason failed=0 allowed=0 d k
  for d in "$a" "$b"; do
    for kind in "${KINDS[@]}"; do
      [[ -f $d/$kind.tsv ]] || { echo "compare: missing fixture $d/$kind.tsv" >&2; return 2; }
    done
  done
  : > "$out"
  for kind in "${KINDS[@]}"; do
    local -A ma=() mb=()
    read_tsv "$a/$kind.tsv" ma
    read_tsv "$b/$kind.tsv" mb
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      va=${ma[$name]-$ABSENT} vb=${mb[$name]-$ABSENT}
      [[ $va == "$vb" ]] && continue
      if allowed_reason "$kind" "$name"; then reason=$REASON
        allowed=$((allowed + 1))
        printf '# allowed (%s): %s %s\n-   %s\n+   %s\n' "$reason" "$kind" "$name" "$va" "$vb" >> "$out"
      else
        failed=$((failed + 1))
        printf '%s %s\n-   %s\n+   %s\n' "$kind" "$name" "$va" "$vb" >> "$out"
        printf 'DIFF %s %s: official=%s wolfi=%s\n' "$kind" "$name" "$va" "$vb"
      fi
    done < <(printf '%s\n' "${!ma[@]}" "${!mb[@]}" | sort -u)
    unset ma mb
  done
  for k in "${!AL_KIND[@]}"; do
    [[ -n ${AL_USED[$k]:-} ]] && continue
    printf '# warning: stale allowlist entry (never matched): %s %s\n' "${AL_KIND[k]}" "${AL_NAME[k]}" | tee -a "$out" >&2
  done
  printf '# summary: %d unallowed difference(s), %d allowlisted\n' "$failed" "$allowed" >> "$out"
  echo "compare: $failed unallowed difference(s), $allowed allowlisted; see $out"
  ((failed == 0))
}

main() {
  local mode=refs allowlist=$HERE/allowlist.yaml out="" pos=() rc
  while (($#)); do
    case $1 in
      --dirs) mode=dirs ;;
      --allowlist) allowlist=${2:?}; shift ;;
      --out) out=${2:?}; shift ;;
      -h | --help) usage ;;
      *) pos+=("$1") ;;
    esac
    shift
  done
  ((${#pos[@]} == 2)) || usage
  [[ -n $out ]] || out=$HERE/../../out/results/compat-$(date -u +%Y%m%dT%H%M%SZ).diff
  mkdir -p "$(dirname "$out")"
  load_allowlist "$allowlist" || return 1
  if [[ $mode == refs ]]; then
    local work
    work=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT
    "$HERE/collect.sh" "${pos[0]}" "$work/official" || return 2
    "$HERE/collect.sh" "${pos[1]}" "$work/wolfi" || return 2
    mkdir -p "$(dirname "$out")"
    [[ -n ${COMPAT_KEEP_FIXTURES:-} ]] && cp -r "$work" "${out%.diff}.fixtures"
    compare_dirs "$work/official" "$work/wolfi" "$out" && rc=0 || rc=$?
    return "$rc"
  fi
  compare_dirs "${pos[0]}" "${pos[1]}" "$out"
}

main "$@"
