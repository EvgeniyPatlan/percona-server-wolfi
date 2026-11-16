#!/usr/bin/env bats

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  A=$BATS_TEST_TMPDIR/a/x86_64 B=$BATS_TEST_TMPDIR/b/x86_64
  mkdir -p "$A" "$B"
  for d in "$A" "$B"; do
    printf 'one' > "$d/foo-1-r0.apk"
    printf 'two' > "$d/bar-1-r0.apk"
    printf 'idx-%s' "$d" > "$d/APKINDEX.tar.gz"   # always differs; must be ignored
  done
  export RESULTS_DIR=$BATS_TEST_TMPDIR/results
  export DOCKER=echo
}

@test "apks: identical dirs -> all OK, no diffoscope" {
  run "$ROOT/scripts/verify-repro.sh" apks "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK foo-1-r0"* && "$output" == *"OK bar-1-r0"* ]]
  [[ "$output" != *"diffoscope"* ]]
  [[ "$output" != *APKINDEX* ]]
}

@test "apks: changed byte -> DIFF, diffoscope only for that pair" {
  printf 'twX' > "$B/bar-1-r0.apk"
  run "$ROOT/scripts/verify-repro.sh" apks "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DIFF bar-1-r0"* && "$output" == *"OK foo-1-r0"* ]]
  [[ "$output" == *"diffoscope"* && "$output" == *"diffoscope-bar-1-r0.html"* ]]
  [[ "$output" != *"foo-1-r0.apk"* ]]
}

@test "apks: extra file in B -> ONLY-IN-B, exit 1" {
  printf 'x' > "$B/extra-1-r0.apk"
  run "$ROOT/scripts/verify-repro.sh" apks "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ONLY-IN-B extra-1-r0"* ]]
}

@test "apks: extra file in A -> ONLY-IN-A, exit 1" {
  printf 'x' > "$A/extra-1-r0.apk"
  run "$ROOT/scripts/verify-repro.sh" apks "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ONLY-IN-A extra-1-r0"* ]]
}

@test "apks: missing dir or no apks -> error" {
  run "$ROOT/scripts/verify-repro.sh" apks "$BATS_TEST_TMPDIR/nope" "$BATS_TEST_TMPDIR/b"
  [ "$status" -ne 0 ]
  mkdir "$BATS_TEST_TMPDIR/empty"
  run "$ROOT/scripts/verify-repro.sh" apks "$BATS_TEST_TMPDIR/empty" "$BATS_TEST_TMPDIR/empty"
  [ "$status" -ne 0 ]
}

D1=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
D2=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

@test "images: equal digest strings -> 0" {
  run "$ROOT/scripts/verify-repro.sh" images "$D1" "$D1"
  [ "$status" -eq 0 ]; [[ "$output" == *"OK"* ]]
}

@test "images: different digests -> 1" {
  run "$ROOT/scripts/verify-repro.sh" images "$D1" "$D2"
  [ "$status" -eq 1 ]; [[ "$output" == *"DIFF"* ]]
}

@test "images: digest files are read" {
  printf '%s\n' "$D1" > "$BATS_TEST_TMPDIR/x.digest"
  printf '%s\n' "$D1" > "$BATS_TEST_TMPDIR/y.digest"
  run "$ROOT/scripts/verify-repro.sh" images "$BATS_TEST_TMPDIR/x.digest" "$BATS_TEST_TMPDIR/y.digest"
  [ "$status" -eq 0 ]
}

@test "images: refs resolved via docker buildx imagetools" {
  printf '#!/bin/sh\necho "$*" >> "%s/calls"\ncase "$*" in *refA*) echo %s;; *) echo %s;; esac\n' "$BATS_TEST_TMPDIR" "$D1" "$D2" > "$BATS_TEST_TMPDIR/fakedocker"
  chmod +x "$BATS_TEST_TMPDIR/fakedocker"
  DOCKER="$BATS_TEST_TMPDIR/fakedocker" run "$ROOT/scripts/verify-repro.sh" images reg/refA:1 reg/refB:1
  [ "$status" -eq 1 ]
  grep -q 'buildx imagetools inspect' "$BATS_TEST_TMPDIR/calls"
}

@test "usage error" {
  run "$ROOT/scripts/verify-repro.sh"
  [ "$status" -ne 0 ]
}

@test "apks: --subset-of-b ignores names only in A but still flags ONLY-IN-B" {
  printf 'x' > "$A/other-1-r0.apk"
  run "$ROOT/scripts/verify-repro.sh" apks --subset-of-b "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  [ "$status" -eq 0 ]
  [[ "$output" != *other-1-r0* ]]
  printf 'x' > "$B/new-1-r0.apk"
  run "$ROOT/scripts/verify-repro.sh" apks --subset-of-b "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  [ "$status" -eq 1 ]; [[ "$output" == *"ONLY-IN-B new-1-r0"* ]]
}

