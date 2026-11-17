#!/usr/bin/env bats

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  TMP=$BATS_TEST_TMPDIR
  mkdir -p "$TMP/pkgs/foo" "$TMP/kd" "$TMP/ws/foo"
  printf 'package:\n  name: foo\n  version: @@ps_version@@\n' > "$TMP/pkgs/foo/melange.yaml.tmpl"
  touch "$TMP/ws/foo/stale.o" "$TMP/kd/ps-wolfi-dev.rsa" "$TMP/kd/ps-wolfi-dev.rsa.pub"
  # stub docker: records args; fails if the stale file is still present.
  cat > "$TMP/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/calls"
if [ -e "$TMP/ws/foo/stale.o" ]; then echo "STALE PRESENT" >> "$TMP/calls"; exit 9; fi
STUB
  chmod +x "$TMP/docker"
  export DOCKER="$TMP/docker" PKG_DIR="$TMP/pkgs" RENDER_DIR="$TMP/rendered" KEY_DIR="$TMP/kd"
  export APK_PUBKEY="$TMP/kd/ps-wolfi-dev.rsa.pub" SOURCES_DIR="$TMP/src" STAGE_DIR="$TMP/stage"
  export REPRO_GIT_COMMIT=0123456789abcdef0123456789abcdef01234567
  # the melange cache (ccache, git mirrors) of the test, never the repository's out/cache
  export MELANGE_CACHE_DIR="$TMP/cache"
  ARGS=(foo --workspace-root "$TMP/ws" --out "$TMP/repo")
}

@test "stale workspace is deleted before melange runs" {
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  run grep -q "STALE PRESENT" "$TMP/calls"; [ "$status" -ne 0 ]
  [ ! -e "$TMP/ws/foo" ]   # and cleaned up on success
}

@test "command has arch, source date epoch and workspace dir" {
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  epoch=$(grep '^source_date_epoch' "$ROOT/versions/9.7.yaml" | tr -dc 0-9)
  grep -q -- '--privileged' "$TMP/calls"
  grep -q -- '--arch x86_64' "$TMP/calls"
  grep -q -- "SOURCE_DATE_EPOCH=$epoch" "$TMP/calls"
  grep -q -- "--workspace-dir $TMP/ws/foo" "$TMP/calls"
  grep -q -- "--out-dir $TMP/repo" "$TMP/calls"
  grep -q -- "--repository-append $TMP/repo" "$TMP/calls"
  grep -q -- "--keyring-append $APK_PUBKEY" "$TMP/calls"
  grep -q -- '--signing-key /keys/ps-wolfi-dev.rsa' "$TMP/calls"
  grep -q -- '--cache-dir' "$TMP/calls"
}

@test "--no-cache omits --cache-dir" {
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}" --no-cache
  [ "$status" -eq 0 ]
  run grep -q -- "--cache-dir" "$TMP/calls"; [ "$status" -ne 0 ]
}

@test "failed build keeps the workspace and fails" {
  printf '#!/bin/sh\nmkdir -p "%s/ws/foo"\nexit 3\n' "$TMP" > "$TMP/docker"
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -ne 0 ]
  [ -d "$TMP/ws/foo" ]
}

@test "missing template and bad args fail" {
  run "$ROOT/scripts/melange-build.sh" nope --workspace-root "$TMP/ws"
  [ "$status" -eq 1 ]
  run "$ROOT/scripts/melange-build.sh"
  [ "$status" -eq 1 ]
}

@test "keys.sh refuses to overwrite and touches nothing" {
  echo keep > "$TMP/kd/ps-wolfi-dev.rsa"
  run "$ROOT/scripts/keys.sh"
  [ "$status" -eq 1 ]
  [ "$(cat "$TMP/kd/ps-wolfi-dev.rsa")" = keep ]
  [ ! -e "$TMP/calls" ]
}

