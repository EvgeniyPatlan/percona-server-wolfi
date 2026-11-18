#!/usr/bin/env bash
# lint-pipelines.sh <file.groovy...>: validate declarative pipelines with Jenkins' own validator
# (/pipeline-model-converter/validate) in a throwaway Jenkins: the pinned image of jenkins/tools.yaml with the plugins
# the jobs use, no security, on 127.0.0.1:$LINT_PORT. An already running container of that name is reused; KEEP=1
# leaves it running for the next call, otherwise it is removed at the end. Exit 1 if any file does not validate.
# Env: LINT_PORT (8099), LINT_NAME (ps-wolfi-jenkins-lint), KEEP, DOCKER, CURL.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here/../.."
# shellcheck source=../../scripts/lib/common.sh
. scripts/lib/common.sh

(($#)) || die "usage: lint-pipelines.sh <file.groovy...>"
port=${LINT_PORT:-8099} name=${LINT_NAME:-ps-wolfi-jenkins-lint}
docker_cmd=${DOCKER:-docker} curl_cmd=${CURL:-curl}
base=http://127.0.0.1:$port
# the plugins whose steps and options the jobs use
plugins="workflow-aggregator pipeline-model-definition git credentials-binding timestamper aws-credentials github"

if [[ $("$docker_cmd" inspect -f '{{.State.Running}}' "$name" 2> /dev/null) != true ]]; then
  "$docker_cmd" rm -f "$name" > /dev/null 2>&1 || true
  image=$(TOOLS_FILE=jenkins/tools.yaml vars_get jenkins/tools.yaml jenkins)
  log_info "starting $name (installs the plugins on its first start)"
  "$docker_cmd" run -d --name "$name" -p "127.0.0.1:$port:8080" -e JAVA_OPTS=-Djenkins.install.runSetupWizard=false \
    --entrypoint bash "$image" -c "jenkins-plugin-cli --plugins $plugins > /tmp/plugins.log 2>&1 && exec /usr/local/bin/jenkins.sh" \
    > /dev/null
fi
[[ ${KEEP:-0} == 1 ]] || trap '"$docker_cmd" rm -f "$name" > /dev/null 2>&1 || true' EXIT

for ((i = 0; i < 180; i++)); do
  [[ $("$curl_cmd" -s -o /dev/null -w '%{http_code}' "$base/login" || true) == 200 ]] && break
  "$docker_cmd" inspect -f '{{.State.Running}}' "$name" 2> /dev/null | grep -q true || die "$name stopped (docker logs $name)"
  sleep 5
done
((i < 180)) || die "Jenkins did not come up on $base"

jar=$(mktemp)
trap '"$docker_cmd" rm -f "$name" > /dev/null 2>&1 || true; rm -f "$jar"' EXIT
[[ ${KEEP:-0} != 1 ]] || trap 'rm -f "$jar"' EXIT
crumb=$("$curl_cmd" -fsS -c "$jar" "$base/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")
rc=0
for f in "$@"; do
  out=$("$curl_cmd" -fsS -b "$jar" -H "$crumb" -X POST -F "jenkinsfile=<$f" "$base/pipeline-model-converter/validate")
  if [[ $out == *"successfully validated"* ]]; then
    echo "OK    $f"
  else
    echo "FAIL  $f"
    printf '%s\n' "$out" | sed 's/^/      /'
    rc=1
  fi
done
exit "$rc"