@test "apks: same name in <dir> and <dir>/<arch> -> error" {
  printf 'dup' > "$BATS_TEST_TMPDIR/a/foo-1-r0.apk"
  run "$ROOT/scripts/verify-repro.sh" apks "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  [ "$status" -ne 0 ]; [[ "$output" == *"duplicate apk foo-1-r0"* ]]
}

# mkapk <out> <keyname> <sigbytes> <data>: apk-shaped file: gzip(tar .SIGN.RSA256.<keyname>) + gzip(control) + gzip(data)
mkapk() {
  python3 -I - "$@" <<'PY'
import gzip, io, sys, tarfile
out, key, sig, data = sys.argv[1:5]
def member(name, payload, eof):
    b = io.BytesIO()
    with tarfile.open(fileobj=b, mode="w", format=tarfile.USTAR_FORMAT) as t:
        ti = tarfile.TarInfo(name); ti.size = len(payload.encode()); ti.mtime = 0
        t.addfile(ti, io.BytesIO(payload.encode()))
    raw = b.getvalue()
    if not eof:
        raw = raw[:512 + -(-ti.size // 512) * 512]  # apk control/signature tars have no end-of-archive blocks
    return gzip.compress(raw, mtime=0)
with open(out, "wb") as f:
    f.write(member(".SIGN.RSA256." + key + ".rsa.pub", sig, False))
    f.write(member(".PKGINFO", "pkgname = foo\n", False))
    f.write(member("usr/bin/foo", data, True))
PY
}

@test "apks: same content signed with different keys -> OK" {
  mkapk "$A/foo-1-r0.apk" ps-wolfi "signature-by-host-key-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" payload
  mkapk "$B/foo-1-r0.apk" ps-wolfi-dev "laptop-sig" payload
  run "$ROOT/scripts/verify-repro.sh" apks "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  [ "$status" -eq 0 ]; [[ "$output" == *"OK foo-1-r0"* ]]
}

@test "apks: different content under different signatures -> DIFF" {
  mkapk "$A/foo-1-r0.apk" ps-wolfi sigA payload
  mkapk "$B/foo-1-r0.apk" ps-wolfi-dev sigB payloaX
  run "$ROOT/scripts/verify-repro.sh" apks "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  [ "$status" -eq 1 ]; [[ "$output" == *"DIFF foo-1-r0"* ]]
}

@test "apk-content-hash: unsigned or non-gzip files are hashed whole" {
  printf 'plain' > "$BATS_TEST_TMPDIR/p"
  run python3 -I "$ROOT/scripts/lib/apk-content-hash.py" "$BATS_TEST_TMPDIR/p"
  [ "$status" -eq 0 ]
  [ "${output%%$'\t'*}" = "$(sha256sum "$BATS_TEST_TMPDIR/p" | cut -d' ' -f1)" ]
  printf 'x' | gzip -n > "$BATS_TEST_TMPDIR/g"   # gzip, but the first member is no signature
  run python3 -I "$ROOT/scripts/lib/apk-content-hash.py" "$BATS_TEST_TMPDIR/g"
  [ "${output%%$'\t'*}" = "$(sha256sum "$BATS_TEST_TMPDIR/g" | cut -d' ' -f1)" ]
}

@test "apks: APK_HASH_CONTAINER=1 hashes in the pinned python container, files mounted read-only" {
  printf '#!/bin/sh\necho "$*" >> "%s/calls"\nprintf "h\\tx\\nh\\tx\\nh\\tx\\nh\\tx\\n"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/fakedocker"
  chmod +x "$BATS_TEST_TMPDIR/fakedocker"
  APK_HASH_CONTAINER=1 DOCKER="$BATS_TEST_TMPDIR/fakedocker" run "$ROOT/scripts/verify-repro.sh" apks "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  [ "$status" -eq 0 ]
  grep -q "python@sha256:.* python3 -I /work/scripts/lib/apk-content-hash.py /cmp/0.apk /cmp/1.apk /cmp/2.apk /cmp/3.apk" "$BATS_TEST_TMPDIR/calls"
  grep -q -- "-v $A/bar-1-r0.apk:/cmp/0.apk:ro" "$BATS_TEST_TMPDIR/calls"
}

@test "apks: hash helper failure is an error, not a silent DIFF/OK" {
  printf '#!/bin/sh\nexit 3\n' > "$BATS_TEST_TMPDIR/fakedocker"; chmod +x "$BATS_TEST_TMPDIR/fakedocker"
  APK_HASH_CONTAINER=1 DOCKER="$BATS_TEST_TMPDIR/fakedocker" run "$ROOT/scripts/verify-repro.sh" apks "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b"
  [ "$status" -ne 0 ]; [[ "$output" == *"hashing apks failed"* ]]
}
