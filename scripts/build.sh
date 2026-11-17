#!/usr/bin/env bash
# build.sh [options] [image...]: build the apks and the images, skipping whatever is already up to date.
# Images: percona-server (distroless), percona-server-dev, percona-xtrabackup, percona-mysql-router, percona-haproxy,
# percona-fluentbit (default: all).
# Only the packages the chosen images need are built: the distroless image does not need percona-mysql-shell or
# percona-telemetry-agent, the xtrabackup image needs percona-server (libs, client) but not the -dev extras, the router
# image needs percona-server (the router is one of its subpackages) and percona-mysql-shell; the haproxy and fluentbit
# images need percona-server (its client) and their docker-scripts package.
#
# A package is rebuilt when its main apk is missing from out/repo, when it has never been built by this script, or when
# its inputs changed since the last successful build: the rendered recipe (so every pin of the version file it uses),
# the files in packages/<name>/, the build scripts, the pinned melange image, the apk key name, and the inputs of the
# packages it is built against (so a v8 change rebuilds percona-server and everything built on it).
# An image is rebuilt when its digest is missing or not in the registry, when its lock file no longer matches the apks
# in out/repo (then it is re-locked: RELOCK=1, commit the new lock file), or when its template, lock file, version
# file, apko-build.sh or the pinned apko image changed.
# Stamps (input hashes of the last successful build) live in out/stamps/. The build commit recorded in the apks is NOT
# an input: a commit alone does not trigger a rebuild. For a release use `make all` (or --force).
#
# Options:
#   -n, --dry-run        print the plan (BUILD/SKIP per package and image, with the reason) and exit
#   -f, --force          rebuild every selected package and image
#   --packages-only      stop after the packages
#   --images-only        do not build packages (the apks must already be in out/repo)
#   --dev-keys           sign with the laptop dev keys (KEY_DIR=$HOME/.config/ps-wolfi-dev)
# Env: KEY_DIR, REGISTRY (default localhost:5000), VERSION_FILE, MAKE_CMD (default make), CURL (default curl).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
cd "$here/.."

usage() { die "usage: build.sh [-n|--dry-run] [-f|--force] [--packages-only|--images-only] [--dev-keys] [percona-server] [percona-server-dev] [percona-xtrabackup] [percona-mysql-router] [percona-haproxy] [percona-fluentbit]"; }

# Build order (mk/packages.mk PACKAGES; tests/unit/build.bats checks they agree) and the local packages each one is
# built against.
ORDER=(mecab mecab-ipadic v8 percona-server percona-mysql-shell percona-xtrabackup percona-telemetry-agent percona-server-docker-scripts percona-xtrabackup-docker-scripts percona-mysql-router-docker-scripts percona-haproxy-docker-scripts percona-fluentbit-docker-scripts)
declare -A DEPS=(
  [mecab]="" [mecab-ipadic]="mecab" [v8]="" [percona-server]="mecab mecab-ipadic v8"
  [percona-mysql-shell]="percona-server" [percona-xtrabackup]="percona-server" [percona-telemetry-agent]=""
  [percona-server-docker-scripts]="percona-server" [percona-xtrabackup-docker-scripts]=""
  [percona-mysql-router-docker-scripts]="percona-server"
  [percona-haproxy-docker-scripts]="percona-server" [percona-fluentbit-docker-scripts]="percona-server"
)
declare -A IMAGE_PKGS=(
  [percona-server]="mecab mecab-ipadic v8 percona-server percona-server-docker-scripts"
  [percona-server-dev]="mecab mecab-ipadic v8 percona-server percona-mysql-shell percona-telemetry-agent percona-server-docker-scripts"
  [percona-xtrabackup]="mecab mecab-ipadic v8 percona-server percona-xtrabackup percona-xtrabackup-docker-scripts"
  [percona-mysql-router]="mecab mecab-ipadic v8 percona-server percona-mysql-shell percona-mysql-router-docker-scripts"
  [percona-haproxy]="mecab mecab-ipadic v8 percona-server percona-haproxy-docker-scripts"
  [percona-fluentbit]="mecab mecab-ipadic v8 percona-server percona-fluentbit-docker-scripts"
)
# registry repository of each image (the -dev image is a tag of percona-server)
declare -A IMAGE_REPO=([percona-server]=percona-server [percona-server-dev]=percona-server [percona-xtrabackup]=percona-xtrabackup
  [percona-mysql-router]=percona-mysql-router [percona-haproxy]=percona-haproxy [percona-fluentbit]=percona-fluentbit)

