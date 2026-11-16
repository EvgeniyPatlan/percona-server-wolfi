#!/usr/bin/env bash
# fetch-all-sources.sh [versions.yaml]: fetch every pinned tarball into
# $SOURCES_DIR (default sources/). Pairs pinned TODO-UNRESOLVED are skipped.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

file=${1:-versions/9.7.yaml}
dir=${SOURCES_DIR:-sources}

while read -r url sha base; do
  if [[ $sha == TODO-UNRESOLVED ]]; then
    log_warn "skipping $base: sha256 is TODO-UNRESOLVED"
    continue
  fi
  "$here/fetch-sources.sh" "$url" "$sha" "$dir/$base"
done < <("$here/list-source-pairs.sh" "$file")
