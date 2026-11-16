#!/usr/bin/env bats
# scripts/repro-images.sh: a second, independent image build (fresh apko cache, separate output dirs, separate
# registry namespace) from the same committed lock files, compared by index digest with the first build.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  T=$BATS_TEST_TMPDIR
  S="$ROOT/scripts/repro-images.sh"
  mkdir -p "$T/img" "$T/results" "$T/bin"
  D1=sha256:$(printf 'a%.0s' {1..64}) D2=sha256:$(printf 'b%.0s' {1..64})
  for n in one two; do
    echo "{\"lock\":\"$n\"}" > "$T/img/$n.lock.json"
    echo "$D1" > "$T/results/$n.digest"
  done
  # stub apko-build.sh: records its env and args, writes $RESULTS_DIR/<name>.digest (STUB_DIGEST_<name> or D1)
  cat > "$T/bin/apko-build" <<STUB
#!/usr/bin/env bash
echo "\$* REGISTRY=\$REGISTRY RESULTS_DIR=\$RESULTS_DIR OUT_IMAGES=\$OUT_IMAGES APKO_CACHE=\$APKO_CACHE RELOCK=\${RELOCK:-}" >> "$T/calls"
[[ -z \${STUB_TOUCH_LOCK:-} ]] || echo changed >> "$T/img/\$1.lock.json"
mkdir -p "\$RESULTS_DIR"
v=STUB_DIGEST_\$1
echo "\${!v:-$D1}" > "\$RESULTS_DIR/\$1.digest"
STUB
  chmod +x "$T/bin/apko-build"
  export APKO_BUILD="$T/bin/apko-build" IMAGES_DIR="$T/img" RESULTS_DIR="$T/results" REGISTRY=localhost:5000
  export REPRO_DIR="$T/repro"
}

@test "rebuilds each image into a separate namespace, dirs and a fresh cache, then compares digests" {
  mkdir -p "$T/repro/apko-cache" && touch "$T/repro/apko-cache/stale"
  run "$S" one two
  [ "$status" -eq 0 ]
  [[ $output == *"OK"* ]]
  grep -q "^one REGISTRY=localhost:5000/repro RESULTS_DIR=$T/repro/results OUT_IMAGES=$T/repro/images APKO_CACHE=$T/repro/apko-cache RELOCK=\$" "$T/calls"
  grep -q '^two ' "$T/calls"
  [ ! -e "$T/repro/apko-cache/stale" ]
  # the first build's digests are untouched
  [ "$(cat "$T/results/one.digest")" = "$D1" ]
}

@test "RELOCK from the caller never reaches the second build" {
  RELOCK=1 run "$S" one
  [ "$status" -eq 0 ]
  grep -q 'RELOCK=$' "$T/calls"
}

@test "a different digest fails; all images are still compared" {
  STUB_DIGEST_one=$D2 run "$S" one two
  [ "$status" -eq 1 ]
  grep -q '^two ' "$T/calls"
}

@test "missing first-build digest or lock file fails before building" {
  mv "$T/results/two.digest" "$T/two.digest.moved"
  run "$S" one two
  [ "$status" -eq 1 ]
  [[ $output == *"make images first"* ]]
  [ ! -e "$T/calls" ]
  mv "$T/two.digest.moved" "$T/results/two.digest"
  mv "$T/img/one.lock.json" "$T/one.lock.moved"
  run "$S" one two
  [ "$status" -eq 1 ]
  [[ $output == *"lock"* ]]
  [ ! -e "$T/calls" ]
}

@test "a lock file changed by the second build fails (not the same locked apks)" {
  STUB_TOUCH_LOCK=1 run "$S" one
  [ "$status" -eq 1 ]
  [[ $output == *"lock file changed"* ]]
}

@test "usage" {
  run "$S"
  [ "$status" -ne 0 ]
}
