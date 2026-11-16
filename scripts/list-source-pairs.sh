#!/usr/bin/env bash
# list-source-pairs.sh <versions.yaml>: print "<url> <sha256> <basename>" for
# every <prefix>_url key that has a matching <prefix>_sha256 key.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

file=${1:?usage: list-source-pairs.sh <versions.yaml>}
[[ -r $file ]] || die "cannot read $file"

while read -r key; do
  prefix=${key%_url}
  grep -qE "^${prefix}_sha256:[[:space:]]" "$file" || continue
  url=$(vars_get "$file" "${prefix}_url")
  sha=$(vars_get "$file" "${prefix}_sha256")
  base=${url%%[?#]*}
  printf '%s %s %s\n' "$url" "$sha" "${base##*/}"
done < <(grep -oE '^[A-Za-z0-9_]+_url:' "$file" | sed 's/:$//')
