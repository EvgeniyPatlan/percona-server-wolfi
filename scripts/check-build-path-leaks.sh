#!/usr/bin/env bash
# check-build-path-leaks.sh <dir> <build-path> [allowlist]
# Fails if any regular file under <dir> contains the literal string <build-path> (e.g. the melange workspace
# /home/build): such files are not build-path independent, so not reproducible across build hosts/dirs.
# <allowlist>: optional file of extended regexes (one per line, '#' comments and blank lines ignored),
# matched against the path relative to <dir>; matching files are reported as ALLOWED instead of failing.
# LEAK_IGNORE (environment): space-separated literal strings under <build-path> that do not come from this build and
# are removed from a file's content before the check, e.g. "/home/build/csu": Wolfi builds glibc in /home/build too, so
# the debug info of its crt objects (linked into every binary) names /home/build/csu. A file whose only references are
# such strings is reported as IGNORED. Each string must start with <build-path>/.
# LEAK_SCAN=warn (environment): report the leaks but exit 0 (first host run: collect every leak in one build instead of
# stopping at the first package). LEAK_SCAN=fatal is the default. scripts/melange-build.sh passes it into the build.
# Self-contained (no scripts/lib): scripts/melange-build.sh stages it into every package source dir as
# build-tools/check-build-path-leaks.sh, and recipes run it inside the melange build container.
set -euo pipefail

if (($# < 2 || $# > 3)); then
  echo "usage: check-build-path-leaks.sh <dir> <build-path> [allowlist]" >&2
  exit 2
fi
dir=$1 path=$2 allow=${3:-} mode=${LEAK_SCAN:-fatal}
case $mode in
  fatal | warn) ;;
  *) echo "LEAK_SCAN must be fatal or warn, not '$mode'" >&2; exit 2 ;;
esac
[[ -d $dir ]] || { echo "not a directory: $dir" >&2; exit 2; }
[[ $path == /?* ]] || { echo "build path must be absolute and not '/': $path" >&2; exit 2; }
if [[ -n $allow && ! -r $allow ]]; then
  echo "cannot read allowlist: $allow" >&2
  exit 2
fi

ignore=()
for i in ${LEAK_IGNORE:-}; do
  [[ $i == "$path"/?* ]] || { echo "LEAK_IGNORE entry must start with $path/: $i" >&2; exit 2; }
  ignore+=("$i")
done
sed_ignore=()
for i in "${ignore[@]}"; do
  sed_ignore+=(-e "s#$(printf '%s' "$i" | sed 's/[][\\.*^$#&]/\\&/g')##g")
done

# only_ignored <file>: every reference to the build path in <file> is one of the LEAK_IGNORE strings.
only_ignored() {
  ((${#ignore[@]})) || return 1
  ! sed "${sed_ignore[@]}" "$1" | grep -qF -- "$path"
}

patterns=()
if [[ -n $allow ]]; then
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    patterns+=("$line")
  done < "$allow"
fi

allowed() {
  local p
  for p in "${patterns[@]}"; do
    if [[ $1 =~ $p ]]; then return 0; fi
  done
  return 1
}

# One grep per file and no GNU-only flags (-Z, sort -z): the melange build container may only have busybox.
leaks=0 total=0
while IFS= read -r f; do
  grep -qF -- "$path" "$dir/$f" || continue
  rel=${f#./}
  if only_ignored "$dir/$f"; then
    echo "IGNORED build-path reference (LEAK_IGNORE only): $rel"
    continue
  fi
  total=$((total + 1))
  if allowed "$rel"; then
    echo "ALLOWED build-path reference: $rel"
  else
    echo "BUILD-PATH LEAK: $rel" >&2
    leaks=$((leaks + 1))
  fi
done < <(cd "$dir" && find . -type f | LC_ALL=C sort)

if ((leaks)); then
  echo "$leaks file(s) under $dir contain the build path $path (allow-list them only with a reason)" >&2
  if [[ $mode == warn ]]; then
    echo "LEAK_SCAN=warn: not failing the build (never for a release)" >&2
    exit 0
  fi
  exit 1
fi
echo "no build-path leaks under $dir ($total allow-listed)"
