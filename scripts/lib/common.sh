#!/usr/bin/env bash
# Common helpers, meant to be sourced. Does not change shell options.

log_info() { printf '[%s] INFO  %s\n' "$(ts)" "$*" >&2; }
log_warn() { printf '[%s] WARN  %s\n' "$(ts)" "$*" >&2; }
die() { printf '[%s] ERROR %s\n' "$(ts)" "$*" >&2; exit 1; }

# ts -> YYYYmmddTHHMMSSZ (UTC)
ts() { date -u +%Y%m%dT%H%M%SZ; }

# vars_get <file> <key>: value of flat "key: value" YAML; strips quotes/comments.
vars_get() {
  local file=$1 key=$2 line val
  [[ -r $file ]] || { echo "cannot read file: $file" >&2; return 1; }
  line=$(grep -E "^${key}:[[:space:]]" "$file" | head -n1 || true)
  if [[ -z $line ]]; then
    echo "missing key: $key" >&2
    return 1
  fi
  val=${line#"${key}:"}
  val=${val#"${val%%[![:space:]]*}"}
  if [[ $val == \"* ]]; then
    val=${val#\"}; val=${val%%\"*}
  elif [[ $val == \'* ]]; then
    val=${val#\'}; val=${val%%\'*}
  else
    val=${val%%[[:space:]]#*}
    val=${val%"${val##*[![:space:]]}"}
  fi
  printf '%s\n' "$val"
}

# retry <n> <cmd...>: run up to n times, backoff 2,4,8... seconds.
retry() {
  local n=$1 i delay=2
  shift
  for ((i = 1; i <= n; i++)); do
    if "$@"; then return 0; fi
    if ((i < n)); then
      log_warn "attempt $i/$n failed: $*; retrying in ${delay}s"
      sleep "${RETRY_SLEEP:-$delay}"
      delay=$((delay * 2))
    fi
  done
  return 1
}

# tool <name> [docker-run-args...] -- <cmd args...>
tool() {
  local name=$1 image
  shift
  image=$(vars_get "${TOOLS_FILE:-versions/tools.yaml}" "$name") || return 1
  local -a runargs=()
  while (($#)) && [[ $1 != -- ]]; do runargs+=("$1"); shift; done
  (($#)) && shift
  ${DOCKER:-docker} run --rm -v "$PWD:/work" -w /work "${runargs[@]}" "$image" "$@"
}

# Paths whose content goes into the apks. Commits that touch only other paths (docs/, tests/, images/*.lock.json, ...)
# do not change the commit recorded in the apks, so committing a lock file or a doc never invalidates the apk
# checksums pinned by images/*.lock.json.
BUILD_INPUT_PATHS=(packages scripts versions mk Makefile)

# build_commit [extra-pathspec...]: the commit to record in a build (melange --git-commit, image revision): the last
# commit that touched BUILD_INPUT_PATHS (plus the extra pathspecs) in GIT_REPO (default .). Uncommitted changes under
# those paths give <sha>-dirty with a warning; RELEASE=1 refuses that unless ALLOW_DIRTY=1. REPRO_GIT_COMMIT
# overrides detection (iteration only). Prints the value; returns 1 on error.
build_commit() {
  local gr=${GIT_REPO:-.} c
  local -a paths=("${BUILD_INPUT_PATHS[@]}" "$@")
  if [[ -n ${REPRO_GIT_COMMIT:-} ]]; then
    printf '%s\n' "$REPRO_GIT_COMMIT"
    return 0
  fi
  c=$(git -C "$gr" log -1 --format=%H -- "${paths[@]}") || {
    log_warn "cannot read git history in $gr (set REPRO_GIT_COMMIT)"
    return 1
  }
  if [[ -z $c ]]; then
    log_warn "no commit in $gr touches the build inputs (${paths[*]}); commit them or set REPRO_GIT_COMMIT"
    return 1
  fi
  if [[ -n $(git -C "$gr" status --porcelain -- "${paths[@]}") ]]; then
    if [[ ${RELEASE:-} == 1 && ${ALLOW_DIRTY:-} != 1 ]]; then
      log_warn "dirty build inputs (${paths[*]}): commit or stash (or ALLOW_DIRTY=1)"
      return 1
    fi
    log_warn "dirty build inputs: recording ${c}-dirty"
    c=$c-dirty
  fi
  printf '%s\n' "$c"
}