@test "keys.sh generates into a fresh KEY_DIR without touching repo keys" {
  rm -rf "$TMP/kd"
  cat > "$TMP/docker" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *keygen*) touch "$TMP/kd/ps-wolfi-dev.rsa" "$TMP/kd/ps-wolfi-dev.rsa.pub" ;;
  *generate-key-pair*) touch "$TMP/kd/cosign.key" "$TMP/kd/cosign.pub" ;;
esac
STUB
  run env REPO_PUBKEY="$TMP/repo.pub" "$ROOT/scripts/keys.sh"
  [ "$status" -eq 0 ]
  [ -e "$TMP/kd/cosign.key" ]
  [ ! -e "$TMP/repo.pub" ]   # non-default KEY_DIR: no copy into the repo
}

@test "keys.sh copies the public key to the repo for the default KEY_DIR" {
  unset KEY_DIR
  export HOME="$TMP/home"
  cat > "$TMP/docker" <<STUB
#!/usr/bin/env bash
d="$TMP/home/.config/ps-wolfi"
case "\$*" in
  *keygen*) echo PUB > "\$d/ps-wolfi.rsa.pub"; touch "\$d/ps-wolfi.rsa" ;;
  *generate-key-pair*) touch "\$d/cosign.key" "\$d/cosign.pub" ;;
esac
echo "\$*" >> "$TMP/calls"
STUB
  run env REPO_PUBKEY="$TMP/repo.pub" "$ROOT/scripts/keys.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/repo.pub")" = PUB ]
  grep -q 'keygen /keys/ps-wolfi.rsa' "$TMP/calls"   # release key named like the committed keys/ps-wolfi.rsa.pub
}

@test "relative KEY_DIR is mounted with an absolute path" {
  cd "$ROOT"
  rel=out/test-keys-$$
  mkdir -p "$ROOT/$rel"
  touch "$ROOT/$rel/ps-wolfi-dev.rsa" "$ROOT/$rel/ps-wolfi-dev.rsa.pub"
  run env KEY_DIR="$rel" APK_PUBKEY="$rel/ps-wolfi-dev.rsa.pub" "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  rm -rf "${ROOT:?}/$rel"
  [ "$status" -eq 0 ]
  grep -q -- " -v $ROOT/$rel:/keys:ro" "$TMP/calls"
}

@test "absolute paths under PWD are passed container-relative" {
  cd "$ROOT"
  rm -f "$TMP/ws/foo/stale.o"
  w=$ROOT/out/wsabs-$$
  run env APK_PUBKEY="$APK_PUBKEY" "$ROOT/scripts/melange-build.sh" foo --workspace-root "$w" --out "$ROOT/out/repoabs-$$"
  rm -rf "$w" "${ROOT:?}/out/repoabs-$$"
  [ "$status" -eq 0 ]
  grep -q -- "--workspace-dir out/wsabs-$$/foo" "$TMP/calls"
  grep -q -- "--out-dir out/repoabs-$$" "$TMP/calls"
  run grep -q -- "$ROOT/out" "$TMP/calls"; [ "$status" -ne 0 ]
}

@test "runs melange test against the built repo after build" {
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  grep -q -- "test $TMP/rendered/foo.yaml foo --arch x86_64" "$TMP/calls"
  grep -q -- "--repository-append $TMP/repo" "$TMP/calls"
  grep -q -- "--keyring-append $APK_PUBKEY" "$TMP/calls"
}

@test "default output repo is out/repo" {
  cd "$ROOT"
  run "$ROOT/scripts/melange-build.sh" foo --workspace-root "$TMP/ws"
  [ "$status" -eq 0 ]
  grep -q -- "--out-dir out/repo" "$TMP/calls"
}

