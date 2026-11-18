#!/usr/bin/env bats
# jenkins/: the job scripts with stubbed docker/curl, and the consistency of the jobs with the Makefile.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  export DOCKER_LOG=$BATS_TEST_TMPDIR/docker.log
  : > "$DOCKER_LOG"
  export DOCKER=$BATS_TEST_TMPDIR/docker
  cat > "$DOCKER" <<'S'
#!/usr/bin/env bash
# records every call (one line), fails on demand: FAIL_ON=<substring of the call>
printf '%s\n' "$*" >> "$DOCKER_LOG"
cat > /dev/null 2>&1 < /dev/stdin &
if [[ -n ${FAIL_ON:-} && "$*" == *"$FAIL_ON"* ]]; then exit 1; fi
case "$*" in
  *" resolve "*) echo "${RESOLVE_DIGEST:-sha256:$(printf 'b%.0s' {1..64})}" ;;
  *" s3 ls "*) [[ ${S3_HAS:-0} == 1 ]] || exit 1 ;;
  *"du -sk"*) echo "4 x" ;;
esac
exit 0
S
  chmod +x "$DOCKER"
  DIGEST=sha256:$(printf 'b%.0s' {1..64})
}

# --- changed.sh ---------------------------------------------------------------------------------------------------

@test "changed: images are the BUILD image lines of a build.sh plan" {
  plan=$'BUILD package percona-server (inputs changed)\nSKIP  image percona-server (up to date)\nBUILD image percona-toolkit (inputs changed)\nBUILD image pmm-client (digest not in localhost:5000)'
  run "$ROOT/jenkins/scripts/changed.sh" images <<< "$plan"
  [ "$status" -eq 0 ]
  [ "$output" = $'percona-toolkit\npmm-client' ]
}

@test "changed: tests are deduplicated and in phase-b order" {
  run "$ROOT/jenkins/scripts/changed.sh" tests pmm-client percona-xtradb-cluster percona-xtrabackup percona-xtradb-cluster-backup
  [ "$status" -eq 0 ]
  [ "$output" = $'test-xtrabackup\ntest-pxc\ntest-pmm-client' ]
  run "$ROOT/jenkins/scripts/changed.sh" tests nope
  [ "$status" -ne 0 ]
}

@test "changed: every image has suites, and every phase-b suite belongs to an image" {
  cd "$ROOT"
  . scripts/lib/common.sh
  . jenkins/scripts/lib.sh
  # shellcheck disable=SC2046
  run jenkins/scripts/changed.sh tests $(images_list)
  [ "$status" -eq 0 ]
  phase_b=$(grep '^phase-b:' Makefile | tr ' ' '\n' | grep '^test-' | grep -v '^test-unit$')
  [ "$output" = "$phase_b" ]
}

# --- publish.sh ---------------------------------------------------------------------------------------------------

