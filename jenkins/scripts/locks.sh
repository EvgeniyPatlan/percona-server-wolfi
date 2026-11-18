#!/usr/bin/env bash
# locks.sh <stash|unstash>: carry the image lock files that build.sh generated across ephemeral agents.
# stash:   copies every images/*.lock.json that is not committed to out/ci-locks/ (cached with the incremental state).
# unstash: copies them back, only where git has no committed lock file for that image: committed lock files win.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here/../.."
# shellcheck source=../../scripts/lib/common.sh
. scripts/lib/common.sh

stash=out/ci-locks
shopt -s nullglob
case ${1:-} in
  stash)
    rm -rf "${stash:?}"
    mkdir -p "$stash"
    for f in images/*.lock.json; do
      git ls-files --error-unmatch "$f" > /dev/null 2>&1 || cp "$f" "$stash/"
    done
    log_info "stashed $(find "$stash" -name '*.lock.json' | wc -l) generated lock file(s)"
    ;;
  unstash)
    n=0
    for f in "$stash"/*.lock.json; do
      t=images/$(basename "$f")
      if git ls-files --error-unmatch "$t" > /dev/null 2>&1; then
        log_info "kept the committed $t"
      else
        cp "$f" "$t"
        n=$((n + 1))
      fi
    done
    log_info "unstashed $n lock file(s)"
    ;;
  *) die "usage: locks.sh <stash|unstash>" ;;
esac
