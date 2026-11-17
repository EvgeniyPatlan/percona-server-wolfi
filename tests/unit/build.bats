#!/usr/bin/env bats
# scripts/build.sh: builds only the packages and images whose inputs changed. make and curl are stubs; the real
# recipes and image templates are used, the apk repo, stamps, lock files and results live in the test dir.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  T=$BATS_TEST_TMPDIR
  S="$ROOT/scripts/build.sh"
  mkdir -p "$T/bin" "$T/img" "$T/results" "$T/repo/x86_64" "$T/kd"
  cp "$ROOT"/images/*.apko.yaml.tmpl "$T/img/"
  touch "$T/kd/ps-wolfi-dev.rsa.pub"
  # stub make: logs its target (with RELOCK), "builds" image-<name> by writing a lock with no local packages and a digest
  cat > "$T/bin/make" <<STUB
#!/usr/bin/env bash
shift   # --no-print-directory
echo "\$1 RELOCK=\${RELOCK:-}" >> "$T/calls"
case \$1 in
  image-*) n=\${1#image-}
    echo '{"contents":{"packages":[{"name":"wolfi-baselayout","url":"https://packages.wolfi.dev/os/x.apk"}]}}' > "$T/img/\$n.lock.json"
    echo "sha256:\$(printf 'a%.0s' {1..64})" > "$T/results/\$n.digest" ;;
esac
[[ \$1 != \${STUB_FAIL:-none} ]]
STUB
  cat > "$T/bin/curl" <<STUB
#!/usr/bin/env bash
echo "\${*: -1}" >> "$T/curl.log"
exit "\${STUB_CURL_RC:-0}"
STUB
  chmod +x "$T/bin/make" "$T/bin/curl"
  export MAKE_CMD="$T/bin/make" CURL="$T/bin/curl" STAMP_DIR="$T/stamps" APK_REPO="$T/repo" IMAGES_DIR="$T/img" \
    RESULTS_DIR="$T/results" KEY_DIR="$T/kd" REGISTRY=localhost:5000
  unset VERSION_FILE RELOCK
}

# have_apks: create every main apk the dry run reports as missing
have_apks() {
  run "$S" -n --packages-only
  local p
  while read -r p; do echo apk > "$p"; done < <(grep -oE 'no [^ ]+\.apk' <<< "$output" | cut -d' ' -f2)
}

@test "build order matches PACKAGES in mk/packages.mk" {
  want=$(sed -n '/^PACKAGES :=/,/[^\\]$/p' "$ROOT/mk/packages.mk" | sed 's/PACKAGES :=//; s/\\//' | tr -s ' \n' ' ' | xargs)
  got=$(sed -n 's/^ORDER=(\(.*\))$/\1/p' "$S")
  [ "$got" = "$want" ]
}

@test "fresh tree: every package and image is planned, a dry run calls nothing" {
  run "$S" -n
  [ "$status" -eq 0 ]
  [ "$(grep -c '^BUILD package' <<< "$output")" -eq 20 ]
  [[ $output == *"BUILD package percona-server (no $T/repo/x86_64/percona-server-9.7.2.2-r0.apk)"* ]]
  [[ $output == *"BUILD image percona-server (no lock file (first build))"* ]]
  [[ $output == *"BUILD image percona-server-dev (no lock file (first build))"* ]]
  [[ $output == *"BUILD image percona-xtrabackup (no lock file (first build))"* ]]
  [[ $output == *"BUILD image percona-mysql-router (no lock file (first build))"* ]]
  [[ $output == *"BUILD image percona-haproxy (no lock file (first build))"* ]]
  [[ $output == *"BUILD image percona-fluentbit (no lock file (first build))"* ]]
  [[ $output == *"BUILD image percona-orchestrator (no lock file (first build))"* ]]
  [[ $output == *"BUILD image percona-server-mysql-operator (no lock file (first build))"* ]]
  [[ $output == *"BUILD image percona-xtradb-cluster-operator (no lock file (first build))"* ]]
  [[ $output == *"BUILD image percona-proxysql3 (no lock file (first build))"* ]]
  [[ $output == *"BUILD package percona-xtradb-cluster (no $T/repo/x86_64/percona-xtradb-cluster-9.7.2.2.1-r0.apk)"* ]]
  [[ $output == *"BUILD image percona-xtradb-cluster (no lock file (first build))"* ]]
  [[ $output == *"BUILD image percona-xtradb-cluster-backup (no lock file (first build))"* ]]
  [ ! -e "$T/calls" ]
}

@test "build runs sources, vendor-v8 before pkg-v8, packages in order, then the images; a second run skips all" {
  have_apks
  run "$S"
  [ "$status" -eq 0 ]
  run cat "$T/calls"
  [ "${lines[0]}" = "sources RELOCK=" ]
  [ "${lines[1]}" = "git-mirrors RELOCK=" ]
  [ "${lines[2]}" = "pkg-mecab RELOCK=" ]
  [ "${lines[4]}" = "vendor-v8 RELOCK=" ]
  [ "${lines[5]}" = "pkg-v8 RELOCK=" ]
  [ "${lines[8]}" = "pkg-percona-xtrabackup RELOCK=" ]
  [ "${lines[11]}" = "pkg-percona-xtrabackup-docker-scripts RELOCK=" ]
  [ "${lines[12]}" = "pkg-percona-mysql-router-docker-scripts RELOCK=" ]
  [ "${lines[13]}" = "pkg-percona-haproxy-docker-scripts RELOCK=" ]
  [ "${lines[14]}" = "pkg-percona-fluentbit-docker-scripts RELOCK=" ]
  [ "${lines[15]}" = "pkg-percona-orchestrator RELOCK=" ]
  [ "${lines[16]}" = "pkg-percona-orchestrator-docker-scripts RELOCK=" ]
  [ "${lines[17]}" = "pkg-percona-server-mysql-operator RELOCK=" ]
  [ "${lines[18]}" = "pkg-percona-xtradb-cluster-operator RELOCK=" ]
  [ "${lines[19]}" = "pkg-percona-proxysql-admin RELOCK=" ]
  [ "${lines[20]}" = "pkg-percona-proxysql-docker-scripts RELOCK=" ]
  [ "${lines[21]}" = "pkg-percona-xtradb-cluster RELOCK=" ]
  [ "${lines[22]}" = "pkg-percona-xtradb-cluster-docker-scripts RELOCK=" ]
  [ "${lines[23]}" = "registry-up RELOCK=" ]
  [ "${lines[24]}" = "image-percona-server RELOCK=" ]
  [ "${lines[25]}" = "image-percona-server-dev RELOCK=" ]
  [ "${lines[26]}" = "image-percona-xtrabackup RELOCK=" ]
  [ "${lines[27]}" = "image-percona-mysql-router RELOCK=" ]
  [ "${lines[28]}" = "image-percona-haproxy RELOCK=" ]
  [ "${lines[29]}" = "image-percona-fluentbit RELOCK=" ]
  [ "${lines[30]}" = "image-percona-orchestrator RELOCK=" ]
  [ "${lines[31]}" = "image-percona-server-mysql-operator RELOCK=" ]
  [ "${lines[32]}" = "image-percona-xtradb-cluster-operator RELOCK=" ]
  [ "${lines[33]}" = "image-percona-proxysql3 RELOCK=" ]
  [ "${lines[34]}" = "image-percona-xtradb-cluster RELOCK=" ]
  [ "${lines[35]}" = "image-percona-xtradb-cluster-backup RELOCK=" ]
  [ -s "$T/stamps/pkg-percona-server" ] && [ -s "$T/stamps/image-percona-xtrabackup" ]
  rm "$T/calls"
  run "$S"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^SKIP' <<< "$output")" -eq 32 ]
  run cat "$T/calls"
  [ "$output" = "registry-up RELOCK=" ]
}

@test "a changed pin rebuilds that package and the packages built on it, nothing else" {
  have_apks
  "$S" > /dev/null 2>&1
  sed 's/^v8_src_sha256: .*/v8_src_sha256: "0000"/' "$ROOT/versions/9.7.yaml" > "$T/v.yaml"
  VERSION_FILE=$T/v.yaml run "$S" -n --packages-only
  [[ $output == *"SKIP  package mecab (up to date)"* ]]
  [[ $output == *"SKIP  package percona-telemetry-agent (up to date)"* ]]
  [[ $output == *"SKIP  package percona-xtrabackup-docker-scripts (up to date)"* ]]
  [[ $output == *"SKIP  package percona-orchestrator (up to date)"* ]]
  [[ $output == *"SKIP  package percona-orchestrator-docker-scripts (up to date)"* ]]
  [[ $output == *"SKIP  package percona-server-mysql-operator (up to date)"* ]]
  [[ $output == *"SKIP  package percona-xtradb-cluster-operator (up to date)"* ]]
  [[ $output == *"SKIP  package percona-xtradb-cluster-docker-scripts (up to date)"* ]]
  for p in v8 percona-server percona-mysql-shell percona-xtrabackup percona-server-docker-scripts \
    percona-mysql-router-docker-scripts percona-haproxy-docker-scripts percona-fluentbit-docker-scripts percona-proxysql-admin percona-proxysql-docker-scripts percona-xtradb-cluster; do
    [[ $output == *"BUILD package $p (inputs changed)"* ]]
  done
}

