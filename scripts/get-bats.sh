#!/usr/bin/env bash
# Vendor bats-core at a pinned tag into out/tools/bats.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

BATS_TAG=v1.11.1
dest=${BATS_DIR:-out/tools/bats}
if [[ -x $dest/bin/bats ]]; then
  log_info "bats already vendored at $dest"
  exit 0
fi
rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
retry 4 git clone --depth 1 --branch "$BATS_TAG" https://github.com/bats-core/bats-core "$dest"
log_info "bats $BATS_TAG vendored at $dest"