@test "source dir is a staged copy of package files plus referenced sources" {
  mkdir -p "$TMP/pkgs/foo/patches" "$TMP/pkgs/foo/tests" "$TMP/src"
  printf 'pipeline:\n  - runs: tar -xf foo-1.tar.gz\n' >> "$TMP/pkgs/foo/melange.yaml.tmpl"
  touch "$TMP/pkgs/foo/patches/0001-x.patch" "$TMP/pkgs/foo/tests/smoke.sh" "$TMP/src/foo-1.tar.gz" "$TMP/src/other.tar.gz" \
    "$TMP/src/oo-1.tar.gz" "$TMP/src/foo-1.tar" "$TMP/src/foo-1+tar.gz"
  cat > "$TMP/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/calls"
[ -e "$TMP/staged" ] || (cd "$TMP/stage/foo" && find . -mindepth 1 | sort) > "$TMP/staged"
STUB
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  grep -qx './patches/0001-x.patch' "$TMP/staged"
  grep -qx './tests/smoke.sh' "$TMP/staged"
  grep -qx './foo-1.tar.gz' "$TMP/staged"
  grep -qx './build-tools/check-build-path-leaks.sh' "$TMP/staged"   # shared helper for recipes
  run grep -q 'other.tar.gz' "$TMP/staged"; [ "$status" -ne 0 ]
  run grep -qx './oo-1.tar.gz' "$TMP/staged"; [ "$status" -ne 0 ]     # substring of a referenced name
  run grep -qx './foo-1.tar' "$TMP/staged"; [ "$status" -ne 0 ]        # prefix of a referenced name
  run grep -qx './foo-1+tar.gz' "$TMP/staged"; [ "$status" -ne 0 ]     # regex metachar must be literal
  run grep -q 'melange.yaml.tmpl' "$TMP/staged"; [ "$status" -ne 0 ]
  [ "$(grep -c -- "--source-dir $TMP/stage/foo" "$TMP/calls")" -eq 2 ]   # build and test
  [ ! -e "$TMP/stage/foo" ]   # removed on success
}

@test "--deps-repo: dependencies come from it; output goes to --out; test sees both" {
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}" --deps-repo "$TMP/deps" --no-cache
  [ "$status" -eq 0 ]
  grep -q -- "--out-dir $TMP/repo" "$TMP/calls"
  grep -q -- "--repository-append $TMP/deps" "$TMP/calls"
  run grep -E -- "^.*build .*--repository-append $TMP/repo" "$TMP/calls"; [ "$status" -ne 0 ]
  grep -E -- "test .*--repository-append $TMP/repo" "$TMP/calls" | grep -q -- "--repository-append $TMP/deps"
}

# mkgit: a git repo whose first commit touches a build input (packages/), so it is the recorded commit.
mkgit() {
  unset REPRO_GIT_COMMIT
  mkdir -p "$TMP/gr/packages"
  git -C "$TMP/gr" init -q
  echo a > "$TMP/gr/packages/p"
  git -C "$TMP/gr" add packages/p
  git -C "$TMP/gr" -c user.name=t -c user.email=t@t commit -q -m inputs
  export GIT_REPO="$TMP/gr"
}

@test "recorded build config excludes ccache env and records the build-input commit" {
  mkgit
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  grep -q -- '--exclude-env-from-recorded-config CCACHE_DIR' "$TMP/calls"
  grep -q -- '--exclude-env-from-recorded-config CCACHE_MAXSIZE' "$TMP/calls"
  grep -q -- "--git-commit $(git -C "$TMP/gr" rev-parse HEAD) " "$TMP/calls"
}

@test "commits that touch only docs, tests or image lock files do not change the recorded commit" {
  mkgit
  want=$(git -C "$TMP/gr" rev-parse HEAD)
  mkdir -p "$TMP/gr/docs" "$TMP/gr/images" "$TMP/gr/tests"
  echo d > "$TMP/gr/docs/x.md"; echo l > "$TMP/gr/images/percona-server.lock.json"; echo t > "$TMP/gr/tests/t.bats"
  git -C "$TMP/gr" add -A
  git -C "$TMP/gr" -c user.name=t -c user.email=t@t commit -q -m docs
  [ "$(git -C "$TMP/gr" rev-parse HEAD)" != "$want" ]
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  grep -q -- "--git-commit $want " "$TMP/calls"
  # a later commit to a build input (scripts, versions, mk, Makefile, packages) is recorded
  for f in scripts/s versions/v mk/m Makefile; do
    mkdir -p "$TMP/gr/$(dirname "$f")"; echo x > "$TMP/gr/$f"
    git -C "$TMP/gr" add -A
    git -C "$TMP/gr" -c user.name=t -c user.email=t@t commit -q -m "$f"
    : > "$TMP/calls"
    run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
    [ "$status" -eq 0 ]
    grep -q -- "--git-commit $(git -C "$TMP/gr" rev-parse HEAD) " "$TMP/calls"
  done
}

