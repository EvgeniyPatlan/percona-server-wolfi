#!/usr/bin/env bats

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  TMP=$BATS_TEST_TMPDIR
  mkdir -p "$TMP/img" "$TMP/kd"
  for n in percona-server percona-server-dev percona-xtrabackup percona-mysql-router percona-haproxy percona-fluentbit percona-orchestrator \
    percona-server-mysql-operator percona-xtradb-cluster-operator percona-proxysql3 percona-xtradb-cluster \
    percona-xtradb-cluster-backup percona-binlog-server percona-toolkit pmm-client; do
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

@test "router image is tagged with the server version in its own repository" {
  BUILD_ID=7 run "$ROOT/scripts/apko-build.sh" percona-mysql-router
  [ "$status" -eq 0 ]
  v=$(grep '^ps_version:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)-$(grep '^ps_release:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)
  line=$(grep -E -- ' publish ' "$TMP/calls")
  [[ $line == *"localhost:5000/percona-mysql-router:9.7 "* ]]
  [[ $line == *"localhost:5000/percona-mysql-router:$v "* ]]
  [[ $line == *"localhost:5000/percona-mysql-router:$v-7"* ]]
}

@test "haproxy and fluentbit images are tagged with their own product version in their own repositories" {
  for n in haproxy fluentbit; do
    rm -f "$TMP/calls"
    BUILD_ID=7 run "$ROOT/scripts/apko-build.sh" "percona-$n"
    [ "$status" -eq 0 ]
    v=$(grep "^${n}_version:" "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)
    s=$(grep "^${n}_series:" "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)
    [[ $v == "$s".* ]]
    line=$(grep -E -- ' publish ' "$TMP/calls")
    [[ $line == *"localhost:5000/percona-$n:$s "* ]]
    [[ $line == *"localhost:5000/percona-$n:$v "* ]]
    [[ $line == *"localhost:5000/percona-$n:$v-7"* ]]
  done
}

@test "orchestrator image is tagged with the orchestrator version in its own repository" {
  BUILD_ID=7 run "$ROOT/scripts/apko-build.sh" percona-orchestrator
  [ "$status" -eq 0 ]
  ov=$(grep '^orc_version:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)
  v=$ov-$(grep '^orc_release:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)
  line=$(grep -E -- ' publish ' "$TMP/calls")
  [[ $line == *"localhost:5000/percona-orchestrator:$ov "* ]]
  [[ $line == *"localhost:5000/percona-orchestrator:$v "* ]]
  [[ $line == *"localhost:5000/percona-orchestrator:$v-7"* ]]
  [[ $line != *"percona-orchestrator:9.7"* ]]
}

@test "operator images: one tag, the operator version, and the operator's commit time as build date" {
  vf=$ROOT/versions/9.7.yaml
  for n in percona-server-mysql-operator:ps percona-xtradb-cluster-operator:pxc; do
    img=${n%%:*} k=${n#*:}
    : > "$TMP/calls"
    BUILD_ID=7 run "$ROOT/scripts/apko-build.sh" "$img"
    [ "$status" -eq 0 ]
    v=$(grep "^${k}_operator_version:" "$vf" | cut -d'"' -f2)
    epoch=$(grep "^${k}_operator_source_date_epoch:" "$vf" | cut -d'"' -f2)
    line=$(grep -E -- ' publish ' "$TMP/calls")
    [[ $line == *"localhost:5000/$img:$v "* ]]
    [[ $line == *"localhost:5000/$img:$v-7"* ]]
    [ "$(grep -o "localhost:5000/$img:[^ ]*" <<< "$line" | sort -u | wc -l)" -eq 2 ]
    [[ $line == *"--build-date $(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)"* ]]
  done
}

@test "proxysql3 image is tagged with the ProxySQL version in its own repository" {
  BUILD_ID=7 run "$ROOT/scripts/apko-build.sh" percona-proxysql3
  [ "$status" -eq 0 ]
  v=$(grep '^proxysql_version:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)
  line=$(grep -E -- ' publish ' "$TMP/calls")
  [[ $line == *"localhost:5000/percona-proxysql3:${v%.*} "* ]]
  [[ $line == *"localhost:5000/percona-proxysql3:$v "* ]]
  [[ $line == *"localhost:5000/percona-proxysql3:$v-7"* ]]
}

@test "PXC images are tagged with the PXC version in their own repositories" {
  v=$(grep '^pxc_version:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)-$(grep '^pxc_release:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)
  v=$v.$(grep '^pxc_rpm_release:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)
  for n in percona-xtradb-cluster percona-xtradb-cluster-backup; do
    rm -f "$TMP/calls"
    BUILD_ID=7 run "$ROOT/scripts/apko-build.sh" "$n"
    [ "$status" -eq 0 ]
    line=$(grep -E -- ' publish ' "$TMP/calls")
    [[ $line == *"localhost:5000/$n:9.7 "* ]]
    [[ $line == *"localhost:5000/$n:$v "* ]]
    [[ $line == *"localhost:5000/$n:$v-7"* ]]
  done
}

@test "binlog server image is tagged with its own version series in its own repository" {
  BUILD_ID=7 run "$ROOT/scripts/apko-build.sh" percona-binlog-server
  [ "$status" -eq 0 ]
  pv=$(grep '^pbs_version:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)
  v=$pv-$(grep '^pbs_release:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)
  line=$(grep -E -- ' publish ' "$TMP/calls")
  [[ $line == *"localhost:5000/percona-binlog-server:${pv%.*} "* ]]
  [[ $line == *"localhost:5000/percona-binlog-server:$v "* ]]
  [[ $line == *"localhost:5000/percona-binlog-server:$v-7"* ]]
  [[ $line != *":9.7"* ]]
}

@test "toolkit image is tagged with the toolkit version line in its own repository" {
  BUILD_ID=7 run "$ROOT/scripts/apko-build.sh" percona-toolkit
  [ "$status" -eq 0 ]
  pv=$(grep '^pt_version:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)
  v=$pv-$(grep '^pt_release:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)
  line=$(grep -E -- ' publish ' "$TMP/calls")
  [[ $line == *"localhost:5000/percona-toolkit:${pv%.*} "* ]]
  [[ $line == *"localhost:5000/percona-toolkit:$v "* ]]
  [[ $line == *"localhost:5000/percona-toolkit:$v-7"* ]]
  [[ $line != *"percona-toolkit:9.7"* ]]
}

@test "pmm-client image is tagged with the major and the PMM version in its own repository" {
  BUILD_ID=7 run "$ROOT/scripts/apko-build.sh" pmm-client
  [ "$status" -eq 0 ]
  v=$(grep '^pmm_version:' "$ROOT/versions/9.7.yaml" | cut -d'"' -f2)
  line=$(grep -E -- ' publish ' "$TMP/calls")
  [[ $line == *"localhost:5000/pmm-client:${v%%.*} "* ]]
  [[ $line == *"localhost:5000/pmm-client:$v "* ]]
  [[ $line == *"localhost:5000/pmm-client:$v-7"* ]]
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
  # router: mysqlsh (+ jit) allowed by owner ruling; no telemetry agent, no server, no other image's scripts
  for p in percona-telemetry-agent percona-server-server percona-server-docker-scripts percona-xtrabackup-docker-scripts; do
    rm -f "$TMP/img/percona-mysql-router.lock.json"
    LOCK_PKGS="{\"name\":\"$p\"}" run "$ROOT/scripts/apko-build.sh" percona-mysql-router
    [ "$status" -ne 0 ]
  done
  rm -f "$TMP/img/percona-mysql-router.lock.json"
  LOCK_PKGS='{"name":"percona-mysql-router"},{"name":"percona-mysql-shell"},{"name":"percona-mysql-shell-jit"}' \
    run "$ROOT/scripts/apko-build.sh" percona-mysql-router
  [ "$status" -eq 0 ]
  # haproxy / fluentbit: no server, mysqlsh, agent or other image's scripts; haproxy only as the -nocaps build
  for n in haproxy fluentbit; do
    for p in percona-server-server percona-mysql-shell percona-telemetry-agent percona-server-docker-scripts \
      percona-mysql-router-docker-scripts percona-xtrabackup-docker-scripts; do
      rm -f "$TMP/img/percona-$n.lock.json"
      LOCK_PKGS="{\"name\":\"$p\"}" run "$ROOT/scripts/apko-build.sh" "percona-$n"
      [ "$status" -ne 0 ]
    done
  done
  for p in haproxy-3.4 percona-fluentbit-docker-scripts; do
    rm -f "$TMP/img/percona-haproxy.lock.json"
    LOCK_PKGS="{\"name\":\"$p\"}" run "$ROOT/scripts/apko-build.sh" percona-haproxy
    [ "$status" -ne 0 ]
  done
  rm -f "$TMP/img/percona-haproxy.lock.json"
  LOCK_PKGS='{"name":"haproxy-3.4-nocaps"},{"name":"bash-binsh"},{"name":"percona-server-client"},{"name":"percona-haproxy-docker-scripts"}' \
    run "$ROOT/scripts/apko-build.sh" percona-haproxy
  [ "$status" -eq 0 ]
  rm -f "$TMP/img/percona-fluentbit.lock.json"
  LOCK_PKGS='{"name":"fluent-bit-5.0"},{"name":"bash-binsh"},{"name":"percona-server-client"},{"name":"percona-fluentbit-docker-scripts"}' \
    run "$ROOT/scripts/apko-build.sh" percona-fluentbit
  [ "$status" -eq 0 ]
  # orchestrator: none of the server, router, xtrabackup, mysqlsh or telemetry packages
  for p in percona-server-libs percona-server-docker-scripts percona-mysql-router percona-mysql-shell \
    percona-telemetry-agent percona-xtrabackup-docker-scripts; do
    rm -f "$TMP/img/percona-orchestrator.lock.json"
    LOCK_PKGS="{\"name\":\"$p\"}" run "$ROOT/scripts/apko-build.sh" percona-orchestrator
    [ "$status" -ne 0 ]
  done
  rm -f "$TMP/img/percona-orchestrator.lock.json"
  LOCK_PKGS='{"name":"percona-orchestrator"},{"name":"percona-orchestrator-client"},{"name":"percona-orchestrator-docker-scripts"},{"name":"bash"}' \
    run "$ROOT/scripts/apko-build.sh" percona-orchestrator
  [ "$status" -eq 0 ]
}

@test "operator images: no server, client, shell, other operator or interpreter packages" {
  for p in percona-server percona-server-client percona-server-libs percona-mysql-shell percona-mysql-router \
    percona-xtrabackup percona-telemetry-agent percona-xtradb-cluster-operator-helpers python-3.13 perl; do
    rm -f "$TMP/img/percona-server-mysql-operator.lock.json"
    LOCK_PKGS="{\"name\":\"$p\"}" run "$ROOT/scripts/apko-build.sh" percona-server-mysql-operator
    [ "$status" -ne 0 ]
  done
  rm -f "$TMP/img/percona-xtradb-cluster-operator.lock.json"
  LOCK_PKGS='{"name":"percona-server-mysql-operator"}' run "$ROOT/scripts/apko-build.sh" percona-xtradb-cluster-operator
  [ "$status" -ne 0 ]
  for n in percona-server-mysql-operator percona-xtradb-cluster-operator; do
    rm -f "$TMP/img/$n.lock.json"
    LOCK_PKGS="{\"name\":\"$n\"},{\"name\":\"$n-helpers\"},{\"name\":\"bash\"},{\"name\":\"busybox\"}" \
      run "$ROOT/scripts/apko-build.sh" "$n"
    [ "$status" -eq 0 ]
  done
  # proxysql3: the server client and my_print_defaults only; no server, mysqlsh, router, telemetry or other scripts
  for p in percona-server-server percona-mysql-shell percona-mysql-router percona-telemetry-agent \
    percona-server-docker-scripts percona-xtrabackup-docker-scripts; do
    rm -f "$TMP/img/percona-proxysql3.lock.json"
    LOCK_PKGS="{\"name\":\"$p\"}" run "$ROOT/scripts/apko-build.sh" percona-proxysql3
    [ "$status" -ne 0 ]
  done
  rm -f "$TMP/img/percona-proxysql3.lock.json"
  LOCK_PKGS='{"name":"proxysql"},{"name":"percona-server-client"},{"name":"percona-proxysql-my-print-defaults"},{"name":"bash"}' \
    run "$ROOT/scripts/apko-build.sh" percona-proxysql3
  [ "$status" -eq 0 ]
}

@test "PXC package rules: no Percona Server server/library packages, no mysqlsh, no other image's scripts" {
  for p in percona-server-server percona-server-libs percona-server-client percona-server-docker-config \
    percona-mysql-shell percona-xtradb-cluster-backup-scripts percona-xtrabackup-docker-scripts; do
    rm -f "$TMP/img/percona-xtradb-cluster.lock.json"
    LOCK_PKGS="{\"name\":\"$p\"}" run "$ROOT/scripts/apko-build.sh" percona-xtradb-cluster
    [ "$status" -ne 0 ]
    [[ $output == *"$p"* ]]
  done
  rm -f "$TMP/img/percona-xtradb-cluster.lock.json"
  LOCK_PKGS='{"name":"percona-xtradb-cluster-server"},{"name":"percona-xtrabackup"},{"name":"percona-telemetry-agent"},{"name":"percona-xtradb-cluster-docker-scripts"}' \
    run "$ROOT/scripts/apko-build.sh" percona-xtradb-cluster
  [ "$status" -eq 0 ]
  # backup image: garbd, xtrabackup and the client, but no PXC server, telemetry agent or server-image scripts
  for p in percona-xtradb-cluster-server percona-telemetry-agent percona-xtradb-cluster-docker-config \
    percona-xtradb-cluster-docker-scripts percona-server-libs; do
    rm -f "$TMP/img/percona-xtradb-cluster-backup.lock.json"
    LOCK_PKGS="{\"name\":\"$p\"}" run "$ROOT/scripts/apko-build.sh" percona-xtradb-cluster-backup
    [ "$status" -ne 0 ]
  done
  rm -f "$TMP/img/percona-xtradb-cluster-backup.lock.json"
  LOCK_PKGS='{"name":"percona-xtradb-cluster-garbd"},{"name":"percona-xtrabackup"},{"name":"percona-xtradb-cluster-client"},{"name":"percona-xtradb-cluster-backup-scripts"}' \
    run "$ROOT/scripts/apko-build.sh" percona-xtradb-cluster-backup
  [ "$status" -eq 0 ]
  # binlog server: the client library only; no server, mysqlsh, telemetry agent, router or other image's scripts
  for p in percona-server-server percona-mysql-shell percona-telemetry-agent percona-mysql-router \
    percona-server-docker-scripts percona-xtrabackup-docker-scripts; do
    rm -f "$TMP/img/percona-binlog-server.lock.json"
    LOCK_PKGS="{\"name\":\"$p\"}" run "$ROOT/scripts/apko-build.sh" percona-binlog-server
    [ "$status" -ne 0 ]
  done
  rm -f "$TMP/img/percona-binlog-server.lock.json"
  LOCK_PKGS='{"name":"percona-binlog-server"},{"name":"percona-binlog-server-docker-scripts"},{"name":"percona-server-libs"},{"name":"bash"}' \
    run "$ROOT/scripts/apko-build.sh" percona-binlog-server
  [ "$status" -eq 0 ]
  # toolkit: perl and shells allowed; no server, mysqlsh, telemetry agent or other image's scripts
  for p in percona-server-server percona-mysql-shell percona-telemetry-agent percona-server-docker-scripts \
    percona-xtrabackup-docker-scripts; do
    rm -f "$TMP/img/percona-toolkit.lock.json"
    LOCK_PKGS="{\"name\":\"$p\"}" run "$ROOT/scripts/apko-build.sh" percona-toolkit
    [ "$status" -ne 0 ]
  done
  rm -f "$TMP/img/percona-toolkit.lock.json"
  LOCK_PKGS='{"name":"percona-toolkit"},{"name":"perl-dbd-mysql"},{"name":"perl"},{"name":"bash"},{"name":"busybox"},{"name":"percona-server-client"}' \
    run "$ROOT/scripts/apko-build.sh" percona-toolkit
  [ "$status" -eq 0 ]
  # pmm-client: the client and the toolkit only; no server, mysqlsh, telemetry agent, router or docker scripts
  for p in percona-server-server percona-mysql-shell percona-telemetry-agent percona-mysql-router \
    percona-server-docker-scripts percona-xtrabackup-docker-scripts; do
    rm -f "$TMP/img/pmm-client.lock.json"
    LOCK_PKGS="{\"name\":\"$p\"}" run "$ROOT/scripts/apko-build.sh" pmm-client
    [ "$status" -ne 0 ]
  done
  rm -f "$TMP/img/pmm-client.lock.json"
  LOCK_PKGS='{"name":"pmm-client"},{"name":"percona-server-client"},{"name":"percona-toolkit"},{"name":"perl"},{"name":"bash"}' \
    run "$ROOT/scripts/apko-build.sh" pmm-client
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

@test "server, -dev, xtrabackup and router images: other images' docker scripts and PXC packages are rejected" {
  reject() { # <image> <package>...
    local img=$1 p; shift
    for p in "$@"; do
      rm -f "$TMP/img/$img.lock.json"
      LOCK_PKGS="{\"name\":\"$p\"}" run "$ROOT/scripts/apko-build.sh" "$img"
      [ "$status" -ne 0 ] || { echo "$img accepted $p"; return 1; }
      [[ $output == *"must not contain: $p"* ]]
    done
  }
  accept() { # <image> <lock package list>
    rm -f "$TMP/img/$1.lock.json"
    LOCK_PKGS=$2 run "$ROOT/scripts/apko-build.sh" "$1"
    [ "$status" -eq 0 ] || { echo "$1 refused: $output"; return 1; }
  }
  newer='percona-haproxy-docker-scripts percona-fluentbit-docker-scripts percona-orchestrator-docker-scripts
    percona-proxysql-docker-scripts percona-xtradb-cluster-docker-scripts percona-binlog-server-docker-scripts'
  # shellcheck disable=SC2086
  reject percona-server $newer percona-server-docker-scripts percona-mysql-router-docker-scripts \
    percona-xtradb-cluster-docker-config percona-xtradb-cluster-server
  # shellcheck disable=SC2086
  reject percona-server-dev $newer percona-xtrabackup-docker-scripts percona-mysql-router-docker-scripts \
    percona-xtradb-cluster-docker-config percona-xtradb-cluster-backup-scripts
  # shellcheck disable=SC2086
  reject percona-xtrabackup $newer percona-server-docker-scripts percona-mysql-router-docker-scripts \
    percona-xtradb-cluster-server percona-xtradb-cluster-docker-config percona-xtradb-cluster-backup-scripts
  # shellcheck disable=SC2086
  reject percona-mysql-router $newer percona-server-docker-scripts percona-xtrabackup-docker-scripts \
    percona-xtradb-cluster-garbd
  # what each image does ship still passes
  accept percona-server-dev '{"name":"percona-server-docker-scripts"},{"name":"percona-server-docker-config"}'
  accept percona-xtrabackup '{"name":"percona-xtrabackup-docker-scripts"},{"name":"percona-xtradb-cluster-garbd"}'
  accept percona-mysql-router '{"name":"percona-mysql-router-docker-scripts"},{"name":"percona-mysql-shell-jit"}'
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
