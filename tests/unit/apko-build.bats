#!/usr/bin/env bats

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  TMP=$BATS_TEST_TMPDIR
  mkdir -p "$TMP/img" "$TMP/kd"
  for n in percona-server percona-server-dev percona-xtrabackup; do
    printf 'contents:\n  packages:\n    - percona-server-server=@@ps_version@@\n' > "$TMP/img/$n.apko.yaml.tmpl"
  done
  touch "$TMP/kd/ps-wolfi-dev.rsa.pub"
  # fixture `docker load` tarballs (manifest.json + one gzipped layer): a clean server tree, and one with a shell
  mkfix() { # mkfix <name> <extra cmd in the layer root>
    local d="$TMP/fix-$1"
    mkdir -p "$d/root/usr/bin" "$d/root/etc" && touch "$d/root/usr/bin/mysqld" "$d/root/etc/my.cnf"
    (cd "$d/root" && eval "$2")
    tar -C "$d/root" -czf "$d/layer.tar.gz" .
    printf '[{"Config":"sha256:c","RepoTags":["x"],"Layers":["layer.tar.gz"]}]' > "$d/manifest.json"
    tar -C "$d" -cf "$TMP/$1.tar" manifest.json layer.tar.gz
  }
  mkfix clean true
  mkfix shell 'ln -s busybox usr/bin/sh'
  export FIXTURE_TAR="$TMP/clean.tar"
  DIGEST=sha256:$(printf 'a%.0s' {1..64}) ARCH_DIGEST=sha256:$(printf 'b%.0s' {1..64})
  # stub docker: records every call; `apko lock` writes the --output file, `apko publish` writes --image-refs.
  cat > "$TMP/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/calls"
args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
  case \${args[i]} in
    # \`apko build <cfg> <tag> <out.tar>\`: the image tarball
    */image.tar) cp "\$FIXTURE_TAR" "\${args[i]}" ;;
    --output) printf '{"contents":{"packages":[%s]}}\n' "\${LOCK_PKGS:-}" > "\${args[i+1]}" ;;
    # like apko: the per-arch image first, the index last
    --image-refs) for t in \${STUB_REFS-x}; do echo "localhost:5000/img@$ARCH_DIGEST"; echo "localhost:5000/img@$DIGEST"; done > "\${args[i+1]}" ;;
  esac
done
exit "\${STUB_RC:-0}"
STUB
  chmod +x "$TMP/docker"
  export DOCKER="$TMP/docker" IMAGES_DIR="$TMP/img" RENDER_DIR="$TMP/rendered" OUT_IMAGES="$TMP/out-images"
  export RESULTS_DIR="$TMP/results" KEY_DIR="$TMP/kd" APK_PUBKEY="$TMP/kd/ps-wolfi-dev.rsa.pub" APK_REPO="$TMP/repo"
  export REPRO_GIT_COMMIT=0123456789abcdef0123456789abcdef01234567
  mkdir -p "$TMP/repo/x86_64"
}

@test "dev image: apko lock, build and publish with arch, lockfile, repo and keyring" {
  run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 0 ]
  lock="$TMP/img/percona-server-dev.lock.json"
  [ -f "$lock" ]
  grep -E -- ' lock .*--arch x86_64' "$TMP/calls"
  grep -E -- " lock .*--output $lock" "$TMP/calls"
  for verb in build publish; do
    line=$(grep -E -- " $verb " "$TMP/calls")
    [[ $line == *"--arch x86_64"* ]]
    [[ $line == *"--lockfile $lock"* ]]
    [[ $line == *"--repository-append $TMP/repo"* ]]
    [[ $line == *"--keyring-append $APK_PUBKEY"* ]]
    [[ $line == *"--sbom-path $TMP/out-images/percona-server-dev"* ]]
    [[ $line == *"$TMP/rendered/percona-server-dev.apko.yaml"* ]]
  done
  grep -E -- ' build .*/image\.tar' "$TMP/calls"
}

@test "digest of the published index (not the per-arch image) is written to the results dir" {
  run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/results/percona-server-dev.digest")" = "$DIGEST" ]
  [[ $output == *"$DIGEST"* ]]
}

