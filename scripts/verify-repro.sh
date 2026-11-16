#!/usr/bin/env bash
# verify-repro.sh apks [--subset-of-b] <dirA> <dirB>   compare *.apk by sha256 of their content, the signature segment
#   excluded (scripts/lib/apk-content-hash.py), so builds signed with different keys compare equal (APKINDEX*: ignored).
#   Runs local python3 when present, else the pinned python tool container (APK_HASH_CONTAINER=1 forces the container).
# verify-repro.sh images <refA> <refB>   compare image digests
#   An image argument is a digest string (sha256:<64 hex>), a file holding one (out/results/<name>.digest
#   from apko-build.sh), or a registry ref resolved with
#   `docker buildx imagetools inspect --format '{{.Manifest.Digest}}' <ref>`.
# --subset-of-b: only compare names present in B (a per-package repro repo); names only in A are not reported.
# apks: prints "OK|DIFF|ONLY-IN-A|ONLY-IN-B <apk name without .apk>"; exit 1 on anything but OK. For each DIFF
# runs diffoscope on that pair only -> ${RESULTS_DIR:-out/results}/diffoscope-<name>.html.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
cd "$here/.."

usage() { die "usage: verify-repro.sh apks [--subset-of-b] <dirA> <dirB> | images <refA> <refB>"; }

# list_apks <dir>: "<name>\t<path>" for every .apk directly in <dir> or <dir>/<arch>.
list_apks() {
  local f
  for f in "$1"/*.apk "$1"/*/*.apk; do
    [[ -f $f ]] || continue
    printf '%s\t%s\n' "$(basename "$f" .apk)" "$f"
  done
}

# content_hashes <apk>...: one sha256 per argument, in argument order (signature segment excluded).
content_hashes() {
  local f i=0
  local -a mounts=() args=()
  if [[ -z ${APK_HASH_CONTAINER:-} ]] && command -v python3 >/dev/null 2>&1; then
    python3 -I "$here/lib/apk-content-hash.py" "$@" | cut -f1
    return "${PIPESTATUS[0]}"
  fi
  # container: every file mounted read-only on its own (paths may be outside $PWD)
  for f in "$@"; do
    f=$(cd "$(dirname "$f")" && pwd)/$(basename "$f")
    mounts+=(-v "$f:/cmp/$i.apk:ro")
    args+=("/cmp/$i.apk")
    i=$((i + 1))
  done
  tool python "${mounts[@]}" -- python3 -I /work/scripts/lib/apk-content-hash.py "${args[@]}" | cut -f1
  return "${PIPESTATUS[0]}"
}

