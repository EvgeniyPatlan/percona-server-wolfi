#!/usr/bin/env bash
# Bundle out/logs, out/results, versions/ and a MANIFEST into out/report-<ts>.tar.gz. The MANIFEST also lists every
# UNEXPECTED-PATH and BUILD-PATH LEAK line of the package build logs in out/logs (with the log file name).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

stamp=$(ts)
out=out/report-$stamp.tar.gz
mkdir -p out/logs out/results versions
# flagged <key> <fixed string>: "<key>: <n distinct lines>" then "  <log>: <line>" for every line of a package build
# log (pkg-*.log, repro-build-*.log) containing the string
flagged() {
  local key=$1 pat=$2 hits line
  # a "/<string>" match is recipe text (the sed that writes the UNEXPECTED-PATH prefix), should melange echo it
  hits=$(cd out/logs && grep -HF -- "$pat" pkg-*.log repro-build-*.log 2>/dev/null | grep -vF -- "/$pat" |
    sed 's#^\([^:]*\):#\1: #' | LC_ALL=C sort -u || true)
  if [[ -z $hits ]]; then
    echo "$key: 0"
    return
  fi
  echo "$key: $(cut -d' ' -f2- <<<"$hits" | LC_ALL=C sort -u | wc -l)"
  while IFS= read -r line; do printf '  %s\n' "$line"; done <<<"$hits"
}
manifest=$(mktemp)
trap 'rm -f "$manifest"' EXIT
{
  echo "timestamp: $stamp"
  echo "git_head: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "git_dirty: $(git status --porcelain 2>/dev/null | wc -l)"
  echo "host: $(uname -srm)"
  echo "docker: $(docker --version 2>/dev/null || echo n/a)"
  # lines that need a decision but do not (always) fail a build: listed so the host run surfaces them
  flagged unexpected_paths 'UNEXPECTED-PATH'
  flagged build_path_leaks 'BUILD-PATH LEAK'
} > "$manifest"
tar czf "$out" --transform "s|^${manifest#/}$|MANIFEST|" "$manifest" out/logs out/results versions
log_info "report written: $out"
echo "$out"
