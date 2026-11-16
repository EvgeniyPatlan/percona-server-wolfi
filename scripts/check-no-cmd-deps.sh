#!/usr/bin/env bash
# check-no-cmd-deps.sh <repo-dir> <version-full> <list-file>
# Fails if a package named in <list-file> (one name per line, '#' comments and blank lines ignored) has a generated
# `depend = cmd:<interpreter>` line in its .PKGINFO. melange adds such a dependency for every executable with a `#!`
# line, and it would pull busybox/bash/perl into the distroless image (scripts/apko-build.sh then refuses the lock).
# The apk checked is <repo-dir>/x86_64/<name>-<version-full>.apk (version-full = <version>-r<epoch>); a listed package
# that was not built is an error. Called by scripts/melange-build.sh after `melange build` when
# packages/<name>/no-cmd-deps exists.
set -euo pipefail

if (($# != 3)); then
  echo "usage: check-no-cmd-deps.sh <repo-dir> <version-full> <list-file>" >&2
  exit 2
fi
repo=$1 ver=$2 list=$3
[[ -r $list ]] || { echo "cannot read list: $list" >&2; exit 2; }

names=()
while IFS= read -r line || [[ -n $line ]]; do
  line=${line%%#*}
  read -r line <<<"$line" || true
  [[ -n $line ]] && names+=("$line")
done < "$list"
((${#names[@]})) || { echo "no package names in $list" >&2; exit 2; }

bad=0
for n in "${names[@]}"; do
  apk=$repo/x86_64/$n-$ver.apk
  if [[ ! -f $apk ]]; then
    echo "CMD-DEP check: $apk not found (listed in $list)" >&2
    bad=1
    continue
  fi
  info=$(tar --warning=no-unknown-keyword -xzOf "$apk" .PKGINFO) || { echo "cannot read .PKGINFO of $apk" >&2; bad=1; continue; }
  deps=$(sed -n 's/^depend = \(cmd:.*\)$/\1/p' <<<"$info")
  if [[ -n $deps ]]; then
    while IFS= read -r d; do echo "CMD-DEP $n: $d" >&2; done <<<"$deps"
    bad=1
  else
    echo "no-cmd-deps ok: $n"
  fi
done
if ((bad)); then
  echo "packages in $list must not depend on an interpreter: move scripts (#! files) to a -scripts subpackage" >&2
  exit 1
fi
