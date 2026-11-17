#!/usr/bin/env bash
# apko-build.sh <name> [--no-publish]
# Assembles image <name> (images/<name>.apko.yaml.tmpl) from the local signed apk repo with apko:
#   1. render the template with the version file -> out/rendered/images/<name>.apko.yaml
#   2. lock: images/<name>.lock.json pins every package (url + checksum). An existing lock file is used as is
#      (commit it); it is (re)generated only when missing or with RELOCK=1.
#   3. apko build -> out/images/<name>/image.tar (docker load) + SBOMs out/images/<name>/sbom-*.spdx.json
#   4. apko publish -> $REGISTRY (default localhost:5000) with the tags below; the index digest is written to
#      out/results/<name>.digest (compare runs with `scripts/verify-repro.sh images`).
# Tags: percona-server:<series>, :<ps_version>-<ps_release> (+ -<BUILD_ID> when set); the -dev image is the same
# repository with a -dev suffix; percona-xtrabackup:<series>, :<pxb_version>-<pxb_release>;
# percona-mysql-router:<series>, :<ps_version>-<ps_release> (the router is built from the server tree);
# percona-haproxy:<haproxy_series>, :<haproxy_version>; percona-fluentbit:<fluentbit_series>, :<fluentbit_version>;
# percona-orchestrator:<orc_version>, :<orc_version>-<orc_release>;
# percona-server-mysql-operator:<ps_operator_version>, percona-xtradb-cluster-operator:<pxc_operator_version> (one tag
# each, as the official operator images); percona-proxysql3:<proxysql series>, :<proxysql_version>.
# Reproducible inputs: build date from source_date_epoch, VCS autodetection off, the revision annotation is the last
# commit that touched the build inputs or images/*.tmpl (<sha>-dirty when those have uncommitted changes; RELEASE=1
# refuses that unless ALLOW_DIRTY=1).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
# shellcheck source=lib/keys.sh
. "$here/lib/keys.sh"
cd "$here/.."

