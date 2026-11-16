#!/usr/bin/env bash
# melange-build.sh <name> [--workspace-root <dir>] [--out <repo-dir>] [--no-cache] [--deps-repo <repo-dir>]
# Renders packages/<name>/melange.yaml.tmpl and builds it with melange (privileged container).
# melange copies --source-dir into the build and the test workspace (/home/build), so a per-package
# source dir is staged first: everything in packages/<name>/ except the template (patches/, tests/,
# files/), scripts/check-build-path-leaks.sh as build-tools/check-build-path-leaks.sh, plus every file in the
# sources dir whose name appears in the rendered recipe (hardlinked).
# Output repo defaults to out/repo. --deps-repo is where build dependencies are resolved from (default: the output
# repo); reproducibility builds pass out/repo so the recorded build config and the inputs match the reference build.
# The per-package workspace is deleted first (no stale objects) and again on
# success; after a failed build OR failed `melange test` it is kept on purpose, for debugging.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
# shellcheck source=lib/keys.sh
. "$here/lib/keys.sh"
cd "$here/.."

usage() { die "usage: melange-build.sh <name> [--workspace-root <dir>] [--out <repo-dir>] [--no-cache] [--deps-repo <repo-dir>]"; }
(($#)) || usage
name=$1
shift
ws_root=out/workspace repo=out/repo cache=1 deps=
while (($#)); do
  case $1 in
    --workspace-root) (($# >= 2)) || usage; ws_root=$2; shift 2 ;;
    --out) (($# >= 2)) || usage; repo=$2; shift 2 ;;
    --no-cache) cache=0; shift ;;
    --deps-repo) (($# >= 2)) || usage; deps=$2; shift 2 ;;
    *) usage ;;
  esac
done
# Absolute paths under $PWD are made relative: the container sees $PWD only as /work (its cwd).
rel() { if [[ $1 == "$PWD"/* ]]; then printf '%s\n' "${1#"$PWD"/}"; else printf '%s\n' "$1"; fi; }
[[ $name =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "bad package name: $name"

version_file=${VERSION_FILE:-versions/9.7.yaml}
pkgdir=${PKG_DIR:-packages}/$name
tmpl=$pkgdir/melange.yaml.tmpl
stage=${STAGE_DIR:-out/stage}/$name
rendered=${RENDER_DIR:-out/rendered/packages}/$name.yaml
sources=${SOURCES_DIR:-sources}
deps=$(rel "${deps:-$repo}")
ws_root=$(rel "$ws_root") repo=$(rel "$repo") sources=$(rel "$sources") stage=$(rel "$stage")
rendered=$(rel "$rendered") APK_PUBKEY=$(rel "$APK_PUBKEY")
[[ -r $tmpl ]] || die "no recipe template: $tmpl"
[[ -r $APK_PUBKEY ]] || die "public key not found: $APK_PUBKEY (run make keys)"
[[ -r $KEY_DIR/$APK_KEY_NAME.rsa ]] || die "signing key not found: $KEY_DIR/$APK_KEY_NAME.rsa (run make keys)"
KEY_DIR=$(cd "$KEY_DIR" && pwd) # docker -v needs an absolute host path
epoch=$(vars_get "$version_file" source_date_epoch)
# LEAK_SCAN=warn: the build-path leak scan of the recipes reports but does not fail (scripts/check-build-path-leaks.sh)
case ${LEAK_SCAN:-} in
  '' | fatal | warn) ;;
  *) die "LEAK_SCAN must be fatal or warn, not '$LEAK_SCAN'" ;;
esac

"$here/render.sh" "$tmpl" "$version_file" "$rendered"
# melange records a git commit in every apk (.PKGINFO commit=, .melange.yaml): the last commit that touched the build
# inputs (build_commit in lib/common.sh: packages scripts versions mk Makefile), not HEAD, so commits of docs or of
# images/*.lock.json leave the apks unchanged. Dirty inputs are recorded as <sha>-dirty (RELEASE=1 refuses that unless
# ALLOW_DIRTY=1); REPRO_GIT_COMMIT overrides detection (iteration only). Two builds compared for reproducibility must
# record the same commit.
# shellcheck disable=SC2119 # no extra pathspecs for packages
commit=$(build_commit) || die "cannot determine the build-input commit (see above)"

# pkg_full_version <rendered recipe>: <version>-r<epoch> of the package: block (the apk file name suffix).
pkg_full_version() {
  awk '/^package:/ { p = 1; next } /^[^[:space:]#]/ { p = 0 }
    p && /^  version:/ { v = $2 } p && /^  epoch:/ { e = $2 }
    END { gsub(/"/, "", v); if (v == "") exit 1; print v "-r" (e == "" ? 0 : e) }' "$1"
}

ws=$ws_root/$name
rm_ws() {
  rm -rf "$ws" 2>/dev/null || true
  # build output is root-owned; fall back to removing it from a container
  if [[ -e $ws ]]; then
    tool wolfi_sdk -v "$(cd "$(dirname "$ws")" && pwd):/ws" --entrypoint rm -- -rf "/ws/$(basename "$ws")"
  fi
}
rm_ws
mkdir -p "$ws_root" "$repo" "$sources"

# names_file <basename> <file>: the file mentions <basename> as a whole token (so "foo-1.tar.gz" does not
# match "oo-1.tar.gz" or "foo-1.tar"); regex metacharacters in the name are taken literally.
names_file() {
  local esc tok='[^A-Za-z0-9._+-]'
  esc=$(printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|/]/\\&/g')
  grep -qE -- "(^|$tok)$esc(\$|$tok)" "$2"
}

# stage_sources: fresh $stage = package files (minus the template) + referenced source files.
stage_sources() {
  local f b
  rm -rf "$stage"
  mkdir -p "$stage"
  for f in "$pkgdir"/* "$pkgdir"/.[!.]*; do
    [[ -e $f && ${f##*/} != melange.yaml.tmpl ]] || continue
    cp -a "$f" "$stage/"
  done
  # shared in-container helpers (self-contained scripts), reachable from recipes as build-tools/<name>
  mkdir -p "$stage/build-tools"
  cp -a "$here/check-build-path-leaks.sh" "$stage/build-tools/"
  for f in "$sources"/*; do
    [[ -f $f ]] || continue
    b=${f##*/}
    names_file "$b" "$rendered" || continue
    ln "$f" "$stage/$b" 2>/dev/null || cp -a "$f" "$stage/$b"
  done
}
stage_sources

# Absolute paths outside $PWD are mounted at the same path so melange sees them unchanged.
extra=(-v "$KEY_DIR:/keys:ro")
for p in "$ws_root" "$repo" "$deps" "$stage" "$rendered" "$APK_PUBKEY"; do
  if [[ $p == /* && $p != "$PWD"/* ]]; then extra+=(-v "$p:$p"); fi
done

args=(build "$rendered" --arch x86_64
  --signing-key "/keys/$APK_KEY_NAME.rsa"
  --keyring-append "$APK_PUBKEY"
  --repository-append "$deps"
  --exclude-env-from-recorded-config CCACHE_DIR
  --exclude-env-from-recorded-config CCACHE_MAXSIZE
  --exclude-env-from-recorded-config LEAK_SCAN
  --git-commit "$commit"
  --source-dir "$stage"
  --workspace-dir "$ws"
  --out-dir "$repo")
# Build environment overrides (--env-file; all of them are excluded from the recorded config above, so they never
# change the apks): ccache for cached builds, LEAK_SCAN when set.
envs=()
if ((cache)); then
  mkdir -p out/cache
  envs+=("CCACHE_DIR=/var/cache/melange/ccache" "CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-30G}")
  args+=(--cache-dir out/cache)
fi
if [[ -n ${LEAK_SCAN:-} ]]; then envs+=("LEAK_SCAN=$LEAK_SCAN"); fi
if ((${#envs[@]})); then
  envfile=out/melange.env
  ((cache)) || envfile=out/melange-nocache.env
  mkdir -p out
  printf '%s\n' "${envs[@]}" > "$envfile"
  args+=(--env-file "$envfile")
fi

log_info "building $name (SOURCE_DATE_EPOCH=$epoch) into $repo"
tool melange --privileged -e "SOURCE_DATE_EPOCH=$epoch" "${extra[@]}" -- "${args[@]}"
# packages/<name>/no-cmd-deps: subpackages that go into the distroless image must not have generated cmd:<interpreter>
# dependencies (scripts/check-no-cmd-deps.sh reads the .PKGINFO of the apks just built).
if [[ -f $pkgdir/no-cmd-deps ]]; then
  full=$(pkg_full_version "$rendered") || die "cannot read package version/epoch from $rendered"
  "$here/check-no-cmd-deps.sh" "$repo" "$full" "$pkgdir/no-cmd-deps"
fi
# `melange build` does not run the recipe's test: pipelines; run them (package and subpackages) against
# the freshly built apks. Failing tests fail the build.
# The apks just built are signed with KEY_DIR's key; when APK_PUBKEY is another key (laptop rebuild against the imported
# host repo: deps signed by the host, output by the laptop) the test also trusts the signer's own public key. Only the
# test gets it: the build's recorded config must stay identical to the reference build's.
test_keys=(--keyring-append "$APK_PUBKEY")
if [[ -r $KEY_DIR/$APK_KEY_NAME.rsa.pub ]] && ! cmp -s "$KEY_DIR/$APK_KEY_NAME.rsa.pub" "$APK_PUBKEY"; then
  test_keys+=(--keyring-append "/keys/$APK_KEY_NAME.rsa.pub")
fi
log_info "testing $name"
tool melange --privileged "${extra[@]}" -- test "$rendered" "$name" --arch x86_64 \
  "${test_keys[@]}" --repository-append "$repo" --repository-append "$deps" --source-dir "$stage"
rm_ws
rm -rf "$stage"
log_info "built $name"