@test "no commit touching the build inputs: fails with a hint" {
  unset REPRO_GIT_COMMIT
  mkdir -p "$TMP/g2"
  git -C "$TMP/g2" init -q
  git -C "$TMP/g2" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
  GIT_REPO="$TMP/g2" run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -ne 0 ]
  [[ "$output" == *REPRO_GIT_COMMIT* ]]
}

@test "git-commit is stable across cached and --no-cache invocations" {
  mkgit
  "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  "$ROOT/scripts/melange-build.sh" "${ARGS[@]}" --no-cache
  [ "$(grep -o -- '--git-commit [0-9a-f]*' "$TMP/calls" | sort -u | wc -l)" -eq 1 ]
}

@test "dirty build inputs: recorded as <sha>-dirty with a warning" {
  mkgit; touch "$TMP/gr/packages/x"
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *dirty* ]]
  grep -q -- "--git-commit $(git -C "$TMP/gr" rev-parse HEAD)-dirty " "$TMP/calls"
}

@test "changes outside the build inputs do not make the tree dirty" {
  mkgit
  mkdir -p "$TMP/gr/docs" "$TMP/gr/images"
  touch "$TMP/gr/docs/new.md" "$TMP/gr/images/percona-server.lock.json" "$TMP/gr/notes.txt"
  RELEASE=1 run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  grep -q -- "--git-commit $(git -C "$TMP/gr" rev-parse HEAD) " "$TMP/calls"
  run grep -q -- '-dirty' "$TMP/calls"; [ "$status" -ne 0 ]
}

@test "dirty build inputs with RELEASE=1 die unless ALLOW_DIRTY=1" {
  mkgit; touch "$TMP/gr/packages/x"
  RELEASE=1 run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -ne 0 ]; [[ "$output" == *"dirty"* ]]
  RELEASE=1 ALLOW_DIRTY=1 run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  grep -q -- '-dirty ' "$TMP/calls"
}

@test "REPRO_GIT_COMMIT overrides detection" {
  mkgit; touch "$TMP/gr/packages/x"
  RELEASE=1 REPRO_GIT_COMMIT=abc123 run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  grep -q -- '--git-commit abc123 ' "$TMP/calls"
}

# stub docker whose `melange build` writes $TMP/repo/x86_64/foo-9.7.2-r0.apk with the given depends
stub_build_apk() {
  cat > "$TMP/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/calls"
case " \$* " in
  *" build "*)
    d=\$(mktemp -d); mkdir -p "$TMP/repo/x86_64"
    { echo 'pkgname = foo'; for x in $*; do echo "depend = \$x"; done; } > "\$d/.PKGINFO"
    tar -C "\$d" -czf "$TMP/repo/x86_64/foo-9.7.2-r0.apk" .PKGINFO ;;
esac
STUB
}

@test "no-cmd-deps: a listed package with a cmd: dependency fails the build before melange test" {
  ver=$(grep '^ps_version:' "$ROOT/versions/9.7.yaml" | tr -dc 0-9.)
  [ "$ver" = 9.7.2 ] || skip "fixture assumes ps_version 9.7.2"
  printf 'foo\n' > "$TMP/pkgs/foo/no-cmd-deps"
  stub_build_apk so:libc.so.6 cmd:sh
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CMD-DEP foo: cmd:sh"* ]]
  run grep -q -- ' test ' "$TMP/calls"; [ "$status" -ne 0 ]
  stub_build_apk so:libc.so.6
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: foo"* ]]
}

