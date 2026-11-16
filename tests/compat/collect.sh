#!/usr/bin/env bash
# collect.sh <image-ref> <out-dir>: start the image with a fixed environment and write the fixture files
# described in compare.sh (needs docker; DOCKER may be a multi-word command, e.g. "sudo docker").
# Both images of a comparison are started with the identical environment below.
set -euo pipefail

IMAGE=${1:?usage: collect.sh <image-ref> <out-dir>}
OUT=${2:?usage: collect.sh <image-ref> <out-dir>}
READY_TIMEOUT=${COMPAT_READY_TIMEOUT:-180}
ROOT_PW=${COMPAT_ROOT_PASSWORD:-compat-root}
NAME=compat-$$-$RANDOM

dk() {
  # shellcheck disable=SC2086 # DOCKER may be a multi-word command
  ${DOCKER:-docker} "$@"
}
cleanup() { dk rm -f -v "$NAME" > /dev/null 2>&1 || true; }
trap cleanup EXIT

# sql <statement>: root over the socket, tab-separated, no header.
sql() { dk exec -i -e "MYSQL_PWD=$ROOT_PW" "$NAME" mysql --no-defaults -N -B -uroot -e "$1"; }

wait_ready() {
  local deadline=$((SECONDS + READY_TIMEOUT))
  until dk exec "$NAME" mysqladmin --no-defaults --protocol=tcp -h127.0.0.1 -uroot "-p$ROOT_PW" ping > /dev/null 2>&1; do
    [[ $(dk inspect -f '{{.State.Running}}' "$NAME" 2> /dev/null) == true ]] || { echo "collect: $IMAGE exited" >&2; dk logs "$NAME" >&2 || true; return 1; }
    ((SECONDS < deadline)) || { echo "collect: $IMAGE not ready after ${READY_TIMEOUT}s" >&2; dk logs "$NAME" >&2 || true; return 1; }
    sleep 1
  done
}

mkdir -p "$OUT"
dk run -d --name "$NAME" -e "MYSQL_ROOT_PASSWORD=$ROOT_PW" "$IMAGE" > /dev/null
wait_ready

sql 'SHOW GLOBAL VARIABLES' | LC_ALL=C sort > "$OUT/variable.tsv"
sql 'SHOW PLUGINS' | LC_ALL=C sort > "$OUT/plugin.tsv"
sql 'SELECT component_urn FROM mysql.component' | LC_ALL=C sort > "$OUT/component.tsv"
plugin_dir=$(sql 'SELECT @@plugin_dir')
# <relative path> <TAB> <type>[ <link target>]; fails loudly if find is missing from the image
dk exec "$NAME" find "$plugin_dir" -mindepth 1 -printf '%P\t%y %l\n' | sed 's/ $//' | LC_ALL=C sort > "$OUT/file.tsv"
dk inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" | sed '/^$/d; s/=/\t/' | LC_ALL=C sort > "$OUT/env.tsv"
{
  for f in Entrypoint Cmd User ExposedPorts Volumes WorkingDir; do
    printf '%s\t%s\n' "$f" "$(dk inspect -f "{{json .Config.$f}}" "$NAME")"
  done
} > "$OUT/config.tsv"
