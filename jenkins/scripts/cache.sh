#!/usr/bin/env bash
# cache.sh <restore|save> <entry...>: keep build caches of an ephemeral agent in S3.
#
# An entry is a directory under the repo (sources, out/cache/ccache, out/repo, ...) or volume:<docker volume> (the
# local registry's data, so build.sh sees the images of the last run). Each entry is one object,
# $CACHE_URL/<entry with / as ->.tar.zst, streamed through tar + zstd and the AWS CLI (both pinned containers).
#   save:    upload to <object>.partial, then rename to <object>: a failed tar or upload never replaces a good cache.
#            A missing entry is skipped.
#   restore: an entry that already exists and is not empty is kept as it is; a missing object is skipped (first run).
#            A failed extraction removes what it wrote: no half-restored cache.
# A cache failure never fails the build (a warning, exit 0): every restored file is checked by the build anyway
# (sha256 of tarballs, pinned commits, go.sum, apk signatures). Usage errors exit 1.
# The melange containers leave out/cache/ccache and out/cache/gomodcache owned by root, so those (and volumes) are
# archived and extracted as root with numeric owners; every other directory as the calling user.
# Env: CACHE_URL (required, s3://bucket/prefix), AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN /
#      AWS_DEFAULT_REGION / AWS_ENDPOINT_URL (passed to the AWS CLI), CACHE_ROOT_OWNED (the root-owned dirs, default
#      above), DOCKER.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here/../.."
# shellcheck source=../../scripts/lib/common.sh
. scripts/lib/common.sh
# shellcheck source=lib.sh
. jenkins/scripts/lib.sh

(($# >= 2)) || die "usage: cache.sh <restore|save> <dir|volume:name>..."
action=$1
shift
case $action in restore | save) ;; *) die "unknown action: $action (restore|save)" ;; esac
url=${CACHE_URL:-}
[[ $url =~ ^s3://[a-z0-9][a-z0-9.-]+(/[A-Za-z0-9._/-]*)?$ ]] || die "CACHE_URL must be s3://bucket[/prefix] (got '$url')"
url=${url%/}
docker_cmd=${DOCKER:-docker}
ROOT_OWNED=" ${CACHE_ROOT_OWNED:-out/cache/ccache out/cache/gomodcache} "

for e in "$@"; do
  case $e in
    volume:*) [[ ${e#volume:} =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "bad volume name: $e" ;;
    *) [[ $e =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ && $e != *..* ]] || die "bad entry: $e (a relative dir in the repo)" ;;
  esac
done

aws() { ci_tool aws_cli -i --network host -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
  -e AWS_DEFAULT_REGION -e AWS_ENDPOINT_URL -- "$@"; }

# in_entry <entry> <sh script> [args...]: run a script in wolfi_sdk with the entry's mount, user and working dir. Its
# tar is busybox, so zstd runs as its own stage of the pipe.
in_entry() {
  local e=$1 script=$2
  shift 2
  local -a run=(-i --entrypoint sh)
  case $e in
    volume:*) run+=(-v "${e#volume:}:/v" -w /v) ;;
    *) [[ $ROOT_OWNED == *" $e "* ]] || run+=(--user "$(id -u):$(id -g)") ;;
  esac
  tool wolfi_sdk "${run[@]}" -- -c "set -eo pipefail; $script" sh "$@"
}

# present <entry>: 0 if the entry exists and is not empty.
present() {
  case $1 in
    volume:*) "$docker_cmd" volume inspect "${1#volume:}" > /dev/null 2>&1 &&
      [[ -n $(tool wolfi_sdk -v "${1#volume:}:/v" --entrypoint ls -- -A /v) ]] ;;
    *) [[ -d $1 && -n $(ls -A "$1" 2> /dev/null || echo unreadable) ]] ;;
  esac
}

# wipe <entry>: remove a half-extracted entry (as root: it may hold root-owned files).
wipe() {
  case $1 in
    volume:*) "$docker_cmd" volume rm -f "${1#volume:}" > /dev/null 2>&1 || true ;;
    *) tool wolfi_sdk --entrypoint rm -- -rf "/work/$1" || true ;;
  esac
}

save() {
  local e=$1 obj=$2 size
  if ! present "$e"; then
    log_info "cache save: $e is missing or empty, skipped"
    return 0
  fi
  local src=(.)
  [[ $e == volume:* ]] || src=("$e")
  size=$(in_entry "$e" 'du -sk "$@"' "${src[@]}" 2> /dev/null | awk '{s += $1} END {print s * 1024}') || size=0
  if in_entry "$e" 'tar --numeric-owner -cf - "$@" | zstd -T0 -3 -q' "${src[@]}" |
    aws s3 cp - "$obj.partial" --expected-size "$((size > 0 ? size : 1))" --only-show-errors; then
    aws s3 mv "$obj.partial" "$obj" --only-show-errors && log_info "cache save: $e -> $obj" && return 0
  fi
  aws s3 rm "$obj.partial" --only-show-errors > /dev/null 2>&1 || true
  log_warn "cache save failed: $e (the previous cache, if any, is kept)"
}

restore() {
  local e=$1 obj=$2
  if present "$e"; then
    log_info "cache restore: $e already present, kept"
    return 0
  fi
  if ! aws s3 ls "$obj" > /dev/null 2>&1; then
    log_info "cache restore: no $obj yet, skipped"
    return 0
  fi
  # as root (volumes, root-owned dirs): numeric owners as archived; as the user: owned by the user (-o)
  local opts=--numeric-owner
  case $e in
    volume:*) "$docker_cmd" volume create "${e#volume:}" > /dev/null ;;
    *)
      mkdir -p "$(dirname "$e")"
      [[ $ROOT_OWNED == *" $e "* ]] || opts=-o
      ;;
  esac
  # shellcheck disable=SC2016 # expanded by the container shell
  if aws s3 cp "$obj" - --only-show-errors | in_entry "$e" 'zstd -dcq | tar "$1" -xf -' "$opts"; then
    log_info "cache restore: $obj -> $e"
  else
    wipe "$e"
    log_warn "cache restore failed: $e (removed; the build starts without it)"
  fi
}

for e in "$@"; do
  name=${e//\//-}
  name=${name/:/-}
  "$action" "$e" "$url/$name.tar.zst"
done