@test "no-cmd-deps: without the file no check runs" {
  stub_build_apk cmd:sh
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
}

@test "LEAK_SCAN=warn reaches the build via an env file and is excluded from the recorded config" {
  LEAK_SCAN=warn run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  grep -q -- '--exclude-env-from-recorded-config LEAK_SCAN' "$TMP/calls"
  f=$(grep -o -- '--env-file [^ ]*' "$TMP/calls" | head -n1 | cut -d' ' -f2)
  [ -n "$f" ]
  grep -qx 'LEAK_SCAN=warn' "$ROOT/$f" || grep -qx 'LEAK_SCAN=warn' "$f"
  : > "$TMP/calls"
  LEAK_SCAN=warn run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}" --no-cache
  [ "$status" -eq 0 ]
  grep -q -- '--env-file' "$TMP/calls"
  run grep -q -- '--cache-dir' "$TMP/calls"; [ "$status" -ne 0 ]
}

@test "git mirrors in the cache dir reach git in the build as insteadOf rules, excluded from the recorded config" {
  mkdir -p "$TMP/cache/git/github.com/percona/percona-server.git" "$TMP/cache/git/github.com/percona/rocksdb.git"
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  grep -q -- "--cache-dir $TMP/cache" "$TMP/calls"
  f=$(grep -o -- '--env-file [^ ]*' "$TMP/calls" | head -n1 | cut -d' ' -f2)
  [ -f "$ROOT/$f" ] && f=$ROOT/$f
  grep -qx 'GIT_CONFIG_COUNT=5' "$f"
  grep -qx 'GIT_CONFIG_KEY_0=protocol.file.allow' "$f"
  grep -qx 'GIT_CONFIG_VALUE_0=always' "$f"
  # both spellings of each upstream URL (with and without .git) map to the mirror mounted under /var/cache/melange
  m=file:///var/cache/melange/git/github.com/percona
  grep -qx "GIT_CONFIG_KEY_1=url.$m/percona-server.git.insteadOf" "$f"
  grep -qx 'GIT_CONFIG_VALUE_1=https://github.com/percona/percona-server' "$f"
  grep -qx 'GIT_CONFIG_VALUE_2=https://github.com/percona/percona-server.git' "$f"
  grep -qx "GIT_CONFIG_KEY_3=url.$m/rocksdb.git.insteadOf" "$f"
  grep -qx 'GIT_CONFIG_VALUE_4=https://github.com/percona/rocksdb.git' "$f"
  for v in GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_4; do
    grep -q -- "--exclude-env-from-recorded-config $v" "$TMP/calls"
  done
}

@test "git mirrors: a recipe URL that only shares a mirror's prefix gets an identity rule and stays on the network" {
  mkdir -p "$TMP/cache/git/github.com/percona/percona-server.git"
  printf 'package:\n  name: foo\n  version: @@ps_version@@\n# https://github.com/percona/percona-server-mysql-operator\n# https://github.com/percona/percona-server\n# https://example.invalid/other\n' \
    > "$TMP/pkgs/foo/melange.yaml.tmpl"
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  f=$(grep -o -- '--env-file [^ ]*' "$TMP/calls" | head -n1 | cut -d' ' -f2)
  [ -f "$ROOT/$f" ] && f=$ROOT/$f
  op=https://github.com/percona/percona-server-mysql-operator
  grep -qx "GIT_CONFIG_KEY_3=url.$op.insteadOf" "$f"
  grep -qx "GIT_CONFIG_VALUE_3=$op" "$f"
  grep -qx 'GIT_CONFIG_COUNT=4' "$f"
  # the mirrored URL itself and unrelated URLs get no identity rule
  run grep -c 'insteadOf$' "$f"
  [ "$output" -eq 3 ]
}

