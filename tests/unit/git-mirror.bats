#!/usr/bin/env bats
# scripts/git-mirror.sh: local bare mirrors for the builds. No network: "https://example.invalid/<name>" is redirected
# to local upstream repositories with git's own url.<base>.insteadOf (GIT_CONFIG_* environment).

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  T=$BATS_TEST_TMPDIR
  S="$ROOT/scripts/git-mirror.sh"
  export MIRROR_DIR="$T/mirrors" RETRY_SLEEP=0
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
  export GIT_CONFIG_KEY_1="url.file://$T/up/.insteadOf" GIT_CONFIG_VALUE_1=https://example.invalid/
  mkdir -p "$T/up"
  # upstream "sub" (two commits; the superproject pins the first) and "top" (submodule sub at that commit, tag v1)
  git init -q "$T/up/sub.git.work"
  git -C "$T/up/sub.git.work" commit -q --allow-empty -m one
  SUB1=$(git -C "$T/up/sub.git.work" rev-parse HEAD)
  git -C "$T/up/sub.git.work" commit -q --allow-empty -m two
  git clone -q --bare "$T/up/sub.git.work" "$T/up/sub.git"
  git --git-dir="$T/up/sub.git" config uploadpack.allowAnySHA1InWant true
  git init -q "$T/top-work"
  printf '[submodule "sub"]\n\tpath = sub\n\turl = https://example.invalid/sub.git\n' > "$T/top-work/.gitmodules"
  git -C "$T/top-work" add .gitmodules
  git -C "$T/top-work" update-index --add --cacheinfo "160000,$SUB1,sub"
  git -C "$T/top-work" commit -q -m top
  git -C "$T/top-work" tag -a -m v1 v1
  TOP=$(git -C "$T/top-work" rev-parse HEAD)
  git clone -q --bare "$T/top-work" "$T/up/top"
}

@test "mirror from the network: tag peeled to the commit, submodule pinned on its own branch (HEAD)" {
  run "$S" https://example.invalid/top v1 "$TOP"
  echo "$output"
  [ "$status" -eq 0 ]
  m=$T/mirrors/example.invalid
  [ "$(git --git-dir="$m/top.git" rev-parse 'v1^{commit}')" = "$TOP" ]
  git --git-dir="$m/sub.git" cat-file -e "$SUB1^{commit}"
  [ "$(git --git-dir="$m/sub.git" symbolic-ref HEAD)" = "refs/heads/pinned-$SUB1" ]
  [ "$(git --git-dir="$m/sub.git" rev-parse HEAD)" = "$SUB1" ]
  # only the pinned commit was fetched (depth 1), not the newer one
  [ "$(git --git-dir="$m/sub.git" rev-list --all | wc -l)" -eq 1 ]
}

@test "a second run needs no network; a clone through the mirror gets the pinned tree" {
  "$S" https://example.invalid/top v1 "$TOP"
  rm -rf "$T/up"
  run "$S" https://example.invalid/top v1 "$TOP"
  [ "$status" -eq 0 ]
  [[ $output != *"fetching"* ]]
  # the way melange's git-checkout clones (url rewritten to the mirror)
  export GIT_CONFIG_KEY_1="url.file://$T/mirrors/example.invalid/.insteadOf"
  git clone -q --branch v1 --recurse-submodules --single-branch https://example.invalid/top "$T/co"
  [ "$(git -C "$T/co" rev-parse HEAD)" = "$TOP" ]
  [ "$(git -C "$T/co/sub" rev-parse HEAD)" = "$SUB1" ]
}

@test "--seed: the superproject comes from a local clone; only the submodule is fetched" {
  git clone -q "$T/up/top" "$T/seed"
  rm -rf "$T/up/top"
  run "$S" https://example.invalid/top v1 "$TOP" --seed "$T/seed"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"seeding"* ]]
  [[ $output != *"fetching tag"* ]]
  [ "$(git --git-dir="$T/mirrors/example.invalid/top.git" config remote.origin.url)" = https://example.invalid/top ]
}

@test "a tag that does not point at the commit, or a commit the upstream lacks, fails" {
  run "$S" https://example.invalid/top v1 0123456789abcdef0123456789abcdef01234567
  [ "$status" -ne 0 ]
  [[ $output == *"tag v1 is $TOP, expected 0123456789abcdef0123456789abcdef01234567"* ]]
  run "$S" https://example.invalid/top nope "$TOP"
  [ "$status" -ne 0 ]
}

@test "bad arguments are rejected" {
  run "$S" http://example.invalid/top v1 "$TOP"
  [ "$status" -ne 0 ]
  run "$S" https://example.invalid/top v1 abc
  [ "$status" -ne 0 ]
  run "$S" https://example.invalid/top v1 "$TOP" --seed
  [ "$status" -ne 0 ]
  run "$S" https://example.invalid/top v1 "$TOP" --seed "$T/does-not-exist"
  [ "$status" -ne 0 ]
}
