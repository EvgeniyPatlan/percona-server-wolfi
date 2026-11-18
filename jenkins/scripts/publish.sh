#!/usr/bin/env bash
# publish.sh <org> <suffix> [image...]: copy built, signed images from the local registry to Docker Hub.
#
# For each image (default: all of mk/images.mk IMAGES): the index digest of out/results/<image>.digest and every tag
# the local registry gives that digest; each tag is pushed as <tag><suffix> to $DEST_REGISTRY/<org>/<repo> with
# `oras copy -r`, which keeps the digest and copies the referrers (the cosign signature and the SBOM attestation
# bundles). Then, against the pushed digest: every pushed tag must resolve to it, `cosign verify` and
# `cosign verify-attestation --type spdxjson` must pass with $COSIGN_PUB (also checked on the local image before
# anything is pushed). Any failure stops the script.
#
# <org>    one of $ALLOWED_ORGS (default "percona perconalab")
# <suffix> -wolfi, optionally followed by -<word> (e.g. -wolfi-ci): never empty, so the official tags are never written
# Env: COSIGN_PUB (required: public key the images were signed with), SRC_REGISTRY (localhost:5000),
#      DEST_REGISTRY (docker.io), DOCKER_USER + DOCKER_PASS (registry login; both unset = anonymous, for tests),
#      DEST_PLAIN_HTTP=1 (a plain-HTTP destination, tests only), RESULTS_DIR (out/results), DRY_RUN=1 (print the
#      plan, push nothing), CURL (curl).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here/../.."
# shellcheck source=../../scripts/lib/common.sh
. scripts/lib/common.sh
# shellcheck source=lib.sh
. jenkins/scripts/lib.sh

(($# >= 2)) || die "usage: publish.sh <org> <suffix> [image...]"
org=$1 suffix=$2
shift 2
allowed=" ${ALLOWED_ORGS:-percona perconalab} "
[[ $allowed == *" $org "* ]] || die "org $org is not one of:$allowed"
[[ $suffix =~ ^-wolfi(-[a-z0-9]+)*$ ]] || die "bad suffix '$suffix': must be -wolfi or -wolfi-<word>"
src=${SRC_REGISTRY:-localhost:5000}
dest=${DEST_REGISTRY:-docker.io}
results=${RESULTS_DIR:-out/results}
curl_cmd=${CURL:-curl}
images=("$@")
((${#images[@]})) || read -r -a images <<< "$(images_list)"
for i in "${images[@]}"; do known_image "$i" || die "unknown image: $i"; done

if [[ ${DRY_RUN:-0} != 1 ]]; then
  [[ -n ${COSIGN_PUB:-} && -r $COSIGN_PUB ]] || die "COSIGN_PUB must name the cosign public key (got '${COSIGN_PUB:-}')"
  COSIGN_PUB=$(cd "$(dirname "$COSIGN_PUB")" && pwd)/$(basename "$COSIGN_PUB")
fi

# Registry login, only inside the tool containers: a throwaway docker config outside the repo, removed on exit.
cfg=$(mktemp -d)
trap 'rm -rf "${cfg:?}"' EXIT
chmod 700 "$cfg"
if [[ -n ${DOCKER_USER:-} || -n ${DOCKER_PASS:-} ]]; then
  [[ -n ${DOCKER_USER:-} && -n ${DOCKER_PASS:-} ]] || die "set both DOCKER_USER and DOCKER_PASS"
  case $dest in docker.io | index.docker.io | registry-1.docker.io) key=https://index.docker.io/v1/ ;; *) key=$dest ;; esac
  auth=$(printf '%s:%s' "$DOCKER_USER" "$DOCKER_PASS" | base64 | tr -d '\n')
  (umask 077 && printf '{"auths":{"%s":{"auth":"%s"}}}\n' "$key" "$auth" > "$cfg/config.json")
  unset auth
else
  echo '{}' > "$cfg/config.json"
fi
run=(--user "$(id -u):$(id -g)" -e HOME=/tmp --network host -v "$cfg:/tmp/.docker:ro")
oras_http=(--from-plain-http)
resolve_http=() cosign_http=()
if [[ ${DEST_PLAIN_HTTP:-0} == 1 ]]; then
  oras_http+=(--to-plain-http)
  resolve_http=(--plain-http)
  cosign_http=(--allow-http-registry)
fi

# local_tags <repo> <digest>: the tags of <repo> in the local registry that point at <digest> (cosign's sha256-* tags
# are skipped).
local_tags() {
  local repo=$1 digest=$2 t got
  for t in $("$curl_cmd" -fsS "http://$src/v2/$repo/tags/list" | python3 -I -c \
    'import json, sys; print(" ".join(json.load(sys.stdin).get("tags") or []))'); do
    [[ $t == sha256-* ]] && continue
    got=$("$curl_cmd" -fsS -o /dev/null -I -w '%header{docker-content-digest}' \
      -H 'Accept: application/vnd.oci.image.index.v1+json' -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
      -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
      -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "http://$src/v2/$repo/manifests/$t")
    [[ $got == "$digest" ]] && echo "$t"
  done
  return 0
}

for i in "${images[@]}"; do
  df=$results/$i.digest
  [[ -s $df ]] || die "no digest file $df (build and sign $i first)"
  digest=$(head -n1 "$df")
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "bad digest in $df"
  repo=$(image_repo "$i")
  mapfile -t tags < <(local_tags "$repo" "$digest")
  ((${#tags[@]})) || die "$i: no tag in $src/$repo points at $digest"
  out=()
  for t in "${tags[@]}"; do out+=("$t$suffix"); done
  target=$dest/$org/$repo
  log_info "$i: $src/$repo@$digest -> $target:{$(IFS=,; echo "${out[*]}")}"
  [[ ${DRY_RUN:-0} == 1 ]] && continue

  cosign=(tool cosign "${run[@]}" -v "$COSIGN_PUB:/keys/cosign.pub:ro" --)
  # Nothing unsigned leaves the build host: the source must verify before the copy, the destination after it.
  verify() { # <ref> <cosign flags...>
    local ref=$1
    shift
    "${cosign[@]}" verify --key /keys/cosign.pub "$@" --insecure-ignore-tlog "$ref" > /dev/null ||
      die "$ref: cosign verify failed"
    "${cosign[@]}" verify-attestation --type spdxjson --key /keys/cosign.pub "$@" --insecure-ignore-tlog \
      "$ref" > /dev/null || die "$ref: SBOM attestation does not verify"
  }
  verify "$src/$repo@$digest" --allow-http-registry
  ci_tool oras "${run[@]}" -- copy -r "${oras_http[@]}" "$src/$repo@$digest" "$target:$(IFS=,; echo "${out[*]}")"
  for t in "${out[@]}"; do
    got=$(ci_tool oras "${run[@]}" -- resolve "${resolve_http[@]}" "$target:$t")
    [[ $got == "$digest" ]] || die "$target:$t resolves to $got, expected $digest"
  done
  verify "$target@$digest" "${cosign_http[@]}"
  log_info "$i: published and verified $target@$digest"
done
