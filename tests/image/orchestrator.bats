#!/usr/bin/env bats
# Orchestrator image, the way the official percona/percona-orchestrator is used: the entrypoint fills the topology
# credentials (and, under Kubernetes, the per-pod raft/TLS settings) and starts `orchestrator http` with the shipped
# configuration (SQLite backend, single-node raft); the Percona Operator's orc-entrypoint.sh and
# orc-add_mysql_nodes.sh need bash, jq, curl and the HTTP API. Also discovers a source/replica pair.
#
# Environment: ORC_IMAGE (default localhost:5000/percona-orchestrator:<orc_version>), IMAGE (the -dev server image,
# for the MySQL pair). Docker only, no network access.

setup_file() {
  load helpers
  VERSION_FILE=${VERSION_FILE:-$PS_ROOT/versions/9.7.yaml}
  # shellcheck disable=SC2153 # PS_IMAGE comes from helpers.bash
  ps_pull_images "$PS_IMAGE" "${ORC_IMAGE:-localhost:5000/percona-orchestrator:$(vars_get "$VERSION_FILE" orc_version)}"
}

setup() {
  load helpers
  VERSION_FILE=${VERSION_FILE:-$PS_ROOT/versions/9.7.yaml}
  ORC_IMAGE=${ORC_IMAGE:-localhost:5000/percona-orchestrator:$(vars_get "$VERSION_FILE" orc_version)}
  unset PS_SQL_USER
  export PS_SQL_PASSWORD=x
}

teardown() {
  ps_cleanup
}

# orc_run [docker-run-args...] -- [cmd...]: docker run --rm of the orchestrator image; prints both streams
orc_run() {
  local -a dargs=()
  while (($#)) && [[ $1 != -- ]]; do dargs+=("$1"); shift; done
  if (($#)); then shift; fi
  ps_docker run --rm --network none "${dargs[@]}" "$ORC_IMAGE" "$@" 2>&1
}

# orc_start <net> [docker-run-args...]: start the image with its default entrypoint and command on <net>; prints the
# container name once /api/health answers OK (fails after 90 s, with the logs)
orc_start() {
  local net=$1 name
  shift
  name=$(ps_prefix)-orc
  ps_track containers "$name"
  ps_docker run -d --name "$name" --hostname "$name" --network "$net" "$@" "$ORC_IMAGE" > /dev/null || return 1
  for _ in $(seq 1 90); do
    if ps_docker exec "$name" curl -sf http://127.0.0.1:3000/api/health 2> /dev/null | grep -q '"Code":"OK"'; then
      printf '%s\n' "$name"
      return 0
    fi
    sleep 1
  done
  echo "orc_start: /api/health not OK after 90s" >&2
  ps_logs "$name" | tail -n 40 >&2
  return 1
}

# orc_api <container> <path>: GET http://127.0.0.1:3000<path> from inside the container
orc_api() { ps_docker exec "$1" curl -sf "http://127.0.0.1:3000$2"; }

@test "orchestrator: version, layout, uid and the tools the entrypoints call" {
  run orc_run --entrypoint /usr/local/orchestrator/orchestrator -- --version
  echo "$output"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(vars_get "$VERSION_FILE" orc_version)-$(vars_get "$VERSION_FILE" orc_release)" ]
  [ "${lines[1]}" = "$(vars_get "$VERSION_FILE" orc_commit)" ]
  # orc-entrypoint.sh / orc-add_mysql_nodes.sh (operator), entrypoint.sh / add_mysql_nodes.sh (image)
  run orc_run --entrypoint bash -- -c \
    'command -v jq curl sed mktemp seq date sh orchestrator-client add_mysql_nodes.sh which dig openssl tar ps column'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<< "$output")" -eq 15 ]
  run orc_run --entrypoint bash -- -c 'id -u; id -g; pwd
    stat -c "%u:%g %a %n" /var/lib/orchestrator /etc/orchestrator /etc/orchestrator/orchestrator.conf.json \
      /etc/orchestrator/orc-topology.cnf
    test -w /var/lib/orchestrator && test -w /etc/orchestrator/orc-topology.cnf && echo writable
    test -d /usr/local/orchestrator/resources/public && test -s /licenses/LICENSE.orchestrator && echo layout'
  echo "$output"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 1001 ]
  [ "${lines[1]}" = 1001 ]
  [ "${lines[2]}" = /usr/local/orchestrator ]
  [ "${lines[3]}" = "1001:1001 755 /var/lib/orchestrator" ]
  [ "${lines[4]}" = "0:0 755 /etc/orchestrator" ]
  [ "${lines[5]}" = "1001:1001 644 /etc/orchestrator/orchestrator.conf.json" ]
  [ "${lines[6]}" = "1001:1001 644 /etc/orchestrator/orc-topology.cnf" ]
  [ "${lines[7]}" = writable ]
  [ "${lines[8]}" = layout ]
}

@test "orchestrator: the shipped configuration starts (SQLite, raft leader), API and orchestrator-client answer" {
  net=$(ps_network orc)
  orc=$(orc_start "$net" -e ORC_TOPOLOGY_PASSWORD=pw1)
  run orc_api "$orc" /api/health
  [[ $output == *'"Code":"OK"'* ]]
  # StatusEndpoint of the shipped configuration
  run orc_api "$orc" /api/status
  [ "$status" -eq 0 ]
  # single-node raft: this node becomes the leader within seconds ("" until then; add_mysql_nodes.sh waits for it)
  leader=
  for _ in $(seq 1 30); do
    leader=$(orc_api "$orc" /api/raft-leader || true)
    [[ -n $leader && $leader != '""' ]] && break
    sleep 1
  done
  echo "leader: $leader"
  [ "$leader" = '"127.0.0.1:10008"' ]
  run ps_docker exec "$orc" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/api/leader-check
  [ "$output" = 200 ]
  # the SQLite backend lives in the volume directory
  run ps_docker exec "$orc" test -s /var/lib/orchestrator/orc.db
  [ "$status" -eq 0 ]
  # the entrypoint wrote the topology password into the credentials file
  run ps_docker exec "$orc" grep -x 'password=pw1' /etc/orchestrator/orc-topology.cnf
  [ "$status" -eq 0 ]
  run ps_docker exec "$orc" orchestrator-client -c clusters
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run ps_docker exec "$orc" orchestrator-client -c help
  [ "$status" -eq 0 ]
  [[ $output == *discover* ]]
}

@test "orchestrator: entrypoint under Kubernetes (namespace and password files, raft and TLS settings)" {
  d=$BATS_TEST_TMPDIR/k8s
  mkdir -p "$d"
  printf 'ns1' > "$d/namespace"
  printf 'pw-from-secret' > "$d/orchestrator"
  chmod 0644 "$d/namespace" "$d/orchestrator"
  run orc_run --hostname orc-0 -e KUBERNETES_SERVICE_HOST=10.0.0.1 -e ORC_SERVICE=orc-svc \
    -v "$d/namespace:/var/run/secrets/kubernetes.io/serviceaccount/namespace:ro" \
    -v "$d/orchestrator:/etc/orchestrator/orchestrator-users-secret/orchestrator:ro" -- \
    bash -c 'jq -c "[.HTTPAdvertise, .RaftAdvertise, .RaftBind, .RaftEnabled, .RaftNodes, .MySQLTopologySSLCAFile, .BackendDB]" /etc/orchestrator/orchestrator.conf.json; grep "^password=" /etc/orchestrator/orc-topology.cnf'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *'["http://orc-0.ns1:3000","orc-0.ns1","orc-0.orc-svc.ns1",true,[],"/etc/orchestrator/ssl/ca.crt","sqlite"]'* ]]
  [[ $output == *"password=pw-from-secret"* ]]
}