@test "a failed package build stops the run: earlier stamps kept, its own and later ones unwritten" {
  have_apks
  STUB_FAIL=pkg-mecab-ipadic run "$S" --packages-only
  [ "$status" -ne 0 ]
  [ -s "$T/stamps/pkg-mecab" ]
  [ ! -e "$T/stamps/pkg-mecab-ipadic" ]
  run grep -q '^pkg-v8 ' "$T/calls"
  [ "$status" -ne 0 ]
  run "$S" -n --packages-only
  [[ $output == *"SKIP  package mecab (up to date)"* ]]
  [[ $output == *"BUILD package mecab-ipadic (never built by build.sh)"* ]]
}

@test "distroless only: no mysqlsh, no telemetry agent, only that image" {
  run "$S" -n percona-server
  [[ $output != *"percona-mysql-shell"* ]]
  [[ $output != *"percona-telemetry-agent"* ]]
  [[ $output != *"image percona-server-dev"* ]]
  [[ $output == *"BUILD package percona-server-docker-scripts"* ]]
  [[ $output != *"xtrabackup"* ]]
  [[ $output != *"router"* ]]
  [[ $output != *"orchestrator"* ]]
  [[ $output != *"proxysql"* ]]
}

@test "proxysql3 only: the server (client) and the two proxysql packages, nothing else; its own registry repository" {
  run "$S" -n percona-proxysql3
  [[ $output == *"BUILD package percona-server ("* ]]
  [[ $output == *"BUILD package percona-proxysql-admin ("* ]]
  [[ $output == *"BUILD package percona-proxysql-docker-scripts ("* ]]
  [[ $output != *"percona-mysql-shell"* ]]
  [[ $output != *"percona-telemetry-agent"* ]]
  [[ $output != *"xtrabackup"* ]]
  [[ $output != *"router"* ]]
  [[ $output != *"image percona-server"* ]]
  have_apks
  "$S" percona-proxysql3 > /dev/null 2>&1
  run "$S" -n percona-proxysql3
  [[ $output == *"SKIP  image percona-proxysql3 (up to date)"* ]]
  grep -q "^http://localhost:5000/v2/percona-proxysql3/manifests/sha256:" "$T/curl.log"
}