usage() { die "usage: apko-build.sh <percona-server|percona-server-dev|percona-xtrabackup|percona-mysql-router|percona-haproxy|percona-fluentbit|percona-orchestrator|percona-server-mysql-operator|percona-xtradb-cluster-operator|percona-proxysql3> [--no-publish]"; }
(($#)) || usage
name=$1
shift
publish=1
while (($#)); do
  case $1 in
    --no-publish) publish=0; shift ;;
    *) usage ;;
  esac
done
[[ $name =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "bad image name: $name"

version_file=${VERSION_FILE:-versions/9.7.yaml}
v() { vars_get "$version_file" "$1"; }
ps_full=$(v ps_version)-$(v ps_release)
series=$(v ps_version | cut -d. -f1-2)
# forbid: packages that must not end up in the image (regex on package names, checked against the lock file
# before building). distroless=1: after the build the image's file list must not contain a shell or apk either.
# Rules: no shell/apk and no perl/python in the distroless image; mysqlsh (+ the -jit blob, ruling R4) and the telemetry agent only in
# -dev (and mysqlsh, by owner ruling, in the router image); percona-xtrabackup-docker-scripts and percona-telemetry-agent
# never together (both ship /call-home.sh). The router image has no telemetry agent and no other image's scripts; the
# proxysql3 image has neither, nor mysqlsh or the server (only its client and my_print_defaults).
# The haproxy and fluentbit images: no server, no mysqlsh, no telemetry agent, no other image's scripts; the haproxy
# image takes the -nocaps haproxy only (the default build has a file capability, see its template).
# The orchestrator image has no server, mysqlsh, telemetry agent or other image's scripts.
shells='busybox[a-z0-9-]*|bash|dash|toybox|mksh|zsh|oksh|[a-z0-9-]*-binsh|apk-tools[a-z0-9-]*'
dev_only='percona-mysql-shell[a-z0-9-]*|percona-telemetry-agent'
# distroless only: no script interpreters either. percona-server-scripts (mysqld_safe, ps-admin, ...) and Wolfi's
# jemalloc (jeprof: cmd:perl) are -dev only; the distroless image takes the library alone (libjemalloc2).
interpreters='perl[a-z0-9-]*|python[a-z0-9.-]*|percona-server-scripts|jemalloc'
# others_scripts <x>: every docker-scripts package except percona-<x>-docker-scripts, as a regex alternation
others_scripts() {
  local p out=
  for p in server xtrabackup mysql-router haproxy fluentbit orchestrator proxysql; do
    [[ $p == "$1" ]] || out+="${out:+|}percona-$p-docker-scripts"
  done
  printf '%s\n' "$out"
}
forbid='' distroless=0 epoch_key=source_date_epoch
case $name in
  percona-server) repo_name=percona-server suffix='' full=$ps_full distroless=1
    forbid="$shells|$interpreters|$dev_only|percona-server-docker-scripts|percona-xtrabackup-docker-scripts" ;;
  percona-server-dev) repo_name=percona-server suffix=-dev full=$ps_full forbid='percona-xtrabackup-docker-scripts' ;;
  percona-xtrabackup) repo_name=percona-xtrabackup suffix='' full=$(v pxb_version)-$(v pxb_release) forbid=$dev_only ;;
  percona-mysql-router) repo_name=percona-mysql-router suffix='' full=$ps_full
    forbid='percona-telemetry-agent|percona-server-docker-scripts|percona-xtrabackup-docker-scripts|percona-server-server' ;;
  percona-haproxy) repo_name=percona-haproxy suffix='' full=$(v haproxy_version) series=$(v haproxy_series)
    forbid="$dev_only|percona-server-server|$(others_scripts haproxy)|haproxy-[0-9.]+" ;;
  percona-fluentbit) repo_name=percona-fluentbit suffix='' full=$(v fluentbit_version) series=$(v fluentbit_series)
    forbid="$dev_only|percona-server-server|$(others_scripts fluentbit)" ;;
  percona-orchestrator) repo_name=percona-orchestrator suffix='' full=$(v orc_version)-$(v orc_release) series=$(v orc_version)
    forbid="$dev_only|percona-server-[a-z0-9-]*|percona-mysql-router[a-z0-9-]*|percona-xtrabackup[a-z0-9-]*|$(others_scripts orchestrator)" ;;
  # operator images: the operator's own packages only (no database, client, shell or other image's scripts)
  percona-server-mysql-operator | percona-xtradb-cluster-operator)
    repo_name=$name suffix=''
    if [[ $name == percona-server-mysql-operator ]]; then
      full=$(v ps_operator_version) other=percona-xtradb-cluster-operator epoch_key=ps_operator_source_date_epoch
    else
      full=$(v pxc_operator_version) other=percona-server-mysql-operator epoch_key=pxc_operator_source_date_epoch
    fi
    series=$full
    forbid="${other}[a-z0-9-]*|percona-server|percona-server-(server|client|libs|scripts|docker-scripts|docker-config|rocksdb|js|dev|test)"
    forbid+="|percona-mysql-[a-z0-9-]*|percona-xtrabackup[a-z0-9-]*|percona-telemetry-agent|perl[a-z0-9-]*|python[a-z0-9.-]*"
    forbid+="|$(others_scripts '')" ;;
  percona-proxysql3) repo_name=percona-proxysql3 suffix='' full=$(v proxysql_version) series=$(v proxysql_version | cut -d. -f1-2)
    forbid="$dev_only|percona-server-docker-scripts|percona-xtrabackup-docker-scripts|percona-mysql-router[a-z0-9-]*|percona-server-server"
    forbid+="|$(others_scripts proxysql)" ;;
  *) die "unknown image: $name" ;;
esac