dry=0 force=0 do_pkgs=1 do_images=1
images=()
while (($#)); do
  case $1 in
    -n | --dry-run) dry=1 ;;
    -f | --force) force=1 ;;
    --packages-only) do_images=0 ;;
    --images-only) do_pkgs=0 ;;
    --dev-keys) export KEY_DIR=$HOME/.config/ps-wolfi-dev ;;
    -h | --help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    percona-server | percona-server-dev | percona-xtrabackup | percona-mysql-router | percona-haproxy | percona-fluentbit) images+=("$1") ;;
    *) usage ;;
  esac
  shift
done
((do_pkgs || do_images)) || die "--packages-only and --images-only exclude each other"
((${#images[@]})) || images=(percona-server percona-server-dev percona-xtrabackup percona-mysql-router percona-haproxy percona-fluentbit)

# shellcheck source=lib/keys.sh
. "$here/lib/keys.sh"
version_file=${VERSION_FILE:-versions/9.7.yaml}
registry=${REGISTRY:-localhost:5000}
make_cmd=${MAKE_CMD:-make}
curl_cmd=${CURL:-curl}
stamps=${STAMP_DIR:-out/stamps}
repo=${APK_REPO:-out/repo}/x86_64
results=${RESULTS_DIR:-out/results}
images_dir=${IMAGES_DIR:-images}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# selected packages, in build order
declare -A want=()
for i in "${images[@]}"; do for p in ${IMAGE_PKGS[$i]}; do want[$p]=1; done; done
pkgs=()
for p in "${ORDER[@]}"; do [[ -z ${want[$p]:-} ]] || pkgs+=("$p"); done

sha() { sha256sum | cut -d' ' -f1; }

# pkg_inputs <name>: input hash of a package (recursive over DEPS); leaves the rendered recipe in $tmp/<name>.yaml
pkg_inputs() {
  local p=$1 d
  scripts/render.sh "packages/$p/melange.yaml.tmpl" "$version_file" "$tmp/$p.yaml" > /dev/null
  {
      echo "rendered"; cat "$tmp/$p.yaml"
      find "packages/$p" -type f ! -name melange.yaml.tmpl -print0 | sort -z | xargs -0 -r sha256sum
      sha256sum scripts/melange-build.sh scripts/check-build-path-leaks.sh scripts/check-no-cmd-deps.sh \
        scripts/render.sh scripts/lib/*.sh
      echo "melange=$(vars_get versions/tools.yaml melange)"
      echo "key=$APK_KEY_NAME"
      for d in ${DEPS[$p]}; do echo "dep $d=$(pkg_inputs "$d")"; done
  } | sha
}

# main_apk <name>: path of the package's own apk (version and epoch from the rendered recipe)
main_apk() {
  local y=$tmp/$1.yaml v e
  v=$(awk '/^package:/{p=1;next} p&&/^[^ ]/{exit} p&&$1=="version:"{gsub(/"/,"",$2);print $2;exit}' "$y")
  e=$(awk '/^package:/{p=1;next} p&&/^[^ ]/{exit} p&&$1=="epoch:"{print $2;exit}' "$y")
  printf '%s/%s-%s-r%s.apk\n' "$repo" "$1" "$v" "${e:-0}"
}

# lock_matches <lock>: every local package the lock pins exists in out/repo with the pinned control checksum
lock_matches() {
  python3 -I - "$1" <<'EOF'
import base64, hashlib, json, os, sys
for p in json.load(open(sys.argv[1]))["contents"]["packages"]:
    url = p.get("url", "")
    if url.startswith(("http://", "https://")):
        continue
    if not os.path.isfile(url):
        print(f"{p['name']}: {url} missing"); sys.exit(1)
    lo, hi = (int(x) for x in p["control"]["range"].split("=")[1].split("-"))
    with open(url, "rb") as f:
        f.seek(lo); got = hashlib.sha1(f.read(hi - lo + 1)).digest()
    algo, want = p["control"]["checksum"].split("-", 1)
    if algo != "sha1" or base64.b64decode(want) != got:
        print(f"{p['name']}: {url} differs from the lock"); sys.exit(1)
EOF
}

# image_inputs <name>: input hash of an image (call after its lock file exists)
image_inputs() {
  {
    sha256sum "$images_dir/$1.apko.yaml.tmpl" "$images_dir/$1.lock.json" "$version_file" scripts/apko-build.sh \
      scripts/render.sh scripts/lib/*.sh
    echo "apko=$(vars_get versions/tools.yaml apko)"
    echo "key=$APK_KEY_NAME"
  } | sha
}

in_registry() { # <image> <digest>
  "$curl_cmd" -sf -o /dev/null -I \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json' \
    "http://$registry/v2/${IMAGE_REPO[$1]}/manifests/$2"
}

run_make() {
  log_info "make $*"
  "$make_cmd" --no-print-directory "$@"
}

# ---- packages ----
if ((do_pkgs)); then
  plan=()
  for p in "${pkgs[@]}"; do
    h=$(pkg_inputs "$p")
    apk=$(main_apk "$p")
    reason=
    if ((force)); then reason="--force"
    elif [[ ! -s $apk ]]; then reason="no $apk"
    elif [[ ! -s $stamps/pkg-$p ]]; then reason="never built by build.sh"
    elif [[ $(cat "$stamps/pkg-$p") != "$h" ]]; then reason="inputs changed"
    fi
    if [[ -n $reason ]]; then
      echo "BUILD package $p ($reason)"
      plan+=("$p")
    else
      echo "SKIP  package $p (up to date)"
    fi
  done
  if ((!dry && ${#plan[@]})); then
    mkdir -p "$stamps"
    run_make sources
    run_make git-mirrors
    for p in "${plan[@]}"; do
      [[ $p != v8 ]] || run_make vendor-v8
      run_make "pkg-$p"
      pkg_inputs "$p" > "$stamps/pkg-$p"
    done
  fi
fi

# ---- images ----
if ((do_images)); then
  ((dry)) || run_make registry-up
  for i in "${images[@]}"; do
    lock=$images_dir/$i.lock.json digest_file=$results/$i.digest
    relock=0 reason=
    # a stale lock is checked first: even with --force, apko-build.sh would otherwise build from it and fail
    if [[ ! -s $lock ]]; then reason="no lock file (first build)"
    elif ! why=$(lock_matches "$lock"); then reason="lock file stale ($why): re-locking"; relock=1
    elif ((force)); then reason="--force"
    elif [[ ! -s $digest_file ]]; then reason="no $digest_file"
    elif ! in_registry "$i" "$(head -n1 "$digest_file")"; then reason="digest not in $registry"
    elif [[ ! -s $stamps/image-$i ]]; then reason="never built by build.sh"
    elif [[ $(cat "$stamps/image-$i") != "$(image_inputs "$i")" ]]; then reason="inputs changed"
    fi
    if [[ -z $reason ]]; then
      echo "SKIP  image $i (up to date)"
      continue
    fi
    echo "BUILD image $i ($reason)"
    ((dry)) && continue
    if ((relock)); then RELOCK=1 run_make "image-$i"; else run_make "image-$i"; fi
    mkdir -p "$stamps"
    image_inputs "$i" > "$stamps/image-$i"
    ((!relock)) || log_warn "$lock was rewritten: review and commit it"
  done
fi
((dry)) || log_info "build.sh done: ${images[*]}"