@test "router only: the server and mysqlsh, no telemetry agent or xtrabackup; its own registry repository" {
  run "$S" -n percona-mysql-router
  [[ $output == *"BUILD package percona-server ("* ]]
  [[ $output == *"BUILD package percona-mysql-shell ("* ]]
  [[ $output == *"BUILD package percona-mysql-router-docker-scripts ("* ]]
  [[ $output != *"percona-telemetry-agent"* ]]
  [[ $output != *"xtrabackup"* ]]
  [[ $output != *"image percona-server"* ]]
  have_apks
  "$S" percona-mysql-router > /dev/null 2>&1
  run "$S" -n percona-mysql-router
  [[ $output == *"SKIP  image percona-mysql-router (up to date)"* ]]
  grep -q "^http://localhost:5000/v2/percona-mysql-router/manifests/sha256:" "$T/curl.log"
}

@test "haproxy and fluentbit: the server (client) and their own scripts only; their own registry repositories" {
  run "$S" -n percona-haproxy percona-fluentbit
  [[ $output == *"BUILD package percona-server ("* ]]
  [[ $output == *"BUILD package percona-haproxy-docker-scripts ("* ]]
  [[ $output == *"BUILD package percona-fluentbit-docker-scripts ("* ]]
  [[ $output == *"BUILD image percona-haproxy ("* ]]
  [[ $output == *"BUILD image percona-fluentbit ("* ]]
  for p in percona-mysql-shell percona-telemetry-agent xtrabackup router "image percona-server"; do
    [[ $output != *"$p"* ]]
  done
  have_apks
  "$S" percona-haproxy percona-fluentbit > /dev/null 2>&1
  run "$S" -n percona-haproxy percona-fluentbit
  [[ $output == *"SKIP  image percona-haproxy (up to date)"* ]]
  [[ $output == *"SKIP  image percona-fluentbit (up to date)"* ]]
  grep -q "^http://localhost:5000/v2/percona-haproxy/manifests/sha256:" "$T/curl.log"
  grep -q "^http://localhost:5000/v2/percona-fluentbit/manifests/sha256:" "$T/curl.log"
}

