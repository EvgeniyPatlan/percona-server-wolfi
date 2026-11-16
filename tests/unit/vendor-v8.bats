#!/usr/bin/env bats

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  T=$BATS_TEST_TMPDIR
  mkdir -p "$T/fx/v8/src" "$T/fx/v8/.git/objects" "$T/fx/v8/third_party/dep/.git"
  printf 'a\n' > "$T/fx/v8/src/a.cc"
  printf 'b\n' > "$T/fx/v8/BUILD.gn"
  printf 'ignore\n' > "$T/fx/v8/.gitignore"
  printf 'x\n' > "$T/fx/v8/.git/HEAD"
  printf 'y\n' > "$T/fx/v8/third_party/dep/.git/HEAD"
  printf 'gitlink: ..\n' > "$T/fx/v8/third_party/dep/lib.cc"
  # shellcheck source=../../scripts/vendor-v8.sh
  source "$ROOT/scripts/vendor-v8.sh"
}

@test "tarring twice yields identical sha256 even when mtimes differ" {
  make_tarball "$T/fx" v8 "$T/one.tgz" 1789902098
  touch -d '2031-01-01' "$T/fx/v8/src/a.cc"
  sleep 1
  make_tarball "$T/fx" v8 "$T/two.tgz" 1789902098
  [ "$(sha256sum < "$T/one.tgz")" = "$(sha256sum < "$T/two.tgz")" ]
}

@test "no .git entries, but .gitignore kept" {
  make_tarball "$T/fx" v8 "$T/o.tgz" 1789902098
  list=$(tar -tzf "$T/o.tgz")
  run grep -E '(^|/)\.git(/|$)' <<<"$list"
  [ "$status" -eq 1 ]
  grep -qx 'v8/.gitignore' <<<"$list"
  grep -qx 'v8/third_party/dep/lib.cc' <<<"$list"
}

@test "normalised owner and mtime" {
  make_tarball "$T/fx" v8 "$T/o.tgz" 1789902098
  run tar -tvzf "$T/o.tgz" --numeric-owner v8/BUILD.gn
  [[ "$output" == *"0/0"* ]]
  [[ "$output" == *"2026-09-20"* ]]
}

@test "gzip header has no flags, name or timestamp" {
  make_tarball "$T/fx" v8 "$T/o.tgz" 1789902098
  # bytes: 1f 8b 08 | FLG | MTIME(4)
  [ "$(head -c 8 "$T/o.tgz" | od -An -tx1 | tr -d ' \n')" = "1f8b080000000000" ]
}

@test "missing source dir fails" {
  run make_tarball "$T/fx" nope "$T/o.tgz" 1789902098
  [ "$status" -ne 0 ]
  [ ! -e "$T/o.tgz" ]
}

@test "check_recorded_sha: TODO or empty v8_src_sha256 stops with the paste/commit/re-run message" {
  sha=$(printf 'a%.0s' {1..64})
  for v in '"TODO-UNRESOLVED"' '""'; do
    printf 'v8_tag: "12.9"\nv8_src_sha256: %s\n' "$v" > "$T/v.yaml"
    run check_recorded_sha "$T/v.yaml" "$sha"
    [ "$status" -eq 1 ]
    [[ $output == *"paste v8_src_sha256: \"$sha\" into $T/v.yaml, commit, re-run"* ]]
  done
}

@test "check_recorded_sha: a matching value passes, a different one fails" {
  sha=$(printf 'a%.0s' {1..64})
  printf 'v8_src_sha256: "%s"\n' "$sha" > "$T/v.yaml"
  run check_recorded_sha "$T/v.yaml" "$sha"
  [ "$status" -eq 0 ]
  run check_recorded_sha "$T/v.yaml" "$(printf 'b%.0s' {1..64})"
  [ "$status" -eq 1 ]
  [[ $output == *"differs"* ]]
}

@test "--check: an existing tarball is hashed and checked without fetching" {
  mkdir -p "$T/src" "$T/bin"
  printf '#!/bin/sh\necho "$*" >> "%s/docker.calls"\n' "$T" > "$T/bin/docker"
  chmod +x "$T/bin/docker"
  printf 'x' > "$T/src/v8-12.9.tar.gz"
  sha=$(sha256sum "$T/src/v8-12.9.tar.gz" | cut -d' ' -f1)
  printf 'v8_tag: "12.9"\nsource_date_epoch: 1\nv8_src_sha256: "TODO-UNRESOLVED"\n' > "$T/v.yaml"
  DOCKER="$T/bin/docker" SOURCES_DIR="$T/src" run "$ROOT/scripts/vendor-v8.sh" --check "$T/v.yaml"
  [ "$status" -eq 1 ]
  [[ $output == *"v8_src_sha256: \"$sha\""* ]]
  [[ $output == *"commit, re-run"* ]]
  [ ! -e "$T/docker.calls" ]
  printf 'v8_tag: "12.9"\nsource_date_epoch: 1\nv8_src_sha256: "%s"\n' "$sha" > "$T/v.yaml"
  DOCKER="$T/bin/docker" SOURCES_DIR="$T/src" run "$ROOT/scripts/vendor-v8.sh" --check "$T/v.yaml"
  [ "$status" -eq 0 ]
  mv "$T/src/v8-12.9.tar.gz" "$T/moved.tar.gz"
  DOCKER="$T/bin/docker" SOURCES_DIR="$T/src" run "$ROOT/scripts/vendor-v8.sh" --check "$T/v.yaml"
  [ "$status" -eq 1 ]
  [ ! -e "$T/docker.calls" ]
}

@test "inner fetch bootstraps depot_tools before the first gclient/fetch call" {
  run bash -c ". '$ROOT/scripts/vendor-v8.sh'; inner_fetch"
  [ "$status" -eq 0 ]
  boot=$(grep -n '^ensure_bootstrap$' <<<"$output" | cut -d: -f1)
  first=$(grep -nE '^\[\[ -d v8 \]\] \|\| fetch ' <<<"$output" | cut -d: -f1)
  [ -n "$boot" ] && [ -n "$first" ] && [ "$boot" -lt "$first" ]
}
