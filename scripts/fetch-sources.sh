#!/usr/bin/env bash
# fetch-sources.sh <url> <sha256> <dest>: sha256-pinned download.
# Downloads to <dest>.part and renames only after verification.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

(($# == 3)) || die "usage: fetch-sources.sh <url> <sha256> <dest>"
url=$1 want=$2 dest=$3
part=$dest.part

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

if [[ -f $dest && $(sha_of "$dest") == "$want" ]]; then
  log_info "up to date: $dest"
  exit 0
fi

mkdir -p "$(dirname "$dest")"
rm -f "$part"
log_info "fetching $url"
if ! retry 5 "${CURL:-curl}" -fsSL -o "$part" "$url"; then
  rm -f "$part"
  die "download failed: $url"
fi
got=$(sha_of "$part")
if [[ $got != "$want" ]]; then
  rm -f "$part"
  die "sha256 mismatch for $url: expected $want, got $got"
fi
mv -f "$part" "$dest"
log_info "verified $dest"