# diffoscope_pair <name> <a> <b>: paths under $PWD are given container-relative (/work/...), others are mounted.
diffoscope_pair() {
  local name=$1 a=$2 b=$3 results=${RESULTS_DIR:-out/results} p
  local -a mounts=() paths=()
  mkdir -p "$results"
  results=$(cd "$results" && pwd)
  [[ $results == "$PWD"/* ]] || mounts+=(-v "$results:/out")
  for p in "$a" "$b"; do
    p=$(cd "$(dirname "$p")" && pwd)/$(basename "$p")
    if [[ $p == "$PWD"/* ]]; then
      paths+=("/work/${p#"$PWD"/}")
    else
      mounts+=(-v "$(dirname "$p"):/cmp/${#paths[@]}:ro")
      paths+=("/cmp/${#paths[@]}/$(basename "$p")")
    fi
  done
  local html=/work/${results#"$PWD"/}/diffoscope-$name.html
  [[ $results == "$PWD"/* ]] || html=/out/diffoscope-$name.html
  # diffoscope exits 1 when it finds differences: expected here
  tool diffoscope "${mounts[@]}" -- --html "$html" "${paths[@]}" || true
  log_info "diffoscope report: $results/diffoscope-$name.html"
}

cmd_apks() {
  local subset=0
  if [[ ${1:-} == --subset-of-b ]]; then subset=1; shift; fi
  (($# == 2)) || usage
  local da=$1 db=$2 rc=0 n=0 name pa pb
  [[ -d $da ]] || die "not a directory: $da"
  [[ -d $db ]] || die "not a directory: $db"
  local -A ma=() mb=()
  while IFS=$'\t' read -r name pa; do
    [[ -z ${ma[$name]:-} ]] || die "duplicate apk $name in $da: ${ma[$name]} and $pa"
    ma[$name]=$pa
  done < <(list_apks "$da")
  while IFS=$'\t' read -r name pb; do
    [[ -z ${mb[$name]:-} ]] || die "duplicate apk $name in $db: ${mb[$name]} and $pb"
    mb[$name]=$pb
  done < <(list_apks "$db")
  ((${#ma[@]} + ${#mb[@]})) || die "no .apk files in $da or $db"
  # content hash of every apk present on both sides, one helper call
  local -a both=() files=() hashes=()
  local -A ha=() hb=()
  while IFS= read -r name; do
    [[ -n ${ma[$name]:-} && -n ${mb[$name]:-} ]] || continue
    both+=("$name"); files+=("${ma[$name]}" "${mb[$name]}")
  done < <(printf '%s\n' "${!ma[@]}" | sort)
  if ((${#files[@]})); then
    local out
    out=$(content_hashes "${files[@]}") || die "hashing apks failed"
    mapfile -t hashes <<<"$out"
    ((${#hashes[@]} == ${#files[@]})) || die "hashing apks failed: ${#hashes[@]} hashes for ${#files[@]} files"
    local i
    for i in "${!both[@]}"; do ha[${both[$i]}]=${hashes[$((2 * i))]} hb[${both[$i]}]=${hashes[$((2 * i + 1))]}; done
  fi
  while IFS= read -r name; do
    if ((subset)) && [[ -z ${mb[$name]:-} ]]; then continue; fi
    n=$((n + 1))
    if [[ -z ${mb[$name]:-} ]]; then echo "ONLY-IN-A $name"; rc=1
    elif [[ -z ${ma[$name]:-} ]]; then echo "ONLY-IN-B $name"; rc=1
    elif [[ ${ha[$name]} == "${hb[$name]}" ]]; then echo "OK $name"
    else
      echo "DIFF $name"; rc=1
      diffoscope_pair "$name" "${ma[$name]}" "${mb[$name]}"
    fi
  done < <(printf '%s\n' "${!ma[@]}" "${!mb[@]}" | sort -u)
  log_info "compared $n apk name(s), $( ((rc)) && echo MISMATCH || echo all identical )"
  return "$rc"
}

# image_digest <digest|file|ref> -> sha256:...
image_digest() {
  local v=$1 d
  if [[ $v =~ ^sha256:[0-9a-f]{64}$ ]]; then printf '%s\n' "$v"
  elif [[ -f $v ]]; then
    d=$(tr -d '[:space:]' < "$v")
    [[ $d =~ ^sha256:[0-9a-f]{64}$ ]] || die "not a digest in $v: $d"
    printf '%s\n' "$d"
  else
    d=$(${DOCKER:-docker} buildx imagetools inspect --format '{{.Manifest.Digest}}' "$v") || die "cannot inspect $v"
    d=$(tr -d '[:space:]' <<<"$d")
    [[ $d =~ ^sha256:[0-9a-f]{64}$ ]] || die "unexpected digest for $v: $d"
    printf '%s\n' "$d"
  fi
}

cmd_images() {
  (($# == 2)) || usage
  local a b
  a=$(image_digest "$1") b=$(image_digest "$2")
  if [[ $a == "$b" ]]; then echo "OK $a"; else echo "DIFF $1=$a $2=$b"; return 1; fi
}

(($#)) || usage
sub=$1
shift
case $sub in
  apks) cmd_apks "$@" ;;
  images) cmd_images "$@" ;;
  *) usage ;;
esac
