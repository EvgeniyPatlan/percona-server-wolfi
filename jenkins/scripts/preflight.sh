#!/usr/bin/env bash
# preflight.sh <release|incremental|mtr>: checks that take seconds, run before hours of building. Every check is
# printed as OK or FAIL; exit 1 if any failed.
#   all:         docker can run privileged containers (melange); free disk (MIN_GB, default 300 release, 150
#                otherwise, via scripts/check-disk.sh)
#   release:     v8_src_sha256 pinned; keys/ps-wolfi.rsa.pub and keys/cosign.pub committed; images/<image>.lock.json
#                committed for every image (skipped with RELOCK=1 or RELOCK=true, the job parameter); no
#                uncommitted change in the build inputs
#   incremental: v8_src_sha256 pinned
# Env: VERSION_FILE (versions/9.7.yaml), RELOCK, MIN_GB, DOCKER.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here/../.."
# shellcheck source=../../scripts/lib/common.sh
. scripts/lib/common.sh
# shellcheck source=lib.sh
. jenkins/scripts/lib.sh

(($# == 1)) || die "usage: preflight.sh <release|incremental|mtr>"
mode=$1
case $mode in
  release) min_gb=${MIN_GB:-300} ;;
  incremental | mtr) min_gb=${MIN_GB:-150} ;;
  *) die "unknown job: $mode" ;;
esac
vf=${VERSION_FILE:-versions/9.7.yaml}
fails=0
check() { # <description> <command...>
  local d=$1
  shift
  if "$@" > /dev/null 2>&1; then echo "OK    $d"; else echo "FAIL  $d"; fails=$((fails + 1)); fi
}

check "docker runs privileged containers" tool wolfi_sdk --privileged --entrypoint true --
check "at least $min_gb GB free" env MIN_GB="$min_gb" scripts/check-disk.sh
v8_pinned() { [[ $(vars_get "$vf" v8_src_sha256) =~ ^[0-9a-f]{64}$ ]]; }
if [[ $mode != mtr ]]; then
  check "v8_src_sha256 pinned in $vf (make vendor-v8 prints it)" v8_pinned
fi
if [[ $mode == release ]]; then
  for f in keys/ps-wolfi.rsa.pub keys/cosign.pub; do
    check "$f committed" git ls-files --error-unmatch "$f"
  done
  if [[ ${RELOCK:-0} != 1 && ${RELOCK:-} != true ]]; then
    for i in $(images_list); do
      check "images/$i.lock.json committed" git ls-files --error-unmatch "images/$i.lock.json"
    done
  fi
  clean_inputs() { [[ -z $(git status --porcelain -- "${BUILD_INPUT_PATHS[@]}" images) ]]; }
  check "no uncommitted change in ${BUILD_INPUT_PATHS[*]} images" clean_inputs
fi
((fails == 0)) || die "$fails preflight check(s) failed"
log_info "preflight ($mode): all checks passed"
