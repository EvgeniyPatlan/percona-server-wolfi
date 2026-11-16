#!/usr/bin/env bats

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  T=$BATS_TEST_TMPDIR
  printf 'hello-source\n' > "$T/good.txt"
  SHA=$(sha256sum "$T/good.txt" | cut -d' ' -f1)
  # stub curl: counts calls; fails the first $FAIL_FIRST calls; writes $PAYLOAD
  # to the file given after -o.
  cat > "$T/curl" <<'STUB'
#!/usr/bin/env bash
n=$(cat "$STUB_DIR/count" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_DIR/count"
if (( n <= ${FAIL_FIRST:-0} )); then exit 22; fi
out=
while (($#)); do [[ $1 == -o ]] && out=$2; shift; done
cp "$STUB_DIR/${PAYLOAD:-good.txt}" "$out"
STUB
  chmod +x "$T/curl"
  export STUB_DIR=$T CURL="$T/curl" RETRY_SLEEP=0
  DEST=$T/out/file.tgz
}
calls() { cat "$T/count" 2>/dev/null || echo 0; }

@test "matching sha writes dest" {
  run "$ROOT/scripts/fetch-sources.sh" http://x/f "$SHA" "$DEST"
  [ "$status" -eq 0 ]
  cmp "$DEST" "$T/good.txt"
  [ ! -e "$DEST.part" ]
}
@test "mismatch fails, no dest, no part" {
  printf 'trunc' > "$T/bad.txt"
  PAYLOAD=bad.txt run "$ROOT/scripts/fetch-sources.sh" http://x/f "$SHA" "$DEST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256 mismatch"* ]]
  [ ! -e "$DEST" ]
  [ ! -e "$DEST.part" ]
}
@test "existing dest with correct sha skips download" {
  mkdir -p "$T/out"; cp "$T/good.txt" "$DEST"
  run "$ROOT/scripts/fetch-sources.sh" http://x/f "$SHA" "$DEST"
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
}
@test "existing dest with wrong sha is re-downloaded" {
  mkdir -p "$T/out"; echo stale > "$DEST"
  run "$ROOT/scripts/fetch-sources.sh" http://x/f "$SHA" "$DEST"
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  cmp "$DEST" "$T/good.txt"
}
@test "curl failing twice then succeeding passes" {
  FAIL_FIRST=2 run "$ROOT/scripts/fetch-sources.sh" http://x/f "$SHA" "$DEST"
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 3 ]
  cmp "$DEST" "$T/good.txt"
}
@test "usage error with missing args" {
  run "$ROOT/scripts/fetch-sources.sh" http://x/f
  [ "$status" -ne 0 ]
}

# --- pair discovery ---
mkfix() {
  cat > "$T/v.yaml" <<'Y'
name: x
a_url: "http://h/a-1.tar.gz"
a_sha256: "aaa"
b_src_url: "http://h/dl/b.tar.gz?x=1"
b_src_sha256: "TODO-UNRESOLVED"
c_url: "http://h/c.tar.gz"
d_sha256: "orphan"
e_url: 'http://h/e.tgz'   # comment
e_sha256: eee
Y
}
@test "list-source-pairs emits url sha dest for complete pairs" {
  mkfix
  run "$ROOT/scripts/list-source-pairs.sh" "$T/v.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'http://h/a-1.tar.gz aaa a-1.tar.gz'* ]]
  [[ "$output" == *$'http://h/e.tgz eee e.tgz'* ]]
  [[ "$output" == *$'http://h/dl/b.tar.gz?x=1 TODO-UNRESOLVED b.tar.gz'* ]]
  [[ "$output" != *c.tar.gz* ]]
  [[ "$output" != *orphan* ]]
}
@test "list-source-pairs on real versions file includes mecab" {
  run "$ROOT/scripts/list-source-pairs.sh" "$ROOT/versions/9.7.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *mecab_0.996.orig.tar.gz* ]]
}
@test "fetch-all skips TODO-UNRESOLVED with warning and fetches the rest" {
  mkfix
  sed -i 's/aaa/'"$SHA"'/; s/eee/'"$SHA"'/' "$T/v.yaml"
  run env SOURCES_DIR="$T/src" "$ROOT/scripts/fetch-all-sources.sh" "$T/v.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TODO-UNRESOLVED"* ]]
  [ -f "$T/src/a-1.tar.gz" ]; [ -f "$T/src/e.tgz" ]; [ ! -e "$T/src/b.tar.gz" ]
}
