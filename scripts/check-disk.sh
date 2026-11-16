#!/usr/bin/env bash
# Free-space preflight. MIN_GB (default 100); DF_CMD prints free whole GB.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

min=${MIN_GB:-100}
default_df() { df -BG --output=avail "${CHECK_PATH:-.}" | tail -n1 | tr -dc '0-9'; }
have=$(${DF_CMD:-default_df})
[[ $have =~ ^[0-9]+$ ]] || die "could not determine free space (got '$have')"
if ((have < min)); then
  die "need $min GB free, have $have"
fi
log_info "disk ok: $have GB free (need $min)"
