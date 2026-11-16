#!/usr/bin/env bats

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  T=$BATS_TEST_TMPDIR
  S="$ROOT/scripts/check-build-path-leaks.sh"
  mkdir -p "$T/d/usr/bin" "$T/d/usr/share"
  printf 'clean\n' > "$T/d/usr/share/ok.txt"
}

@test "clean tree passes" {
  run "$S" "$T/d" /home/build
  [ "$status" -eq 0 ]
  [[ "$output" == *"no build-path leaks"* ]]
}

@test "text and binary leaks fail and are named" {
  printf 'prefix=/home/build/ps-build\n' > "$T/d/usr/share/leak.pc"
  printf '\x7fELF\x00\x01/home/build/x.c\x00' > "$T/d/usr/bin/tool"
  run "$S" "$T/d" /home/build
  [ "$status" -eq 1 ]
  [[ "$output" == *"BUILD-PATH LEAK: usr/share/leak.pc"* ]]
  [[ "$output" == *"BUILD-PATH LEAK: usr/bin/tool"* ]]
  [[ "$output" != *ok.txt* ]]
}

@test "path is matched literally, not as a regex" {
  printf '/home/buildX\n/homeXbuild\n' > "$T/d/usr/share/near.txt"
  run "$S" "$T/d" /home/build.
  [ "$status" -eq 0 ]
}

@test "allowlist regexes excuse matching files only" {
  printf '/home/build\n' > "$T/d/usr/share/a.txt"
  printf '/home/build\n' > "$T/d/usr/share/b.txt"
  printf '# comment\n\n^usr/share/a\\.txt$\n' > "$T/allow"
  run "$S" "$T/d" /home/build "$T/allow"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ALLOWED build-path reference: usr/share/a.txt"* ]]
  [[ "$output" == *"BUILD-PATH LEAK: usr/share/b.txt"* ]]
  printf '^usr/share/b\\.txt$\n' >> "$T/allow"
  run "$S" "$T/d" /home/build "$T/allow"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(2 allow-listed)"* ]]
}

@test "symlinks are not followed" {
  printf '/home/build\n' > "$T/outside"
  ln -s "$T/outside" "$T/d/usr/share/link"
  run "$S" "$T/d" /home/build
  [ "$status" -eq 0 ]
}

@test "bad arguments fail with status 2" {
  run "$S" "$T/d"
  [ "$status" -eq 2 ]
  run "$S" "$T/missing" /home/build
  [ "$status" -eq 2 ]
  run "$S" "$T/d" relative/path
  [ "$status" -eq 2 ]
  run "$S" "$T/d" /
  [ "$status" -eq 2 ]
  run "$S" "$T/d" /home/build "$T/no-such-allowlist"
  [ "$status" -eq 2 ]
}

@test "LEAK_SCAN=warn reports leaks but exits 0; LEAK_SCAN=fatal (default) fails; other values are rejected" {
  printf 'prefix=/home/build/ps-build\n' > "$T/d/usr/share/leak.pc"
  LEAK_SCAN=warn run "$S" "$T/d" /home/build
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUILD-PATH LEAK: usr/share/leak.pc"* ]]
  [[ "$output" == *"LEAK_SCAN=warn"* ]]
  LEAK_SCAN=fatal run "$S" "$T/d" /home/build
  [ "$status" -eq 1 ]
  LEAK_SCAN=bogus run "$S" "$T/d" /home/build
  [ "$status" -eq 2 ]
}

@test "LEAK_IGNORE: a file with only ignored strings is IGNORED, a real leak next to them still fails" {
  printf '\x7fELF\x00/home/build/csu\x00x\x00/home/build/csu/start.S\x00' > "$T/d/usr/bin/onlycsu"
  LEAK_IGNORE=/home/build/csu run "$S" "$T/d" /home/build
  [ "$status" -eq 0 ]
  [[ "$output" == *"IGNORED build-path reference (LEAK_IGNORE only): usr/bin/onlycsu"* ]]
  printf '\x7fELF\x00/home/build/csu\x00/home/build/ps-build/a.c\x00' > "$T/d/usr/bin/mixed"
  LEAK_IGNORE=/home/build/csu run "$S" "$T/d" /home/build
  [ "$status" -eq 1 ]
  [[ "$output" == *"BUILD-PATH LEAK: usr/bin/mixed"* ]]
  [[ "$output" != *"LEAK: usr/bin/onlycsu"* ]]
}

@test "LEAK_IGNORE: strings are literal (regex/sed metacharacters), entries outside the build path are rejected" {
  printf 'x /home/build/a.b#c&d y\n' > "$T/d/usr/share/meta.txt"
  LEAK_IGNORE='/home/build/a.b#c&d' run "$S" "$T/d" /home/build
  [ "$status" -eq 0 ]
  printf 'x /home/build/aXb#c&d y\n' > "$T/d/usr/share/meta.txt"   # "." must not match X
  LEAK_IGNORE='/home/build/a.b#c&d' run "$S" "$T/d" /home/build
  [ "$status" -eq 1 ]
  LEAK_IGNORE=/usr/lib/csu run "$S" "$T/d" /home/build
  [ "$status" -eq 2 ]
}