@test "tags: series and full version, -dev suffix, same repository; registry overridable" {
  REGISTRY=reg.example:5001 run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 0 ]
  ver=$(grep '^ps_version:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)
  rel=$(grep '^ps_release:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)
  line=$(grep -E -- ' publish ' "$TMP/calls")
  [[ $line == *"reg.example:5001/percona-server:9.7-dev"* ]]
  [[ $line == *"reg.example:5001/percona-server:$ver-$rel-dev"* ]]
  run "$ROOT/scripts/apko-build.sh" percona-server
  line=$(grep -E -- ' publish ' "$TMP/calls" | tail -n1)
  [[ $line == *"localhost:5000/percona-server:9.7 "* ]]
  [[ $line == *"localhost:5000/percona-server:$ver-$rel"* ]]
  run bash -c "grep -o 'percona-server:[^ ]*' <<<'$line' | grep -q -- -dev"; [ "$status" -ne 0 ]   # no -dev tag
}

@test "xtrabackup image is tagged with the xtrabackup version" {
  BUILD_ID=7 run "$ROOT/scripts/apko-build.sh" percona-xtrabackup
  [ "$status" -eq 0 ]
  v=$(grep '^pxb_version:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)-$(grep '^pxb_release:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)
  line=$(grep -E -- ' publish ' "$TMP/calls")
  [[ $line == *"localhost:5000/percona-xtrabackup:9.7 "* ]]
  [[ $line == *"localhost:5000/percona-xtrabackup:$v "* ]]
  [[ $line == *"localhost:5000/percona-xtrabackup:$v-7"* ]]
}

@test "reproducible inputs: build date from source_date_epoch, no VCS autodetect, revision annotation" {
  run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 0 ]
  epoch=$(grep '^source_date_epoch' "$ROOT/versions/9.7.yaml" | tr -dc 0-9)
  date=$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)
  for verb in build publish; do
    line=$(grep -E -- " $verb " "$TMP/calls")
    [[ $line == *"SOURCE_DATE_EPOCH=$epoch"* ]]
    [[ $line == *"--build-date $date"* ]]
    [[ $line == *"--vcs=false"* ]]
    [[ $line == *"--annotations org.opencontainers.image.revision:$REPRO_GIT_COMMIT"* ]]
  done
}

@test "existing lock file is used, not regenerated; RELOCK=1 regenerates it" {
  echo '{"keep":1}' > "$TMP/img/percona-server-dev.lock.json"
  run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 0 ]
  run grep -E -- ' lock ' "$TMP/calls"; [ "$status" -ne 0 ]
  grep -q keep "$TMP/img/percona-server-dev.lock.json"
  RELOCK=1 run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 0 ]
  grep -E -- ' lock ' "$TMP/calls"
  run grep -q keep "$TMP/img/percona-server-dev.lock.json"; [ "$status" -ne 0 ]
}

@test "--no-publish builds the tarball only and writes no digest" {
  run "$ROOT/scripts/apko-build.sh" percona-server-dev --no-publish
  [ "$status" -eq 0 ]
  grep -E -- ' build ' "$TMP/calls"
  run grep -E -- ' publish ' "$TMP/calls"; [ "$status" -ne 0 ]
  [ ! -e "$TMP/results/percona-server-dev.digest" ]
}

@test "publish runs on the host network (registry on localhost)" {
  run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 0 ]
  grep -E -- '--network host .* publish ' "$TMP/calls"
}

@test "distroless image: a shell or apk-tools in the lock file fails the build" {
  LOCK_PKGS='{"name":"wolfi-baselayout"},{"name":"busybox"}' run "$ROOT/scripts/apko-build.sh" percona-server
  [ "$status" -ne 0 ]
  [[ $output == *busybox* ]]
  run grep -E -- ' (build|publish) ' "$TMP/calls"; [ "$status" -ne 0 ]
  # the same package is fine in the -dev image
  LOCK_PKGS='{"name":"busybox"}' run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 0 ]
}

@test "publish output without a digest fails" {
  STUB_REFS="" run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -ne 0 ]
  [ ! -e "$TMP/results/percona-server-dev.digest" ]
}

@test "failing apko fails the script" {
  STUB_RC=3 run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -ne 0 ]
}

@test "unknown image, bad name, missing key and no args fail" {
  run "$ROOT/scripts/apko-build.sh" nope
  [ "$status" -eq 1 ]
  run "$ROOT/scripts/apko-build.sh" '../x'
  [ "$status" -eq 1 ]
  run "$ROOT/scripts/apko-build.sh"
  [ "$status" -eq 1 ]
  APK_PUBKEY="$TMP/kd/missing.pub" run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 1 ]
  [ ! -e "$TMP/calls" ]
}

# mkgit_img <dir>: repo whose first commit touches a build input (images/*.tmpl)
mkgit_img() {
  mkdir -p "$1/images"
  git -C "$1" init -q
  echo t > "$1/images/percona-server-dev.apko.yaml.tmpl"
  git -C "$1" add -A
  git -C "$1" -c user.email=a@b -c user.name=a commit -q -m x
}

@test "dirty build inputs: revision annotation is <sha>-dirty; RELEASE=1 refuses it unless ALLOW_DIRTY=1" {
  unset REPRO_GIT_COMMIT
  g="$TMP/git"
  mkgit_img "$g"
  sha=$(git -C "$g" rev-parse HEAD)
  touch "$g/images/new.apko.yaml.tmpl"
  GIT_REPO="$g" run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 0 ]
  grep -q -- "org.opencontainers.image.revision:$sha-dirty" "$TMP/calls"
  GIT_REPO="$g" RELEASE=1 run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 1 ]
  GIT_REPO="$g" RELEASE=1 ALLOW_DIRTY=1 run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 0 ]
}

