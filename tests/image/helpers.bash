#!/usr/bin/env bash
# Shared helpers for the image behaviour suites (tests/image/*.bats). Sourced with `load helpers`.
#
# Environment:
#   IMAGE   image under test (default localhost:5000/percona-server:9.7-dev); also exported as PS_IMAGE
#   DOCKER  docker command (default: docker); may hold several words, e.g. "sudo docker"
#   PS_IMAGE_DEV / PS_IMAGE_DISTROLESS  the pair used by the distroless test; derived from IMAGE by the -dev suffix
#   PS_IMAGE_KIND  dev|distroless: kind of IMAGE when its tag does not tell (default: from the tag, see ps_image_kind)
#   PS_PULL  0: do not `docker pull` the images in setup_file (they must then be in the local docker already)
#
# Everything a test creates (containers, volumes, networks) is recorded in $PS_STATE_DIR and removed by ps_cleanup,
# which every suite calls from teardown(), so a failed test leaves nothing behind.

PS_HELPERS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PS_ROOT=$(cd "$PS_HELPERS_DIR/../.." && pwd)
# shellcheck source=../../scripts/lib/common.sh
source "$PS_ROOT/scripts/lib/common.sh"

PS_IMAGE=${PS_IMAGE:-${IMAGE:-localhost:5000/percona-server:9.7-dev}}
PS_TOOLS_FILE=${PS_TOOLS_FILE:-$PS_ROOT/versions/tools.yaml}
PS_STATE_DIR=${PS_STATE_DIR:-${BATS_TEST_TMPDIR:-${BATS_FILE_TMPDIR:-$(mktemp -d)}}/ps-state}

# ps_docker <args...>: the configured docker command.
ps_docker() {
  # shellcheck disable=SC2086 # DOCKER may be a multi-word command
  ${DOCKER:-docker} "$@"
}

# ps_prefix: unique per test, so parallel or leftover runs never collide.
ps_prefix() { printf 'psw-%s-%s\n' "$$" "${BATS_TEST_NUMBER:-0}"; }

# ps_track <kind> <name>: remember a resource for ps_cleanup (kind: containers, volumes, networks).
ps_track() {
  mkdir -p "$PS_STATE_DIR"
  printf '%s\n' "$2" >> "$PS_STATE_DIR/$1"
}

# ps_tool_image <name>: digest-pinned image from versions/tools.yaml (vault, python, wolfi_sdk, ...).
ps_tool_image() { vars_get "$PS_TOOLS_FILE" "$1"; }

# ps_image_kind [image]: prints dev or distroless. Explicit, never inferred from docker: PS_IMAGE_KIND (dev|distroless)
# for $PS_IMAGE, else the tag of the ref (a tag ending in -dev is the -dev image, any other tag the distroless one).
# A ref without a tag (name@sha256:...) needs PS_IMAGE_KIND; returns 1 when the kind cannot be told.
ps_image_kind() {
  local ref=${1:-$PS_IMAGE} name tag
  if [[ -z ${1:-} && -n ${PS_IMAGE_KIND:-} ]]; then
    case $PS_IMAGE_KIND in
      dev | distroless) printf '%s\n' "$PS_IMAGE_KIND"; return 0 ;;
      *) echo "PS_IMAGE_KIND must be dev or distroless, not '$PS_IMAGE_KIND'" >&2; return 1 ;;
    esac
  fi
  name=${ref%%@*}
  name=${name##*/}
  tag=
  if [[ $name == *:* ]]; then tag=${name##*:}; fi
  case $tag in
    '') echo "cannot tell whether $ref is the -dev or the distroless image (no tag): set PS_IMAGE_KIND" >&2; return 1 ;;
    *-dev) echo dev ;;
    *) echo distroless ;;
  esac
}