@test "git mirrors: GIT_MIRRORS=0 or --no-cache leave git on the network" {
  mkdir -p "$TMP/cache/git/github.com/percona/percona-server.git"
  GIT_MIRRORS=0 run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  run grep -q 'GIT_CONFIG' "$TMP/calls"; [ "$status" -ne 0 ]
  f=$(grep -o -- '--env-file [^ ]*' "$TMP/calls" | head -n1 | cut -d' ' -f2)
  [ -f "$ROOT/$f" ] && f=$ROOT/$f
  run grep -q 'GIT_CONFIG' "$f"; [ "$status" -ne 0 ]
  : > "$TMP/calls"
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}" --no-cache
  [ "$status" -eq 0 ]
  run grep -q -- '--env-file' "$TMP/calls"; [ "$status" -ne 0 ]
}

@test "LEAK_SCAN unset: no env file for --no-cache builds; a bad value is rejected" {
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}" --no-cache
  [ "$status" -eq 0 ]
  run grep -q -- '--env-file' "$TMP/calls"; [ "$status" -ne 0 ]
  LEAK_SCAN=off run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -ne 0 ]
  [[ "$output" == *LEAK_SCAN* ]]
}

@test "keys.sh passes COSIGN_PASSWORD by name, never its value on the docker command line" {
  rm -rf "$TMP/kd"
  cat > "$TMP/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/calls"
case "\$*" in
  *keygen*) touch "$TMP/kd/ps-wolfi-dev.rsa" "$TMP/kd/ps-wolfi-dev.rsa.pub" ;;
  *generate-key-pair*) echo "pw=\${COSIGN_PASSWORD-unset}" >> "$TMP/calls"; touch "$TMP/kd/cosign.key" "$TMP/kd/cosign.pub" ;;
esac
STUB
  COSIGN_PASSWORD=s3cret run env REPO_PUBKEY="$TMP/repo.pub" "$ROOT/scripts/keys.sh"
  [ "$status" -eq 0 ]
  grep -q -- '-e COSIGN_PASSWORD ' "$TMP/calls"
  run grep -q 's3cret' <(grep -v '^pw=' "$TMP/calls"); [ "$status" -ne 0 ]
  grep -qx 'pw=s3cret' "$TMP/calls"
}

@test "key names: release dir -> ps-wolfi and the committed pubkey, other dirs -> ps-wolfi-dev" {
  run env -u KEY_DIR -u APK_PUBKEY HOME="$TMP/h" bash -c ". '$ROOT/scripts/lib/keys.sh'; echo \$APK_KEY_NAME \$APK_PUBKEY"
  [ "$output" = "ps-wolfi keys/ps-wolfi.rsa.pub" ]
  run env -u APK_PUBKEY KEY_DIR=/x bash -c ". '$ROOT/scripts/lib/keys.sh'; echo \$APK_KEY_NAME \$APK_PUBKEY"
  [ "$output" = "ps-wolfi-dev /x/ps-wolfi-dev.rsa.pub" ]
}

@test "signs with the key named after APK_KEY_NAME" {
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  grep -q -- '--signing-key /keys/ps-wolfi-dev.rsa' "$TMP/calls"
}

@test "foreign APK_PUBKEY: only melange test also trusts the signer's own key" {
  echo HOSTKEY > "$TMP/ps-wolfi.rsa.pub"
  echo DEVKEY > "$TMP/kd/ps-wolfi-dev.rsa.pub"
  APK_PUBKEY="$TMP/ps-wolfi.rsa.pub" run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  grep ' test ' "$TMP/calls" | grep -q -- "--keyring-append $TMP/ps-wolfi.rsa.pub --keyring-append /keys/ps-wolfi-dev.rsa.pub"
  run bash -c "grep ' build ' '$TMP/calls' | grep -q /keys/ps-wolfi-dev.rsa.pub"
  [ "$status" -ne 0 ]   # the build (recorded config) sees only APK_PUBKEY
}

@test "own APK_PUBKEY: no extra keyring for melange test" {
  run "$ROOT/scripts/melange-build.sh" "${ARGS[@]}"
  [ "$status" -eq 0 ]
  run grep -q -- '--keyring-append /keys/' "$TMP/calls"
  [ "$status" -ne 0 ]
}