@test "revision annotation: last build-input commit; lock files and docs neither dirty it nor move it" {
  unset REPRO_GIT_COMMIT
  g="$TMP/git"
  mkgit_img "$g"
  sha=$(git -C "$g" rev-parse HEAD)
  mkdir -p "$g/docs"
  echo l > "$g/images/percona-server-dev.lock.json"; echo d > "$g/docs/x.md"
  git -C "$g" add -A
  git -C "$g" -c user.email=a@b -c user.name=a commit -q -m "chore: image lock files"
  touch "$g/images/percona-server.lock.json" "$g/docs/y.md"
  echo '{}' > "$TMP/img/percona-server-dev.lock.json"   # RELEASE=1 needs a committed lock in IMAGES_DIR
  GIT_REPO="$g" RELEASE=1 run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 0 ]
  grep -q -- "org.opencontainers.image.revision:$sha " "$TMP/calls"
}

@test "distroless: a shell file in the image fails the build even if no package name matched" {
  FIXTURE_TAR="$TMP/shell.tar" run "$ROOT/scripts/apko-build.sh" percona-server --no-publish
  [ "$status" -ne 0 ]
  [[ $output == *"usr/bin/sh"* ]]
  run "$ROOT/scripts/apko-build.sh" percona-server --no-publish
  [ "$status" -eq 0 ]
  # the file check applies to the distroless image only
  FIXTURE_TAR="$TMP/shell.tar" run "$ROOT/scripts/apko-build.sh" percona-server-dev --no-publish
  [ "$status" -eq 0 ]
}

@test "distroless: no image tarball after build fails" {
  FIXTURE_TAR=/nonexistent run "$ROOT/scripts/apko-build.sh" percona-server --no-publish
  [ "$status" -ne 0 ]
}

@test "package rules: -binsh and apk-tools variants, mysqlsh, agent and dev scripts are rejected where forbidden" {
  for p in busybox-full dash-binsh apk-tools-static percona-mysql-shell-jit percona-telemetry-agent percona-server-docker-scripts; do
    rm -f "$TMP/img/percona-server.lock.json" "$TMP/calls"
    LOCK_PKGS="{\"name\":\"$p\"}" run "$ROOT/scripts/apko-build.sh" percona-server
    [ "$status" -ne 0 ]
    [[ $output == *"$p"* ]]
  done
  for p in percona-mysql-shell percona-telemetry-agent; do
    rm -f "$TMP/img/percona-xtrabackup.lock.json"
    LOCK_PKGS="{\"name\":\"$p\"}" run "$ROOT/scripts/apko-build.sh" percona-xtrabackup
    [ "$status" -ne 0 ]
  done
  rm -f "$TMP/img/percona-server-dev.lock.json"
  LOCK_PKGS='{"name":"percona-xtrabackup-docker-scripts"}' run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -ne 0 ]
  rm -f "$TMP/img/percona-server-dev.lock.json"
  LOCK_PKGS='{"name":"percona-mysql-shell"},{"name":"percona-telemetry-agent"},{"name":"percona-server-docker-scripts"}' \
    run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 0 ]
}

@test "distroless: interpreters (perl, python) and the scripts subpackage are rejected; -dev allows them" {
  for p in perl python-3.13 percona-server-scripts jemalloc; do
    rm -f "$TMP/img/percona-server.lock.json"
    LOCK_PKGS="{\"name\":\"$p\"}" run "$ROOT/scripts/apko-build.sh" percona-server
    [ "$status" -ne 0 ]
    [[ $output == *"must not contain: $p"* ]]
  done
  # the jemalloc runtime library alone is fine
  rm -f "$TMP/img/percona-server.lock.json"
  LOCK_PKGS='{"name":"libjemalloc2"},{"name":"perl-dbd"}' run "$ROOT/scripts/apko-build.sh" percona-server
  [ "$status" -ne 0 ]
  rm -f "$TMP/img/percona-server.lock.json"
  LOCK_PKGS='{"name":"libjemalloc2"}' run "$ROOT/scripts/apko-build.sh" percona-server
  [ "$status" -eq 0 ]
  rm -f "$TMP/img/percona-server-dev.lock.json"
  LOCK_PKGS='{"name":"perl"},{"name":"percona-server-scripts"},{"name":"jemalloc"}' run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 0 ]
}

@test "RELEASE=1 with no committed lock file fails unless RELOCK=1" {
  RELEASE=1 run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 1 ]
  [ ! -e "$TMP/calls" ]
  [ ! -e "$TMP/img/percona-server-dev.lock.json" ]
  RELEASE=1 RELOCK=1 run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 0 ]
  [ -f "$TMP/img/percona-server-dev.lock.json" ]
  # with the lock file present, RELEASE=1 builds from it
  rm -f "$TMP/calls"
  RELEASE=1 run "$ROOT/scripts/apko-build.sh" percona-server-dev
  [ "$status" -eq 0 ]
  run grep -E -- ' lock ' "$TMP/calls"; [ "$status" -ne 0 ]
}

@test "versions: ps_mycnf_url is pinned to ps_commit" {
  f="$ROOT/versions/9.7.yaml"
  commit=$(grep '^ps_commit:' "$f" | cut -d'"' -f2)
  url=$(grep '^ps_mycnf_url:' "$f" | cut -d'"' -f2)
  [ -n "$commit" ]
  [[ $url == "https://raw.githubusercontent.com/percona/percona-server/$commit/"* ]]
}
