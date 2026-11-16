#!/usr/bin/env bash
# repro-images.sh <image>...
# Image reproducibility (spec section 9): a second, independent build of each image from the lock file the first
# build used (images/<name>.lock.json, so the same locked apks), compared by index digest with the first build
# (out/results/<name>.digest from `make images`). The second build uses a fresh apko cache, its own output dirs
# (out/repro-images/{images,results}) and its own registry namespace ($REGISTRY/repro/...), so it never overwrites the
# first build's tags, digests or SBOMs that scan/sign use. RELOCK is cleared: the lock files must not change.
# Prints the verify-repro.sh line per image; exit 1 if any digest differs.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
cd "$here/.."

(($#)) || die "usage: repro-images.sh <image>..."
build=${APKO_BUILD:-$here/apko-build.sh}
images_dir=${IMAGES_DIR:-images}
results=${RESULTS_DIR:-out/results}
repro=${REPRO_DIR:-out/repro-images}
registry=${REGISTRY:-localhost:5000}

declare -A locksum=()
for i in "$@"; do
  [[ -s $results/$i.digest ]] || die "no first-build digest $results/$i.digest: run make images first"
  [[ -s $images_dir/$i.lock.json ]] || die "no lock file $images_dir/$i.lock.json: run make images first (and commit it)"
  locksum[$i]=$(sha256sum "$images_dir/$i.lock.json" | cut -d' ' -f1)
done

# clean second build: nothing reused from the first one but the lock files and the apk repo
rm -rf -- "${repro:?}/apko-cache" "${repro:?}/images" "${repro:?}/results"
mkdir -p "$repro/apko-cache" "$repro/images" "$repro/results"

rc=0
for i in "$@"; do
  log_info "second build of $i (fresh cache $repro/apko-cache, registry $registry/repro)"
  if ! env -u RELOCK REGISTRY="$registry/repro" RESULTS_DIR="$repro/results" OUT_IMAGES="$repro/images" \
    APKO_CACHE="$repro/apko-cache" IMAGES_DIR="$images_dir" "$build" "$i"; then
    log_warn "second build of $i failed"
    rc=1
    continue
  fi
  if [[ $(sha256sum "$images_dir/$i.lock.json" | cut -d' ' -f1) != "${locksum[$i]}" ]]; then
    log_warn "$i: lock file changed during the second build ($images_dir/$i.lock.json)"
    rc=1
    continue
  fi
  "$here/verify-repro.sh" images "$results/$i.digest" "$repro/results/$i.digest" || rc=1
done
exit "$rc"
