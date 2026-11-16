#!/usr/bin/env bash
# git-mirror.sh <url> <tag> <commit> [--seed <local-repo>]
# Local bare mirror of <url> under $MIRROR_DIR (default out/cache/git) for the builds: scripts/melange-build.sh points
# git inside melange at it (url.<mirror>.insteadOf), so a build clones from disk instead of the network. The recipes keep
# their upstream URLs and expected-commit checks: only the transport changes.
#
# The mirror ends up holding <tag> (peeled to <commit>, checked) and, recursively, the commit every submodule of
# <commit> pins:
#   superproject  --seed: `git clone --mirror` of a local clone (hardlinks, no network); otherwise, or when <tag> is
#                 still missing, a shallow fetch of just that tag from <url> (depth 1).
#   submodules    one mirror per submodule URL holding only the pinned commit (`git fetch --depth 1 <url> <sha>`,
#                 small even for large histories), on branch pinned-<sha> with HEAD on it, so `git submodule update
#                 --single-branch` finds it.
# Mirrors that already hold what is needed are not touched (no network). Paths: <host>/<path>.git of the URL.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
cd "$here/.."

usage() { die "usage: git-mirror.sh <url> <tag> <commit> [--seed <local-repo>]"; }
(($# == 3 || $# == 5)) || usage
url=$1 tag=$2 commit=$3 seed=
if (($# == 5)); then [[ $4 == --seed ]] || usage; seed=$5; fi
[[ $url =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+$ ]] || die "bad url: $url"
[[ $tag =~ ^[A-Za-z0-9._/-]+$ ]] || die "bad tag: $tag"
[[ $commit =~ ^[0-9a-f]{40}$ ]] || die "bad commit: $commit"
mirror_root=${MIRROR_DIR:-out/cache/git}
mkdir -p "$mirror_root"
mirror_root=$(cd "$mirror_root" && pwd)

# mirror_path <url>: <root>/<host>/<path>.git (a trailing .git of the URL is not doubled)
mirror_path() {
  local p=${1#https://}
  printf '%s/%s.git\n' "$mirror_root" "${p%.git}"
}

has_commit() { git --git-dir="$1" cat-file -e "$2^{commit}" 2> /dev/null; }

# submodules <git-dir> <commit>: mirror every submodule <commit> pins (recursively)
submodules() {
  local gd=$1 c=$2 mods name path sub_url sha
  mods=$(git --git-dir="$gd" show "$c:.gitmodules" 2> /dev/null) || return 0
  while read -r name; do
    path=$(git config -f <(printf '%s\n' "$mods") "submodule.$name.path")
    sub_url=$(git config -f <(printf '%s\n' "$mods") "submodule.$name.url")
    sha=$(git --git-dir="$gd" ls-tree "$c" -- "$path" | awk '$2 == "commit" {print $3}')
    [[ -n $sha ]] || die "$url@$c: no gitlink for submodule $name ($path)"
    pinned "$sub_url" "$sha"
  done < <(git config -f <(printf '%s\n' "$mods") --name-only --get-regexp '^submodule\..*\.path$' |
    sed -E 's/^submodule\.(.*)\.path$/\1/')
}

# pinned <url> <sha>: mirror of <url> that holds <sha> on branch pinned-<sha> (HEAD), then its own submodules
pinned() {
  local u=$1 sha=$2 gd
  [[ $u =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+$ ]] || die "submodule url not supported: $u"
  gd=$(mirror_path "$u")
  if ! has_commit "$gd" "$sha"; then
    [[ -d $gd ]] || git init -q --bare "$gd"
    log_info "fetching $u $sha (depth 1)"
    retry 3 git --git-dir="$gd" fetch -q --depth 1 "$u" "$sha"
    has_commit "$gd" "$sha" || die "$u: $sha not fetched"
  fi
  git --git-dir="$gd" update-ref "refs/heads/pinned-$sha" "$sha"
  git --git-dir="$gd" symbolic-ref HEAD "refs/heads/pinned-$sha"
  git --git-dir="$gd" config uploadpack.allowAnySHA1InWant true
  log_info "mirror ok: $u @ $sha"
  submodules "$gd" "$sha"
}

top=$(mirror_path "$url")
if [[ ! -d $top && -n $seed ]]; then
  [[ -d $seed ]] || die "seed is not a directory: $seed"
  log_info "seeding $top from $seed (local clone, no network)"
  git clone -q --mirror "$seed" "$top"
  git --git-dir="$top" remote set-url origin "$url"
fi
[[ -d $top ]] || git init -q --bare "$top"
if [[ $(git --git-dir="$top" rev-parse -q --verify "refs/tags/$tag^{commit}" || true) != "$commit" ]]; then
  log_info "fetching tag $tag from $url (depth 1)"
  retry 3 git --git-dir="$top" fetch -q --no-tags --depth 1 "$url" "+refs/tags/$tag:refs/tags/$tag"
fi
got=$(git --git-dir="$top" rev-parse -q --verify "refs/tags/$tag^{commit}" || true)
[[ $got == "$commit" ]] || die "$url: tag $tag is ${got:-missing}, expected $commit"
git --git-dir="$top" config uploadpack.allowAnySHA1InWant true
log_info "mirror ok: $url $tag @ $commit"
submodules "$top" "$commit"
