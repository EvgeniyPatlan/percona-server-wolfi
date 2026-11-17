#!/usr/bin/env bats
# PMM client image, the way the Percona operators run the official percona/pmm-client:3 as a sidecar: the entrypoint
# (pmm-agent-entrypoint) runs `pmm-agent setup` with PMM_AGENT_SETUP and then `pmm-agent run`; pmm-agent starts the
# exporters and vmagent from /usr/local/percona/pmm/exporters. No PMM server is available offline, so the suite checks
# the binaries' versions, the layout and user, that setup fails cleanly without a server, and that the exporters
# serve /metrics (mysqld_exporter against a server from the -dev image).
#
# Environment: IMAGE (the -dev server image), PMM_CLIENT_IMAGE (default localhost:5000/pmm-client:3).
# Docker only, no network access.

setup_file() {
  load helpers
  # shellcheck disable=SC2153 # PS_IMAGE comes from helpers.bash
  ps_pull_images "$PS_IMAGE" "${PMM_CLIENT_IMAGE:-localhost:5000/pmm-client:3}"
}

setup() {
  load helpers
  PMM_CLIENT_IMAGE=${PMM_CLIENT_IMAGE:-localhost:5000/pmm-client:3}
  VERSION_FILE=${VERSION_FILE:-$PS_ROOT/versions/9.7.yaml}
  P=/usr/local/percona/pmm
}

teardown() {
  ps_cleanup
}

pin() { vars_get "$VERSION_FILE" "$1"; }

# pmm_run [docker-run-args...] -- [cmd...]: docker run --rm of the client image; prints both streams
pmm_run() {
  local -a dargs=()
  while (($#)) && [[ $1 != -- ]]; do dargs+=("$1"); shift; done
  if (($#)); then shift; fi
  ps_docker run --rm "${dargs[@]}" "$PMM_CLIENT_IMAGE" "$@" 2>&1
}

# pmm_start <name> [docker-run-args...] -- <cmd...>: detached client container (tracked); prints its name
pmm_start() {
  local name full
  name=$(ps_prefix)-$1
  shift
  local -a dargs=()
  while (($#)) && [[ $1 != -- ]]; do dargs+=("$1"); shift; done
  if (($#)); then shift; fi
  ps_track containers "$name"
  ps_docker run -d --name "$name" "${dargs[@]}" "$PMM_CLIENT_IMAGE" "$@" > /dev/null || return 1
  printf '%s\n' "$name"
}

# scrape <container> <port> <pattern> [tries=30]: curl /metrics inside the container until a line matches
scrape() {
  local c=$1 port=$2 pattern=$3 tries=${4:-30} out
  for _ in $(seq 1 "$tries"); do
    out=$(ps_docker exec "$c" curl -fsS "http://127.0.0.1:$port/metrics" 2> /dev/null) || out=
    if grep -Eq "$pattern" <<< "$out"; then return 0; fi
    sleep 1
  done
  echo "scrape $c:$port: no line matches $pattern" >&2
  ps_docker logs "$c" 2>&1 | tail -n 20 >&2
  return 1
}

@test "pmm-client: every binary prints its version" {
  run pmm_run --entrypoint pmm-agent -- --version
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"Version: $(pin pmm_version)"* ]]
  [[ $output == *"$(pin pmm_commit)"* ]]
  run pmm_run --entrypoint pmm-admin -- --version
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"Version: $(pin pmm_version)"* ]]
  for e in node mysqld postgres proxysql rds azure; do
    bin=${e}_exporter
    run pmm_run --entrypoint "$P/exporters/$bin" -- --version
    echo "$bin: $output"
    [ "$status" -eq 0 ]
    [[ $output == *"version $(pin "pmm_${e}_exporter_version")"* ]]
  done
  run pmm_run --entrypoint "$P/exporters/mongodb_exporter" -- --version
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"$(pin pmm_mongodb_exporter_version)"* ]]
  run pmm_run --entrypoint "$P/exporters/vmagent" -- -version
  echo "$output"
  [ "$status" -eq 0 ]
  run pmm_run --entrypoint "$P/exporters/valkey_exporter" -- -version
  echo "$output"
  [ "$status" -eq 0 ]
  run pmm_run --entrypoint "$P/tools/nomad" -- version
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"Nomad v$(pin pmm_nomad_version)"* ]]
  # the Go summaries carry no version stamp (built without ldflags, as upstream); pt-summary --version exits 1 in the
  # official image too
  for t in pt-mongodb-summary pt-pg-summary; do
    run pmm_run --entrypoint "$P/tools/$t" -- --version
    echo "$t: $output"
    [ "$status" -eq 0 ]
    [[ $output == "$t"* ]]
  done
  for t in pt-summary pt-mysql-summary; do
    run pmm_run --entrypoint "$P/tools/$t" -- --version
    echo "$t: $output"
    [[ $output == "$t "[0-9]* ]]
  done
  run pmm_run --entrypoint mysql -- --version
  [ "$status" -eq 0 ]
  [[ $output == *"$(pin ps_version)"* ]]
}