# srv_start <net> <name> <server-id>: a -dev server with GTIDs and report_host = its name; prints the container id
srv_start() {
  local full cid
  full=$(ps_prefix)-$2
  cid=$(ps_start "$2" --network "$1" --hostname "$full" -e MYSQL_ROOT_PASSWORD=x -e 'MYSQL_ROOT_HOST=%' -- \
    "--server-id=$3" "--report-host=$full" --gtid-mode=ON --enforce-gtid-consistency=ON) || return 1
  printf '%s\n' "$cid"
}

@test "orchestrator: discovers a source/replica pair of the -dev image" {
  ps_require_dev
  net=$(ps_network orcdb)
  src=$(srv_start "$net" src 1)
  rep=$(srv_start "$net" rep 2)
  sh=$(ps_prefix)-src rh=$(ps_prefix)-rep
  ps_wait_ready "$src" 180
  ps_wait_ready "$rep" 180
  for c in "$src" "$rep"; do ps_sql "$c" 'RESET BINARY LOGS AND GTIDS'; done
  ps_sql "$src" "CREATE USER 'orchestrator'@'%' IDENTIFIED BY 'orcpw'; GRANT ALL ON *.* TO 'orchestrator'@'%'"
  # the shipped ReplicationLagQuery reads the operator's heartbeat table; without it no instance can be read
  ps_sql "$src" 'CREATE DATABASE sys_operator; CREATE TABLE sys_operator.heartbeat (ts TIMESTAMP(6) NOT NULL PRIMARY KEY);
    INSERT INTO sys_operator.heartbeat VALUES (NOW(6))'
  ps_sql "$rep" "CHANGE REPLICATION SOURCE TO SOURCE_HOST='$sh', SOURCE_USER='root', SOURCE_PASSWORD='x',
    SOURCE_AUTO_POSITION=1, SOURCE_SSL=1; START REPLICA"
  n=
  for _ in $(seq 1 30); do
    n=$(ps_sql "$rep" "SELECT COUNT(*) FROM mysql.user WHERE user='orchestrator'" || true)
    [[ $n == 1 ]] && break
    sleep 1
  done
  [ "$n" = 1 ]
  # caching_sha2_password: one TLS login per server fills the cache, so orchestrator's plain connection is accepted
  for c in "$src" "$rep"; do
    ps_docker exec "$c" mysql --no-defaults --protocol=tcp -h127.0.0.1 -uorchestrator -porcpw -e 'SELECT 1' > /dev/null
  done

  orc=$(orc_start "$net" -e ORC_TOPOLOGY_PASSWORD=orcpw)
  ok=
  # each node is discovered by name, as the operator's orc-add_mysql_nodes.sh does for every peer
  for _ in $(seq 1 60); do
    for h in "$sh" "$rh"; do
      ps_docker exec "$orc" curl -s "http://127.0.0.1:3000/api/discover/$h/3306" > /dev/null || true
    done
    reps=$(ps_docker exec "$orc" orchestrator-client -c which-replicas -i "$sh:3306" 2> /dev/null || true)
    [[ $reps == *"$rh"* ]] && ok=1 && break
    sleep 2
  done
  echo "# orchestrator logs: $(ps_logs "$orc" | grep -iE 'error|fatal' | tail -n 5)" >&3
  echo "replicas of $sh: $reps"
  [ "$ok" = 1 ]
  run ps_docker exec "$orc" orchestrator-client -c which-master -i "$rh:3306"
  echo "$output"
  [[ $output == *"$sh"* ]]
  run ps_docker exec "$orc" orchestrator-client -c clusters
  echo "$output"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}
