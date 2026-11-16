#!/usr/bin/env bash
# keys.sh: generate the apk signing key (melange) and cosign key pair, in containers.
# Refuses to overwrite. COSIGN_PASSWORD comes from the environment (empty allowed for dev).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
# shellcheck source=lib/keys.sh
. "$here/lib/keys.sh"
cd "$here/.."

REPO_PUBKEY=${REPO_PUBKEY:-keys/$APK_KEY_NAME.rsa.pub}

for f in "$APK_KEY_NAME.rsa" "$APK_KEY_NAME.rsa.pub" cosign.key cosign.pub; do
  [[ ! -e $KEY_DIR/$f ]] || die "refusing to overwrite existing $KEY_DIR/$f"
done

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"
KEY_DIR=$(cd "$KEY_DIR" && pwd)
if [[ $KEY_DIR == "$PWD" || $KEY_DIR == "$PWD"/* ]]; then
  log_warn "KEY_DIR $KEY_DIR is inside the repo: every tool container mounts the repo (/work), so the private keys" \
    "are visible to all of them; prefer a dev key dir outside it, e.g. KEY_DIR=\$HOME/.config/ps-wolfi-dev"
fi
run_as=(--user "$(id -u):$(id -g)" -v "$KEY_DIR:/keys" -e HOME=/tmp)

log_info "generating melange signing key in $KEY_DIR"
tool melange "${run_as[@]}" -- keygen "/keys/$APK_KEY_NAME.rsa"
log_info "generating cosign key pair in $KEY_DIR"
# by name (like sign.sh): the value never appears on the docker command line (ps, shell history, logs)
export COSIGN_PASSWORD=${COSIGN_PASSWORD-}
tool cosign "${run_as[@]}" -w /keys -e COSIGN_PASSWORD -- generate-key-pair

for f in "$APK_KEY_NAME.rsa" "$APK_KEY_NAME.rsa.pub" cosign.key cosign.pub; do
  [[ -e $KEY_DIR/$f ]] || die "key generation did not produce $KEY_DIR/$f"
done
chmod 600 "$KEY_DIR/$APK_KEY_NAME.rsa" "$KEY_DIR/cosign.key"

if [[ $KEY_DIR == "$(cd "$DEFAULT_KEY_DIR" 2>/dev/null && pwd || echo "$DEFAULT_KEY_DIR")" ]]; then
  mkdir -p "$(dirname "$REPO_PUBKEY")"
  cp "$KEY_DIR/$APK_KEY_NAME.rsa.pub" "$REPO_PUBKEY"
  log_info "copied public key to $REPO_PUBKEY - commit it"
  cp "$KEY_DIR/cosign.pub" "$(dirname "$REPO_PUBKEY")/cosign.pub"
  log_info "copied cosign public key to $(dirname "$REPO_PUBKEY")/cosign.pub - commit it"
else
  log_info "non-default KEY_DIR: public key stays at $KEY_DIR/$APK_KEY_NAME.rsa.pub (not copied to the repo)"
fi