@test "pmm-client: user, working directory, layout and the tools the image copies" {
  run pmm_run --entrypoint id -- -u
  [ "$output" = 1002 ]
  run pmm_run --entrypoint pwd
  [ "$output" = "$P" ]
  run pmm_run --entrypoint stat -- -c '%u:%g:%a %n' "$P" "$P/bin/pmm-agent" "$P/config/pmm-agent.yaml" \
    "$P/exporters/vmagent" "$P/collectors/custom-queries/mysql/high-resolution/queries-mysqld.yml"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1002:1002:775 $P" ]
  [ "${lines[1]}" = "1002:0:755 $P/bin/pmm-agent" ]
  [ "${lines[2]}" = "1002:0:660 $P/config/pmm-agent.yaml" ]
  [ "${lines[3]}" = "1002:0:755 $P/exporters/vmagent" ]
  [ "${lines[4]}" = "1002:0:755 $P/collectors/custom-queries/mysql/high-resolution/queries-mysqld.yml" ]
  # Dockerfile.el9 copies jq tar curl sed grep awk mysql* perl* into /usr/bin
  run pmm_run --entrypoint bash -- -c 'command -v jq tar curl sed grep awk mysql perl'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<< "$output")" -eq 8 ]
  run pmm_run --entrypoint perl -- -MTime::HiRes -MDigest::MD5 -e 'print "ok\n"'
  echo "$output"
  [ "$output" = ok ]
}

@test "pmm-client: pmm-agent setup fails cleanly without a PMM server; pmm-admin without an agent too" {
  # the operators' sidecar settings: setup against PMM_AGENT_SERVER_ADDRESS, then run. Without a server the setup
  # step fails and the entrypoint stops; the official 3.10.0 entrypoint then exits 0 (its exit status is not checked)
  # shellcheck disable=SC2086 # DOCKER may be a multi-word command
  run timeout 120 ${DOCKER:-docker} run --rm \
    -e PMM_AGENT_SETUP=1 -e PMM_AGENT_SERVER_ADDRESS=127.0.0.1:9 -e PMM_AGENT_SERVER_USERNAME=admin \
    -e PMM_AGENT_SERVER_PASSWORD=admin -e PMM_AGENT_SERVER_INSECURE_TLS=1 -e PMM_AGENT_CONFIG_FILE=config/pmm-agent.yaml \
    -e PMM_AGENT_SETUP_NODE_TYPE=container -e PMM_AGENT_SETUP_NODE_NAME=test "$PMM_CLIENT_IMAGE"
  echo "$output"
  [ "$status" -ne 124 ]
  [[ $output == *"Failed to register pmm-agent on PMM Server"*127.0.0.1:9*"connection refused"* ]]
  [[ $output == *"'pmm-agent setup' exited with 1"* ]]
  [[ $output != *panic:* ]]
  run pmm_run --entrypoint pmm-admin -- status
  echo "$output"
  [ "$status" -ne 0 ]
  [[ $output == *"failed to get PMM Agent status from local pmm-agent"* ]]
  [[ $output != *panic:* ]]
}

@test "pmm-client: node_exporter, vmagent, postgres_exporter and valkey_exporter serve /metrics" {
  c=$(pmm_start exp --entrypoint bash -- -c "
    $P/exporters/node_exporter --web.listen-address=127.0.0.1:9100 &
    $P/exporters/vmagent -httpListenAddr=127.0.0.1:8429 -remoteWrite.url=http://127.0.0.1:9/api/v1/write \
      -remoteWrite.tmpDataPath=/tmp/vmagent &
    DATA_SOURCE_NAME='postgresql://u:p@127.0.0.1:9/postgres?sslmode=disable' \
      $P/exporters/postgres_exporter --web.listen-address=127.0.0.1:9187 &
    $P/exporters/valkey_exporter -web.listen-address=127.0.0.1:9121 -redis.addr=redis://127.0.0.1:9 &
    wait")
  scrape "$c" 9100 '^node_cpu_seconds_total'
  scrape "$c" 8429 '^vm_app_version|^vmagent_'
  scrape "$c" 9187 '^pg_up(\{[^}]*\})? 0'
  scrape "$c" 9121 '^redis_up 0'
}

@test "pmm-client: mysqld_exporter scrapes a Percona Server from the -dev image" {
  ps_require_dev
  net=$(ps_network pmm)
  db=$(ps_prefix)-db
  cid=$(ps_start db --network "$net" -e MYSQL_ROOT_PASSWORD=x) || false
  ps_wait_ready "$cid" 180
  cnf=$BATS_TEST_TMPDIR/my.cnf
  printf '[client]\nuser=root\npassword=x\nhost=%s\nport=3306\n' "$db" > "$cnf"
  chmod 0644 "$cnf"
  c=$(pmm_start mysqld --network "$net" -v "$cnf:/tmp/my.cnf:ro" --entrypoint "$P/exporters/mysqld_exporter" -- \
    --config.my-cnf=/tmp/my.cnf --web.listen-address=127.0.0.1:9104 --collect.global_status --collect.global_variables)
  scrape "$c" 9104 '^mysql_up 1'
  scrape "$c" 9104 '^mysql_global_status_uptime [0-9]'
  scrape "$c" 9104 "^mysql_version_info\{.*version=\"$(pin ps_version)"
}
