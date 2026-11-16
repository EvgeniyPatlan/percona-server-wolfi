#!/usr/bin/env bash
# Helpers for tests/image/xtrabackup.bats. Sourced with `load xb-lib` after `load helpers`.
# Pure functions (no docker), unit-tested in tests/unit/xb-lib.bats; xb_restore_state_matches needs
# tests/fixtures/upgrade-lib.bash (expect_compare).

# rand_secret [n=24]: n random hex characters (credentials are generated at test time, never committed).
rand_secret() {
  local n=${1:-24} s
  s=$(head -c "$n" /dev/urandom | od -An -tx1 | tr -d ' \n')
  printf '%s\n' "${s:0:n}"
}

# xbcloud_s3_args <endpoint> <bucket> <access-key> <secret-key>: xbcloud options (one per line) for an S3 compatible
# endpoint with path-style bucket lookup (MinIO).
xbcloud_s3_args() {
  printf '%s\n' \
    --storage=s3 \
    "--s3-endpoint=$1" \
    "--s3-bucket=$2" \
    "--s3-access-key=$3" \
    "--s3-secret-key=$4" \
    --s3-region=us-east-1 \
    --s3-bucket-lookup=PATH \
    --parallel=2
}

# xb_completed_ok <xtrabackup output on stdin>: true when xtrabackup reported "completed OK!".
xb_completed_ok() { grep -Eq 'completed OK!$'; }

# xb_restore_state_matches <expect-file> <actual-file>: every expected key except server.version matches
# (needs upgrade-lib.bash for expect_compare).
xb_restore_state_matches() {
  local expected
  expected=$(mktemp)
  grep -v '^server.version=' "$1" > "$expected"
  expect_compare "$expected" "$2"
  local rc=$?
  rm -f "$expected"
  return "$rc"
}