@test "orchestrator only: its two packages, no server build; its own registry repository" {
  run "$S" -n percona-orchestrator
  [ "$(grep -c '^BUILD package' <<< "$output")" -eq 2 ]
  [[ $output == *"BUILD package percona-orchestrator ("* ]]
  [[ $output == *"BUILD package percona-orchestrator-docker-scripts ("* ]]
  [[ $output != *"percona-server"* ]]
  [[ $output != *"image percona-mysql-router"* ]]
  have_apks
  "$S" percona-orchestrator > /dev/null 2>&1
  run "$S" -n percona-orchestrator
  [[ $output == *"SKIP  image percona-orchestrator (up to date)"* ]]
  grep -q "^http://localhost:5000/v2/percona-orchestrator/manifests/sha256:" "$T/curl.log"
  # an orchestrator pin (Go series) rebuilds both of its packages
  sed 's/^orc_go: .*/orc_go: "1.27"/' "$ROOT/versions/9.7.yaml" > "$T/v.yaml"
  VERSION_FILE=$T/v.yaml run "$S" -n percona-orchestrator
  [[ $output == *"BUILD package percona-orchestrator (inputs changed)"* ]]
  [[ $output == *"BUILD package percona-orchestrator-docker-scripts (inputs changed)"* ]]
}

@test "operator images: only their own package, nothing of the server; their own registry repositories" {
  run "$S" -n percona-server-mysql-operator percona-xtradb-cluster-operator
  [ "$status" -eq 0 ]
  [ "$(grep -c '^BUILD package' <<< "$output")" -eq 2 ]
  [[ $output == *"BUILD package percona-server-mysql-operator ("* ]]
  [[ $output == *"BUILD package percona-xtradb-cluster-operator ("* ]]
  [[ $output != *"package percona-server ("* ]]
  have_apks
  "$S" percona-server-mysql-operator percona-xtradb-cluster-operator > /dev/null 2>&1
  run "$S" -n percona-server-mysql-operator percona-xtradb-cluster-operator
  [[ $output == *"SKIP  image percona-server-mysql-operator (up to date)"* ]]
  [[ $output == *"SKIP  image percona-xtradb-cluster-operator (up to date)"* ]]
  grep -q "^http://localhost:5000/v2/percona-server-mysql-operator/manifests/sha256:" "$T/curl.log"
  grep -q "^http://localhost:5000/v2/percona-xtradb-cluster-operator/manifests/sha256:" "$T/curl.log"
}