mk_results() { # <image...>
  export RESULTS_DIR=$BATS_TEST_TMPDIR/results
  mkdir -p "$RESULTS_DIR"
  for i in "$@"; do echo "$DIGEST" > "$RESULTS_DIR/$i.digest"; done
  export CURL=$BATS_TEST_TMPDIR/curl
  cat > "$CURL" <<S
#!/usr/bin/env bash
case "\$*" in
  */tags/list*) echo '{"tags":["9.7","9.7.2-2","old","sha256-$(printf 'b%.0s' {1..64})"]}' ;;
  */manifests/old) echo sha256:$(printf 'c%.0s' {1..64}) ;;
  */manifests/*) echo $DIGEST ;;
esac
S
  chmod +x "$CURL"
  export COSIGN_PUB=$BATS_TEST_TMPDIR/cosign.pub
  echo PUB > "$COSIGN_PUB"
}

@test "publish: refuses an org outside the list, an empty or other suffix, an unknown image" {
  run "$ROOT/jenkins/scripts/publish.sh" someorg -wolfi
  [ "$status" -ne 0 ]
  [[ $output == *"not one of"* ]]
  run "$ROOT/jenkins/scripts/publish.sh" perconalab ""
  [ "$status" -ne 0 ]
  run "$ROOT/jenkins/scripts/publish.sh" perconalab -latest
  [ "$status" -ne 0 ]
  run "$ROOT/jenkins/scripts/publish.sh" perconalab -wolfi nope
  [ "$status" -ne 0 ]
  [[ $output == *"unknown image"* ]]
}

@test "publish: needs the digest file and the public key" {
  mk_results
  run "$ROOT/jenkins/scripts/publish.sh" perconalab -wolfi percona-toolkit
  [ "$status" -ne 0 ]
  [[ $output == *"no digest file"* ]]
  mk_results percona-toolkit
  COSIGN_PUB=$BATS_TEST_TMPDIR/missing run "$ROOT/jenkins/scripts/publish.sh" perconalab -wolfi percona-toolkit
  [ "$status" -ne 0 ]
  [[ $output == *COSIGN_PUB* ]]
}

@test "publish: only the tags of the digest, suffixed; verify the source, copy, resolve, verify the target" {
  mk_results percona-server-dev
  run "$ROOT/jenkins/scripts/publish.sh" percona -wolfi percona-server-dev
  [ "$status" -eq 0 ]
  copy=$(grep -n ' copy -r ' "$DOCKER_LOG")
  [[ $copy == *"localhost:5000/percona-server@$DIGEST docker.io/percona/percona-server:9.7-wolfi,9.7.2-2-wolfi"* ]]
  [[ $copy != *old* && $copy != *sha256-b* ]]
  first_verify=$(grep -n ' verify --key' "$DOCKER_LOG" | head -n1)
  [[ $first_verify == *"localhost:5000/percona-server@$DIGEST"* ]]
  [ "${first_verify%%:*}" -lt "${copy%%:*}" ]
  grep -q " resolve docker.io/percona/percona-server:9.7-wolfi" "$DOCKER_LOG"
  grep -q " verify-attestation --type spdxjson .*docker.io/percona/percona-server@$DIGEST" "$DOCKER_LOG"
}

@test "publish: nothing is pushed when the local image does not verify" {
  mk_results percona-toolkit
  FAIL_ON="verify --key /keys/cosign.pub --allow-http-registry" run "$ROOT/jenkins/scripts/publish.sh" perconalab -wolfi percona-toolkit
  [ "$status" -ne 0 ]
  run grep -q ' copy -r ' "$DOCKER_LOG"
  [ "$status" -ne 0 ]
}

@test "publish: a tag that resolves to another digest fails" {
  mk_results percona-toolkit
  RESOLVE_DIGEST=sha256:$(printf 'd%.0s' {1..64}) run "$ROOT/jenkins/scripts/publish.sh" perconalab -wolfi percona-toolkit
  [ "$status" -ne 0 ]
  [[ $output == *"resolves to"* ]]
}

@test "publish: the password is never on a command line, the login config is removed" {
  mk_results percona-toolkit
  export TMPDIR=$BATS_TEST_TMPDIR/tmp
  mkdir -p "$TMPDIR"
  DOCKER_USER=bot DOCKER_PASS=S3CRETPASS run "$ROOT/jenkins/scripts/publish.sh" perconalab -wolfi percona-toolkit
  [ "$status" -eq 0 ]
  run grep -q S3CRETPASS "$DOCKER_LOG"
  [ "$status" -ne 0 ]
  [[ $output != *S3CRETPASS* ]]
  [ -z "$(ls -A "$TMPDIR")" ]
  DOCKER_USER=bot run "$ROOT/jenkins/scripts/publish.sh" perconalab -wolfi percona-toolkit
  [ "$status" -ne 0 ]
}

@test "publish: DRY_RUN prints the plan and runs no container" {
  mk_results percona-toolkit
  DRY_RUN=1 run "$ROOT/jenkins/scripts/publish.sh" perconalab -wolfi percona-toolkit
  [ "$status" -eq 0 ]
  [[ $output == *"docker.io/perconalab/percona-toolkit:{9.7-wolfi,9.7.2-2-wolfi}"* ]]
  [ ! -s "$DOCKER_LOG" ]
}

# --- install-keys.sh ----------------------------------------------------------------------------------------------

@test "install-keys: checks its inputs before writing anything" {
  export HOME=$BATS_TEST_TMPDIR/home
  run "$ROOT/jenkins/scripts/install-keys.sh" install ci
  [ "$status" -ne 0 ]
  [[ $output == *APK_KEY_FILE* ]]
  echo 'not a key' > "$BATS_TEST_TMPDIR/k"
  APK_KEY_FILE=$BATS_TEST_TMPDIR/k COSIGN_KEY_FILE=$BATS_TEST_TMPDIR/k run "$ROOT/jenkins/scripts/install-keys.sh" install ci
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/.config/ps-wolfi-ci" ]
  run "$ROOT/jenkins/scripts/install-keys.sh" install frob
  [ "$status" -ne 0 ]
}

@test "install-keys: never overwrites an existing key dir, never a dir inside the repo; release only in the default dir" {
  export HOME=$BATS_TEST_TMPDIR/home
  printf -- '-----BEGIN RSA PRIVATE KEY-----\n' > "$BATS_TEST_TMPDIR/apk"
  printf -- '-----BEGIN ENCRYPTED SIGSTORE PRIVATE KEY-----\n' > "$BATS_TEST_TMPDIR/cos"
  export APK_KEY_FILE=$BATS_TEST_TMPDIR/apk COSIGN_KEY_FILE=$BATS_TEST_TMPDIR/cos
  mkdir -p "$HOME/.config/ps-wolfi-ci"
  run "$ROOT/jenkins/scripts/install-keys.sh" install ci
  [ "$status" -ne 0 ]
  [[ $output == *"already exists"* ]]
  KEY_DIR=$ROOT/out/unit-keys-$$ run "$ROOT/jenkins/scripts/install-keys.sh" install ci
  [ "$status" -ne 0 ]
  [[ $output == *"inside the repo"* ]]
  [ ! -e "$ROOT/out/unit-keys-$$" ]
  KEY_DIR=$BATS_TEST_TMPDIR/elsewhere run "$ROOT/jenkins/scripts/install-keys.sh" install release
  [ "$status" -ne 0 ]
  [[ $output == *"default key dir"* ]]
}

@test "install-keys: clean removes only a dir it created" {
  export HOME=$BATS_TEST_TMPDIR/home
  mkdir -p "$HOME/.config/ps-wolfi"
  echo real > "$HOME/.config/ps-wolfi/cosign.key"
  run "$ROOT/jenkins/scripts/install-keys.sh" clean release
  [ "$status" -eq 0 ]
  [ -s "$HOME/.config/ps-wolfi/cosign.key" ]
  mkdir -p "$HOME/.config/ps-wolfi-ci"
  : > "$HOME/.config/ps-wolfi-ci/.installed-by-jenkins"
  run "$ROOT/jenkins/scripts/install-keys.sh" clean ci
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.config/ps-wolfi-ci" ]
}

# --- cache.sh -----------------------------------------------------------------------------------------------------

@test "cache: rejects a bad CACHE_URL and entries outside the repo" {
  CACHE_URL=/tmp/x run "$ROOT/jenkins/scripts/cache.sh" save sources
  [ "$status" -ne 0 ]
  export CACHE_URL=s3://bucket/prefix
  for e in /etc ../x 'a b' volume:bad/name; do
    run "$ROOT/jenkins/scripts/cache.sh" save "$e"
    [ "$status" -ne 0 ]
  done
  run "$ROOT/jenkins/scripts/cache.sh" frob sources
  [ "$status" -ne 0 ]
}

@test "cache: save goes to .partial and is renamed only after tar and upload succeed" {
  export CACHE_URL=s3://bucket/prefix
  d=out/unit-cache-$$
  mkdir -p "$ROOT/$d"
  echo x > "$ROOT/$d/f"
  run "$ROOT/jenkins/scripts/cache.sh" save "$d"
  [ "$status" -eq 0 ]
  grep -q " s3 cp - s3://bucket/prefix/out-unit-cache-$$.tar.zst.partial" "$DOCKER_LOG"
  grep -q " s3 mv s3://bucket/prefix/out-unit-cache-$$.tar.zst.partial s3://bucket/prefix/out-unit-cache-$$.tar.zst" "$DOCKER_LOG"
  : > "$DOCKER_LOG"
  FAIL_ON='s3 cp -' run "$ROOT/jenkins/scripts/cache.sh" save "$d"
  rm -rf "${ROOT:?}/$d"
  [ "$status" -eq 0 ]
  [[ $output == *"cache save failed"* ]]
  run grep -q ' s3 mv ' "$DOCKER_LOG"
  [ "$status" -ne 0 ]
  grep -q " s3 rm s3://bucket/prefix/out-unit-cache-$$.tar.zst.partial" "$DOCKER_LOG"
}

@test "cache: restore skips a missing object, keeps a present entry, wipes a failed extraction" {
  export CACHE_URL=s3://bucket/prefix
  run "$ROOT/jenkins/scripts/cache.sh" restore out/unit-cache-none-$$
  [ "$status" -eq 0 ]
  [[ $output == *"skipped"* ]]
  run "$ROOT/jenkins/scripts/cache.sh" restore sources
  [ "$status" -eq 0 ]
  [[ $output == *"already present"* ]]
  S3_HAS=1 FAIL_ON='zstd -dcq' run "$ROOT/jenkins/scripts/cache.sh" restore out/unit-cache-bad-$$
  [ "$status" -eq 0 ]
  [[ $output == *"restore failed"* ]]
  grep -q -- "--entrypoint rm .* -rf /work/out/unit-cache-bad-$$" "$DOCKER_LOG"
}

@test "cache: root-owned dirs are archived as root, others as the user" {
  export CACHE_URL=s3://bucket/prefix CACHE_ROOT_OWNED=out/unit-root-$$
  mkdir -p "$ROOT/out/unit-root-$$" "$ROOT/out/unit-user-$$"
  touch "$ROOT/out/unit-root-$$/f" "$ROOT/out/unit-user-$$/f"
  run "$ROOT/jenkins/scripts/cache.sh" save "out/unit-root-$$" "out/unit-user-$$"
  rm -rf "${ROOT:?}/out/unit-root-$$" "${ROOT:?}/out/unit-user-$$"
  [ "$status" -eq 0 ]
  run grep -E -- "--user [0-9]+:[0-9]+ .*tar --numeric-owner -cf - .* out/unit-root-$$" "$DOCKER_LOG"
  [ "$status" -ne 0 ]
  grep -E -q -- "--user $(id -u):$(id -g) .*tar --numeric-owner -cf - .* out/unit-user-$$" "$DOCKER_LOG"
}

# --- locks.sh -----------------------------------------------------------------------------------------------------

@test "locks: stash takes only generated lock files, unstash never replaces a committed one" {
  t=$BATS_TEST_TMPDIR/repo
  mkdir -p "$t/jenkins/scripts" "$t/scripts/lib" "$t/images"
  cp "$ROOT/jenkins/scripts/locks.sh" "$t/jenkins/scripts/"
  cp "$ROOT/scripts/lib/common.sh" "$t/scripts/lib/"
  cd "$t"
  git init -q . && git config user.email t@example.com && git config user.name t
  echo committed > images/a.lock.json && git add images/a.lock.json && git commit -qm a
  echo generated > images/b.lock.json
  run jenkins/scripts/locks.sh stash
  [ "$status" -eq 0 ]
  [ "$(ls out/ci-locks)" = b.lock.json ]
  echo stale > out/ci-locks/a.lock.json
  rm images/b.lock.json
  run jenkins/scripts/locks.sh unstash
  [ "$status" -eq 0 ]
  [ "$(cat images/a.lock.json)" = committed ]
  [ "$(cat images/b.lock.json)" = generated ]
}

# --- preflight.sh -------------------------------------------------------------------------------------------------

@test "preflight: lists every failed check, passes when all pass" {
  export DF_CMD="echo 500"
  printf 'v8_src_sha256: "TODO-UNRESOLVED"\n' > "$BATS_TEST_TMPDIR/v.yaml"
  VERSION_FILE=$BATS_TEST_TMPDIR/v.yaml run "$ROOT/jenkins/scripts/preflight.sh" incremental
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  v8_src_sha256"* && $output == *"OK    docker runs privileged"* ]]
  printf 'v8_src_sha256: "%s"\n' "$(printf 'a%.0s' {1..64})" > "$BATS_TEST_TMPDIR/v.yaml"
  VERSION_FILE=$BATS_TEST_TMPDIR/v.yaml run "$ROOT/jenkins/scripts/preflight.sh" incremental
  [ "$status" -eq 0 ]
  DF_CMD="echo 20" VERSION_FILE=$BATS_TEST_TMPDIR/v.yaml run "$ROOT/jenkins/scripts/preflight.sh" incremental
  [ "$status" -ne 0 ]
  [[ $output == *"FAIL  at least 150 GB free"* ]]
  run "$ROOT/jenkins/scripts/preflight.sh" frob
  [ "$status" -ne 0 ]
}

# --- the jobs -----------------------------------------------------------------------------------------------------

@test "jobs: each JJB file points at its groovy file, no parameter is interpolated into a shell step" {
  for y in "$ROOT"/jenkins/ps-wolfi-*.yml; do
    g=$(sed -n 's/^ *script-path: //p' "$y")
    [ "$g" = "jenkins/$(basename "$y" .yml).groovy" ]
    [ -f "$ROOT/$g" ]
  done
  run grep -nE 'sh +"[^"]*\$\{params' "$ROOT"/jenkins/*.groovy
  [ "$status" -ne 0 ]
}

@test "jobs: the release job never publishes from a relock or without PUBLISH, and drops BUILD_ID" {
  g=$ROOT/jenkins/ps-wolfi-release.groovy
  grep -q "when { expression { params.PUBLISH && !params.RELOCK } }" "$g"
  grep -q "booleanParam(name: 'PUBLISH', defaultValue: false" "$g"
  grep -q "unset BUILD_ID; make tools-pull && RELEASE=1 make all" "$g"
  # shellcheck disable=SC2016 # literal text in the file
  grep -q 'publish.sh "$DOCKER_ORG" -wolfi' "$g"
  grep -q 'publish.sh perconalab -wolfi-ci' "$ROOT/jenkins/ps-wolfi-incremental.groovy"
}

@test "mtr-nightly: the public key is mounted under its own name (apk picks the key by file name)" {
  # shellcheck disable=SC2016 # literal text in the file
  grep -q '/etc/apk/keys/$$APK_KEY_NAME.rsa.pub:ro' "$ROOT/mk/tests.mk"
}