# Absolute paths under $PWD are made relative: the container sees $PWD only as /work (its cwd).
rel() { if [[ $1 == "$PWD"/* ]]; then printf '%s\n' "${1#"$PWD"/}"; else printf '%s\n' "$1"; fi; }
images_dir=$(rel "${IMAGES_DIR:-images}")
tmpl=$images_dir/$name.apko.yaml.tmpl
lock=$images_dir/$name.lock.json
rendered=$(rel "${RENDER_DIR:-out/rendered/images}")/$name.apko.yaml
out=$(rel "${OUT_IMAGES:-out/images}")/$name
results=$(rel "${RESULTS_DIR:-out/results}")
apk_repo=$(rel "${APK_REPO:-out/repo}")
cache=$(rel "${APKO_CACHE:-out/apko-cache}")
APK_PUBKEY=$(rel "$APK_PUBKEY")
registry=${REGISTRY:-localhost:5000}
[[ -r $tmpl ]] || die "no image template: $tmpl"
[[ -r $APK_PUBKEY ]] || die "public key not found: $APK_PUBKEY (run make keys)"
[[ -d $apk_repo ]] || die "apk repo not found: $apk_repo (build the packages first)"

# build date: the server's commit time; the operator images use their operator's (epoch_key above)
epoch=$(v "${epoch_key:-source_date_epoch}")
build_date=$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)

# revision annotation: the last commit that touched the build inputs or the image templates (build_commit in
# lib/common.sh); committing images/*.lock.json or docs does not change it, so the image digest stays reproducible.
commit=$(build_commit 'images/*.tmpl') || die "cannot determine the build-input commit (see above)"

tags=("$registry/$repo_name:$series$suffix")
[[ $full == "$series" ]] || tags+=("$registry/$repo_name:$full$suffix")
if [[ -n ${BUILD_ID:-} ]]; then
  [[ $BUILD_ID =~ ^[A-Za-z0-9._-]+$ ]] || die "bad BUILD_ID: $BUILD_ID"
  tags+=("$registry/$repo_name:$full-$BUILD_ID$suffix")
fi

"$here/render.sh" "$tmpl" "$version_file" "$rendered"
mkdir -p "$out" "$results" "$cache"

# Paths outside $PWD are mounted at the same path. apko runs as the calling user (it needs no privileges:
# file owners in the layers come from the apks and the config, not from the host).
mounts=()
for p in "$images_dir" "$rendered" "$out" "$results" "$apk_repo" "$cache" "$APK_PUBKEY"; do
  if [[ $p == /* && $p != "$PWD"/* ]]; then
    if [[ -d $p ]]; then mounts+=(-v "$p:$p"); else mounts+=(-v "$(dirname "$p"):$(dirname "$p")"); fi
  fi
done
run_apko() {
  tool apko -u "$(id -u):$(id -g)" -e HOME=/tmp -e "SOURCE_DATE_EPOCH=$epoch" "${mounts[@]}" "$@"
}
common=(--arch x86_64 --repository-append "$apk_repo" --keyring-append "$APK_PUBKEY" --cache-dir "$cache")

if [[ ! -f $lock && ${RELEASE:-} == 1 && ${RELOCK:-} != 1 ]]; then
  die "RELEASE=1: no committed lock file $lock (create it with RELOCK=1 / make images-lock and commit it)"
fi
if [[ ! -f $lock || ${RELOCK:-} == 1 ]]; then
  log_info "locking $name -> $lock"
  run_apko -- lock "$rendered" "${common[@]}" --output "$lock"
fi
[[ -s $lock ]] || die "lock file missing or empty: $lock"
if [[ -n $forbid ]]; then
  bad=$(grep -oE "\"name\": *\"($forbid)\"" "$lock" | sed -E 's/.*"([^"]+)"$/\1/' | sort -u | tr '\n' ' ' || true)
  [[ -z $bad ]] || die "$name must not contain: $bad(see $lock; a runtime dependency pulls it in)"
fi

img_args=("${common[@]}" --lockfile "$lock" --sbom-path "$out" --build-date "$build_date" --vcs=false
  --annotations "org.opencontainers.image.revision:$commit")

log_info "building $name (SOURCE_DATE_EPOCH=$epoch, revision $commit)"
rm -f "$out/image.tar"
run_apko -- build "$rendered" "${tags[0]}" "$out/image.tar" "${img_args[@]}"

# image_files <image.tar>: every path in every layer of a `docker load` tarball (manifest.json "Layers"), no leading ./
image_files() {
  local tarball=$1 layer
  [[ -s $tarball ]] || die "no image tarball: $tarball"
  local layers
  layers=$(tar -xOf "$tarball" manifest.json | grep -oE '"Layers": *\[[^]]*\]' | grep -oE '"[^"]+"' | tr -d '"' | grep -v '^Layers$') \
    || die "no layers in $tarball/manifest.json"
  for layer in $layers; do
    tar -xOf "$tarball" "$layer" | tar -tzf - | sed -E 's#^\./##; s#/$##' || die "cannot list layer $layer of $tarball"
  done
}
if ((distroless)); then
  files=$(image_files "$out/image.tar")
  hits=$(grep -xE '(usr/)?s?bin/(sh|ash|bash|dash|busybox|apk|mksh|zsh|oksh)' <<<"$files" | sort -u | tr '\n' ' ' || true)
  [[ -z $hits ]] || die "$name is distroless but the image contains: $hits"
  log_info "distroless check: no shell or apk in $out/image.tar"
fi

if ((publish)); then
  refs=$out/image-refs.txt
  rm -f "$refs"
  log_info "publishing $name: ${tags[*]}"
  run_apko --network host -- publish "$rendered" "${tags[@]}" "${img_args[@]}" --image-refs "$refs"
  [[ -s $refs ]] || die "apko publish wrote no image refs ($refs)"
  # apko writes the per-arch image refs first and the index (what the tags point at) last
  digest=$(tail -n1 "$refs" | grep -oE '@sha256:[0-9a-f]{64}$' | cut -c2- || true)
  [[ -n $digest ]] || die "no index digest in $refs: $(tail -n1 "$refs")"
  printf '%s\n' "$digest" > "$results/$name.digest"
  log_info "published $name: index $digest"
  printf '%s\n' "$digest"
fi