# ps_pull_images <ref>...: docker pull every ref (apko publishes to the registry only; nothing is in the local docker
# until pulled), then check it is present. Any failure is an error (call it from setup_file: the suite then fails
# instead of skipping). PS_PULL=0 skips the pull (images loaded by hand) but still requires them locally.
ps_pull_images() {
  local ref
  (($#)) || { echo "ps_pull_images: no image refs" >&2; return 1; }
  for ref in "$@"; do
    if [[ ${PS_PULL:-1} != 0 ]]; then
      ps_docker pull "$ref" > /dev/null || { echo "ps_pull_images: cannot pull $ref" >&2; return 1; }
    fi
    ps_docker image inspect "$ref" > /dev/null || { echo "ps_pull_images: image $ref not in the local docker" >&2; return 1; }
  done
}

# ps_image_pair: sets PS_IMAGE_DEV and PS_IMAGE_DISTROLESS from IMAGE (either one of the pair) unless preset.
ps_image_pair() {
  if [[ -z ${PS_IMAGE_DEV:-} || -z ${PS_IMAGE_DISTROLESS:-} ]]; then
    if [[ $PS_IMAGE == *-dev ]]; then
      PS_IMAGE_DEV=$PS_IMAGE
      PS_IMAGE_DISTROLESS=${PS_IMAGE%-dev}
    else
      PS_IMAGE_DISTROLESS=$PS_IMAGE
      PS_IMAGE_DEV=$PS_IMAGE-dev
    fi
  fi
}

# ps_volume <name>: create a docker volume (prefixed, tracked); prints its full name.
ps_volume() {
  local full
  full=$(ps_prefix)-$1
  ps_track volumes "$full"
  ps_docker volume create "$full" > /dev/null || return 1
  printf '%s\n' "$full"
}

# ps_network <name>: create a docker network (prefixed, tracked); prints its full name.
ps_network() {
  local full
  full=$(ps_prefix)-$1
  ps_track networks "$full"
  ps_docker network create "$full" > /dev/null || return 1
  printf '%s\n' "$full"
}

# ps_start <name> [docker-run-args...] [-- mysqld-args...]: docker run -d of $PS_IMAGE; prints the container id.
# Arguments after a literal `--` go after the image (command/server options). The container name is prefixed.
ps_start() {
  local name=$1 full cid
  shift
  local -a dargs=() cmd=()
  while (($#)) && [[ $1 != -- ]]; do
    dargs+=("$1")
    shift
  done
  if (($#)); then shift; fi
  cmd=("$@")
  full=$(ps_prefix)-$name
  ps_track containers "$full"
  cid=$(ps_docker run -d --name "$full" "${dargs[@]}" "$PS_IMAGE" "${cmd[@]}") || return 1
  printf '%s\n' "$cid"
}

# ps_wait_ready <cid> [timeout=120]: wait until the final server answers on TCP (the init-time server is
# --skip-networking, so a ping over TCP cannot be satisfied by it). Fails at once if the container exits.
ps_wait_ready() {
  local cid=$1 timeout=${2:-120} running deadline
  deadline=$((SECONDS + timeout))
  while :; do
    running=$(ps_docker inspect -f '{{.State.Running}}' "$cid" 2> /dev/null) || running=
    if [[ $running != true ]]; then
      echo "ps_wait_ready: container $cid is not running" >&2
      ps_logs "$cid" >&2 || true
      return 1
    fi
    if ps_docker exec "$cid" mysqladmin --no-defaults --protocol=tcp -h127.0.0.1 -uroot ping > /dev/null 2>&1; then
      return 0
    fi
    if ((SECONDS >= deadline)); then
      echo "ps_wait_ready: $cid not ready after ${timeout}s" >&2
      ps_logs "$cid" >&2 || true
      return 1
    fi
    sleep "${PS_POLL_INTERVAL:-1}"
  done
}

# ps_sql <cid> <sql>: run SQL as $PS_SQL_USER (root) with $PS_SQL_PASSWORD (empty) over the socket;
# prints the result without column names (-N -B). The client's stderr is shown only on failure.
ps_sql() {
  local cid=$1 sql=$2 out err rc
  err=$(mktemp)
  out=$(ps_docker exec -i -e "MYSQL_PWD=${PS_SQL_PASSWORD:-}" "$cid" \
    mysql --no-defaults -N -B "-u${PS_SQL_USER:-root}" -e "$sql" 2> "$err") && rc=0 || rc=$?
  if ((rc != 0)); then cat "$err" >&2; fi
  rm -f "$err"
  ((rc == 0)) || return "$rc"
  [[ -z $out ]] || printf '%s\n' "$out"
}

# ps_logs <cid>: stdout and stderr of the container.
ps_logs() { ps_docker logs "$1" 2>&1; }

# ps_rm <cid>: force-remove a container and its anonymous volumes.
ps_rm() { ps_docker rm -f -v "$1" > /dev/null; }

# ps_has_file <cid> <path>: the path exists in the container (docker cp: works without a shell or coreutils).
ps_has_file() { ps_docker cp "$1:$2" - > /dev/null 2>&1; }

# ps_peek <cid> <cmd...>: run a command from the python tool image inside the pid and network namespaces of the
# container (works for the distroless image, which has no cat/ps/grep). Root with SYS_PTRACE may read /proc/<pid>.
ps_peek() {
  local cid=$1
  shift
  ps_docker run --rm --user 0 --cap-add SYS_PTRACE --pid "container:$cid" --network "container:$cid" \
    "$(ps_tool_image python)" "$@"
}

# ps_wait_exit <cid> [timeout=120]: wait for the container to exit; prints its exit code.
ps_wait_exit() {
  local cid=$1 timeout=${2:-120} deadline running
  deadline=$((SECONDS + timeout))
  while :; do
    running=$(ps_docker inspect -f '{{.State.Running}}' "$cid") || return 1
    if [[ $running != true ]]; then
      ps_docker inspect -f '{{.State.ExitCode}}' "$cid"
      return 0
    fi
    if ((SECONDS >= deadline)); then
      echo "ps_wait_exit: $cid still running after ${timeout}s" >&2
      return 1
    fi
    sleep "${PS_POLL_INTERVAL:-1}"
  done
}

# ps_cleanup: remove every tracked container, then network, then volume. Never fails.
ps_cleanup() {
  local kind name
  for kind in containers networks volumes; do
    [[ -f $PS_STATE_DIR/$kind ]] || continue
    while read -r name; do
      [[ -n $name ]] || continue
      case $kind in
        containers) ps_docker rm -f -v "$name" > /dev/null 2>&1 || true ;;
        networks) ps_docker network rm "$name" > /dev/null 2>&1 || true ;;
        volumes) ps_docker volume rm -f "$name" > /dev/null 2>&1 || true ;;
      esac
    done < "$PS_STATE_DIR/$kind"
    : > "$PS_STATE_DIR/$kind"
  done
  return 0
}

# ps_require_dev: skip the current test when the image under test is, by name (ps_image_kind), the distroless one;
# fail when the kind cannot be told. (A suite in which every test skipped fails in scripts/run-bats.sh.)
ps_require_dev() {
  local kind
  kind=$(ps_image_kind) || return 1
  [[ $kind == dev ]] || skip "needs the -dev image (entrypoint script); IMAGE=$PS_IMAGE is the distroless one"
}

# ps_seed_datadir <volume> <file-name> <content> [...]: write files into the data directory volume as uid 1001
# (used after the first start, because mysqld --initialize needs an empty directory).
ps_seed_datadir() {
  local vol=$1 script='set -eu;' name content
  shift
  while (($#)); do
    name=$1 content=$2
    shift 2
    script+=" printf '%s' '$content' > '/d/$name'; chown 1001:0 '/d/$name'; chmod 640 '/d/$name';"
  done
  ps_docker run --rm --user 0 -v "$vol:/d" --entrypoint sh "$(ps_tool_image python)" -c "$script" > /dev/null
}

# ps_init_volume <volume> [password=x]: initialise a data volume with $PS_IMAGE (the -dev image) and exit
# (MYSQL_INIT_ONLY), leaving root with the given password.
ps_init_volume() {
  local vol=$1 pw=${2:-x} cid code
  cid=$(ps_start "init-${vol##*-}" -e "MYSQL_ROOT_PASSWORD=$pw" -e MYSQL_INIT_ONLY=1 -v "$vol:/var/lib/mysql") || return 1
  code=$(ps_wait_exit "$cid" 180) || return 1
  if [[ $code != 0 ]]; then
    echo "ps_init_volume: init exited with $code" >&2
    ps_logs "$cid" >&2
    return 1
  fi
  ps_rm "$cid"
}
