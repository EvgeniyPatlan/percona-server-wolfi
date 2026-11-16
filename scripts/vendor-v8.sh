#!/usr/bin/env bash
# vendor-v8.sh [version-file]
# Fetches the V8 source tree (depot_tools, inside the depot_env tool container) and packs it into the
# deterministic tarball sources/v8-<v8_tag>.tar.gz, then prints its sha256 for v8_src_sha256 in the
# version file and exits 1 unless the version file already holds that value (first run: paste it, commit,
# re-run). Needs several GB of disk and network; run it on the build host (make vendor-v8).
#
# Hooks: DEPS has many hooks; only `lastchange` is needed for a gcc/use_sysroot=false x64 static build
# (it writes build/util/LASTCHANGE*, which gn reads, and which cannot be regenerated once .git is
# stripped). sysroot/clang/toolchain hooks are skipped on purpose (use_sysroot=false, is_clang=false).
# The pinned gn binary (buildtools/linux64/gn, a CIPD dep, not a hook) comes with the sync.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$here/lib/common.sh"

# make_tarball <parent-dir> <dir-name> <dest.tar.gz> <source_date_epoch>
# Deterministic: sorted names, fixed mtime/owner, no gzip timestamp, `.git` entries excluded.
make_tarball() {
  local parent=$1 name=$2 dest=$3 epoch=$4 part
  [[ -d $parent/$name ]] || { log_warn "no such directory: $parent/$name"; return 1; }
  part=$dest.part
  mkdir -p "$(dirname "$dest")"
  rm -f "$part"
  if ! { tar -C "$parent" --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
        --exclude=.git -cf - "$name" | gzip -n >"$part"; }; then
    rm -f "$part"
    return 1
  fi
  mv -f "$part" "$dest"
}

# Runs inside the depot_env container (cwd /work, user = host uid). $V8_TAG, $WORKDIR come from -e.
inner_fetch() {
  cat <<'INNER'
set -euo pipefail
export HOME="$WORKDIR/home" DEPOT_TOOLS_UPDATE=0
mkdir -p "$HOME" "$WORKDIR"
cd "$WORKDIR"
[[ -d depot_tools ]] || git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools
export PATH="$PWD/depot_tools:$PATH"
# DEPOT_TOOLS_UPDATE=0 also skips the bootstrap (bundled python3 + cipd), without which gclient/fetch refuse to run
# ("python3_bin_reldir.txt not found"); ensure_bootstrap does it for the current checkout without updating it.
ensure_bootstrap
[[ -d v8 ]] || fetch --nohooks --no-history v8
cd v8
gclient sync -D --force --nohooks --no-history --revision "tags/$V8_TAG"
# the only hook we need (see vendor-v8.sh header)
python3 build/util/lastchange.py -o build/util/LASTCHANGE
test -s build/util/LASTCHANGE
# the recipe's GN_BIN fallback relies on the pinned gn binary being in the tree: fail hard if it is not
test -x buildtools/linux64/gn || { echo "ERROR: buildtools/linux64/gn missing after sync" >&2; exit 1; }
INNER
}

# check_recorded_sha <version-file> <sha>: v8_src_sha256 in the version file must equal the tarball's sha. A TODO or
# empty value stops here (exit 1) so `make phase-a` / `make all` do not go on to build packages that need v8.
check_recorded_sha() {
  local vf=$1 sha=$2 rec
  rec=$(vars_get "$vf" v8_src_sha256 2>/dev/null) || rec=
  case $rec in
    '' | TODO*)
      log_warn "v8_src_sha256 is not set in $vf (value: '${rec}')"
      echo "STOP: paste v8_src_sha256: \"$sha\" into $vf, commit, re-run (make all / make phase-a)" >&2
      return 1 ;;
    "$sha") log_info "v8_src_sha256 in $vf matches the tarball" ;;
    *)
      echo "v8_src_sha256 in $vf ($rec) differs from the vendored tarball ($sha): the vendoring is not" \
        "reproducible or the pin is stale; investigate before changing the pin" >&2
      return 1 ;;
  esac
}

# main [--check] [version-file]: --check only hashes an existing sources/v8-<tag>.tar.gz and runs check_recorded_sha
# (no fetch; used by `make vendor-v8` when the tarball is already there).
main() {
  local check=0
  if [[ ${1:-} == --check ]]; then check=1; shift; fi
  local vf=${1:-${VERSION_FILE:-versions/9.7.yaml}} tag epoch workdir dest sha
  cd "$here/.."
  tag=$(vars_get "$vf" v8_tag)
  epoch=$(vars_get "$vf" source_date_epoch)
  workdir=out/v8-src
  dest=${SOURCES_DIR:-sources}/v8-$tag.tar.gz
  if ((check)); then
    [[ -s $dest ]] || die "no $dest: run make vendor-v8 (FORCE=1 to re-vendor)"
    sha=$(sha256sum "$dest" | cut -d' ' -f1)
    printf 'v8_src_sha256: "%s"\n' "$sha"
    check_recorded_sha "$vf" "$sha"
    return
  fi
  mkdir -p "$workdir"
  log_info "fetching V8 $tag with depot_tools (large download)"
  tool depot_env -u "$(id -u):$(id -g)" -e "V8_TAG=$tag" -e "WORKDIR=/work/$workdir" -- \
    bash -c "$(inner_fetch)"
  log_info "packing $dest"
  make_tarball "$workdir" v8 "$dest" "$epoch"
  sha=$(sha256sum "$dest" | cut -d' ' -f1)
  log_info "done: $dest ($(du -h "$dest" | cut -f1))"
  printf 'v8_src_sha256: "%s"\n' "$sha"
  check_recorded_sha "$vf" "$sha"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
