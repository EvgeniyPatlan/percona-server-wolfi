#!/usr/bin/env bats
# scripts/check-no-cmd-deps.sh: packages listed in packages/<name>/no-cmd-deps must not carry melange's generated
# `cmd:<interpreter>` dependencies (they would pull a shell/perl into the distroless image).

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  T=$BATS_TEST_TMPDIR
  S="$ROOT/scripts/check-no-cmd-deps.sh"
  mkdir -p "$T/repo/x86_64"
  printf '# distroless\npkg-a\n\npkg-b  # trailing comment\n' > "$T/list"
}

# mkapk <name> <version> <depend...>: a minimal apk-like tarball (gzip) with a .PKGINFO
mkapk() {
  local name=$1 ver=$2 d
  shift 2
  d=$(mktemp -d "$T/apk.XXXXXX")
  { printf 'pkgname = %s\npkgver = %s\n' "$name" "$ver"; for dep in "$@"; do printf 'depend = %s\n' "$dep"; done; } \
    > "$d/.PKGINFO"
  mkdir -p "$d/usr/bin" && echo data > "$d/usr/bin/x"
  tar -C "$d" -czf "$T/repo/x86_64/$name-$ver.apk" .PKGINFO usr
}

@test "listed packages without cmd: deps pass" {
  mkapk pkg-a 1.0-r0 so:libc.so.6 percona-server-libs
  mkapk pkg-b 1.0-r0
  run "$S" "$T/repo" 1.0-r0 "$T/list"
  [ "$status" -eq 0 ]
  [[ $output == *"ok: pkg-a"* && $output == *"ok: pkg-b"* ]]
}

@test "a cmd: dependency fails and is named" {
  mkapk pkg-a 1.0-r0 so:libc.so.6 cmd:perl cmd:sh
  mkapk pkg-b 1.0-r0
  run "$S" "$T/repo" 1.0-r0 "$T/list"
  [ "$status" -eq 1 ]
  [[ $output == *"CMD-DEP pkg-a: cmd:perl"* ]]
  [[ $output == *"CMD-DEP pkg-a: cmd:sh"* ]]
  [[ $output != *"CMD-DEP pkg-b"* ]]
}

@test "a listed package that was not built fails" {
  mkapk pkg-a 1.0-r0
  run "$S" "$T/repo" 1.0-r0 "$T/list"
  [ "$status" -eq 1 ]
  [[ $output == *"pkg-b-1.0-r0.apk"* ]]
}

@test "other versions in the repo are ignored" {
  mkapk pkg-a 0.9-r0 cmd:bash
  mkapk pkg-a 1.0-r0
  mkapk pkg-b 1.0-r0
  run "$S" "$T/repo" 1.0-r0 "$T/list"
  [ "$status" -eq 0 ]
}

@test "bad usage and an empty list fail" {
  run "$S" "$T/repo" 1.0-r0
  [ "$status" -eq 2 ]
  printf '# nothing\n' > "$T/empty"
  run "$S" "$T/repo" 1.0-r0 "$T/empty"
  [ "$status" -eq 2 ]
}

@test "a real melange apk with cmd:bash (telemetry agent, if built locally) fails" {
  apk=$(find "$ROOT/out/repo/x86_64" -name "percona-telemetry-agent-*.apk" 2>/dev/null | head -n1 || true)
  [ -n "$apk" ] || skip "no locally built percona-telemetry-agent apk"
  f=${apk##*/}; ver=${f#percona-telemetry-agent-}; ver=${ver%.apk}
  echo percona-telemetry-agent > "$T/tl"
  run "$S" "$ROOT/out/repo" "$ver" "$T/tl"
  [ "$status" -eq 1 ]
  [[ $output == *"CMD-DEP percona-telemetry-agent: cmd:bash"* ]]
}
