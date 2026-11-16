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
  cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
exit "${STUB_CURL_RC:-0}"
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
  [ "$(grep -c '^BUILD package' <<< "$output")" -eq 7 ]
  [[ $output == *"BUILD package percona-server (no $T/repo/x86_64/percona-server-9.7.2.2-r0.apk)"* ]]
  [[ $output == *"BUILD image percona-server (no lock file (first build))"* ]]
  [[ $output == *"BUILD image percona-server-dev (no lock file (first build))"* ]]
  [ ! -e "$T/calls" ]
}

@test "build runs sources, vendor-v8 before pkg-v8, packages in order, then the images; a second run skips all" {
  have_apks
  run "$S"
  [ "$status" -eq 0 ]
  run cat "$T/calls"
  [ "${lines[0]}" = "sources RELOCK=" ]
  [ "${lines[1]}" = "pkg-mecab RELOCK=" ]
  [ "${lines[3]}" = "vendor-v8 RELOCK=" ]
  [ "${lines[4]}" = "pkg-v8 RELOCK=" ]
  [ "${lines[8]}" = "pkg-percona-server-docker-scripts RELOCK=" ]
  [ "${lines[9]}" = "registry-up RELOCK=" ]
  [ "${lines[10]}" = "image-percona-server RELOCK=" ]
  [ "${lines[11]}" = "image-percona-server-dev RELOCK=" ]
  [ -s "$T/stamps/pkg-percona-server" ] && [ -s "$T/stamps/image-percona-server-dev" ]
  rm "$T/calls"
  run "$S"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^SKIP' <<< "$output")" -eq 9 ]
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
  for p in v8 percona-server percona-mysql-shell percona-server-docker-scripts; do
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
  [ "$(grep -c '(--force)' <<< "$output")" -eq 9 ]
}

@test "bad arguments are rejected" {
  run "$S" nope
  [ "$status" -ne 0 ]
  run "$S" --packages-only --images-only
  [ "$status" -ne 0 ]
  [[ $output == *"exclude each other"* ]]
}