@test "pxc only: PXC, XtraBackup (SST) and the server packages under them, no mysqlsh; own registry repositories" {
  run "$S" -n percona-xtradb-cluster percona-xtradb-cluster-backup
  [[ $output == *"BUILD package percona-xtradb-cluster ("* ]]
  [[ $output == *"BUILD package percona-xtradb-cluster-docker-scripts ("* ]]
  [[ $output == *"BUILD package percona-xtrabackup ("* ]]
  [[ $output == *"BUILD package percona-telemetry-agent ("* ]]
  [[ $output != *"percona-mysql-shell"* ]]
  [[ $output != *"percona-server-docker-scripts"* ]]
  [[ $output != *"percona-xtrabackup-docker-scripts"* ]]
  [[ $output != *"image percona-server"* ]]
  [[ $output != *"image percona-xtrabackup"* ]]
  # the backup image has no telemetry agent
  run "$S" -n percona-xtradb-cluster-backup
  [[ $output != *"percona-telemetry-agent"* ]]
  have_apks
  "$S" percona-xtradb-cluster percona-xtradb-cluster-backup > /dev/null 2>&1
  run "$S" -n percona-xtradb-cluster percona-xtradb-cluster-backup
  [[ $output == *"SKIP  image percona-xtradb-cluster (up to date)"* ]]
  [[ $output == *"SKIP  image percona-xtradb-cluster-backup (up to date)"* ]]
  grep -q "^http://localhost:5000/v2/percona-xtradb-cluster/manifests/sha256:" "$T/curl.log"
  grep -q "^http://localhost:5000/v2/percona-xtradb-cluster-backup/manifests/sha256:" "$T/curl.log"
}

@test "xtrabackup only: the server packages it links against, no -dev extras; its own registry repository" {
  run "$S" -n percona-xtrabackup
  [[ $output == *"BUILD package percona-server ("* ]]
  [[ $output == *"BUILD package percona-xtrabackup ("* ]]
  [[ $output == *"BUILD package percona-xtrabackup-docker-scripts ("* ]]
  # garbd: percona-xtradb-cluster-garbd
  [[ $output == *"BUILD package percona-xtradb-cluster ("* ]]
  [[ $output != *"percona-xtradb-cluster-docker-scripts"* ]]
  [[ $output != *"percona-mysql-shell"* ]]
  [[ $output != *"percona-telemetry-agent"* ]]
  [[ $output != *"percona-server-docker-scripts"* ]]
  [[ $output != *"image percona-server"* ]]
  have_apks
  "$S" percona-xtrabackup > /dev/null 2>&1
  run "$S" -n percona-xtrabackup
  [[ $output == *"SKIP  image percona-xtrabackup (up to date)"* ]]
  grep -q "^http://localhost:5000/v2/percona-xtrabackup/manifests/sha256:" "$T/curl.log"
}

@test "stale lock: the image is re-locked (RELOCK=1) and the rewrite is reported, even with --images-only" {
  have_apks
  "$S" > /dev/null 2>&1
  echo apk > "$T/repo/x86_64/x.apk"
  cat > "$T/img/percona-server.lock.json" <<EOF
{"contents":{"packages":[{"name":"x","url":"$T/repo/x86_64/x.apk","control":{"range":"bytes=0-1","checksum":"sha1-AAAAAAAAAAAAAAAAAAAAAAAAAAA="}}]}}
EOF
  rm -f "$T/calls"
  run "$S" --images-only percona-server
  [ "$status" -eq 0 ]
  [[ $output == *"BUILD image percona-server (lock file stale (x: $T/repo/x86_64/x.apk differs from the lock): re-locking)"* ]]
  [[ $output == *"was rewritten: review and commit it"* ]]
  grep -qx "image-percona-server RELOCK=1" "$T/calls"
}

@test "a digest that is not in the registry rebuilds the image; --force rebuilds everything" {
  have_apks
  "$S" > /dev/null 2>&1
  STUB_CURL_RC=22 run "$S" -n --images-only
  [[ $output == *"BUILD image percona-server (digest not in localhost:5000)"* ]]
  run "$S" -n -f
  [ "$(grep -c '(--force)' <<< "$output")" -eq 32 ]
}

@test "bad arguments are rejected" {
  run "$S" nope
  [ "$status" -ne 0 ]
  run "$S" --packages-only --images-only
  [ "$status" -ne 0 ]
  [[ $output == *"exclude each other"* ]]
}
