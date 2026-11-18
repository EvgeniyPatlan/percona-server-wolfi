#!/usr/bin/env bash
# install-keys.sh <install|clean> <release|ci>: put the signing keys from Jenkins credentials where the build expects
# them, and remove them again.
#
# install: APK_KEY_FILE (the apk RSA private key) and COSIGN_KEY_FILE (cosign.key) are the paths of the Jenkins
#   secret-file credentials; COSIGN_PASSWORD comes from the environment (secret text). The keys are copied to the key
#   dir (mode 0700/0600) and their public halves are derived from them:
#   release: KEY_DIR=$HOME/.config/ps-wolfi (the default, so keys.sh names the apk key ps-wolfi and sign.sh compares
#            cosign.pub with the committed keys/cosign.pub); the derived public keys must equal the committed
#            keys/ps-wolfi.rsa.pub and keys/cosign.pub, or nothing is built.
#   ci:      KEY_DIR=$HOME/.config/ps-wolfi-ci (apk key name ps-wolfi-dev, like every non-release key dir); the
#            public keys are written next to the private ones, nothing is compared with keys/.
#   The key dir must be outside the repo (every tool container mounts the repo) and must not exist yet, so keys
#   made by `make keys` on a long-lived host are never overwritten.
# clean: removes the key dir, only if install created it (marker file). Never fails.
# Keys and the password are never printed.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here/../.."
# shellcheck source=../../scripts/lib/common.sh
. scripts/lib/common.sh

(($# == 2)) || die "usage: install-keys.sh <install|clean> <release|ci>"
action=$1 mode=$2
case $mode in
  release) default_dir=$HOME/.config/ps-wolfi apk_name=ps-wolfi ;;
  ci) default_dir=$HOME/.config/ps-wolfi-ci apk_name=ps-wolfi-dev ;;
  *) die "unknown key set: $mode (release|ci)" ;;
esac
key_dir=${KEY_DIR:-$default_dir}
[[ $mode != release || $key_dir == "$HOME/.config/ps-wolfi" ]] ||
  die "release keys go to the default key dir $HOME/.config/ps-wolfi (KEY_DIR=$key_dir)"
marker=.installed-by-jenkins

if [[ $action == clean ]]; then
  if [[ -f $key_dir/$marker ]]; then
    rm -rf "${key_dir:?}"
    log_info "removed $key_dir"
  elif [[ -e $key_dir ]]; then
    log_warn "$key_dir was not created by install-keys.sh: left alone"
  fi
  exit 0
fi
[[ $action == install ]] || die "unknown action: $action (install|clean)"

for v in APK_KEY_FILE COSIGN_KEY_FILE; do
  [[ -n ${!v:-} ]] || die "$v is not set (path of the Jenkins secret-file credential)"
  [[ -r ${!v} ]] || die "$v: cannot read ${!v}"
done
grep -q 'PRIVATE KEY' "$APK_KEY_FILE" || die "APK_KEY_FILE is not a PEM private key"
grep -q 'SIGSTORE PRIVATE KEY' "$COSIGN_KEY_FILE" || die "COSIGN_KEY_FILE is not a cosign private key"
if [[ $mode == release ]]; then
  for f in "keys/$apk_name.rsa.pub" keys/cosign.pub; do
    [[ -s $f ]] || die "no committed $f: generate the release keys once (make keys) and commit the public halves"
  done
fi

[[ ! -e $key_dir ]] || die "$key_dir already exists: refusing to overwrite (install-keys.sh clean $mode removes a dir it made)"
case $key_dir/ in "$PWD"/*) die "key dir $key_dir is inside the repo: every tool container would see the keys" ;; esac

(umask 077 && mkdir -p "$key_dir")
: > "$key_dir/$marker"
install -m 0600 "$APK_KEY_FILE" "$key_dir/$apk_name.rsa"
install -m 0600 "$COSIGN_KEY_FILE" "$key_dir/cosign.key"
key_dir=$(cd "$key_dir" && pwd)

export COSIGN_PASSWORD=${COSIGN_PASSWORD-}
# Public halves, derived in the pinned containers (openssl from wolfi_sdk, cosign for its encrypted key).
tool wolfi_sdk --entrypoint openssl -v "$key_dir:/k:ro" -- pkey -in "/k/$apk_name.rsa" -pubout > "$key_dir/$apk_name.rsa.pub" ||
  die "cannot derive the public key of APK_KEY_FILE"
tool cosign --user "$(id -u):$(id -g)" -e HOME=/tmp -e COSIGN_PASSWORD -v "$key_dir/cosign.key:/k/cosign.key:ro" -- \
  public-key --key /k/cosign.key > "$key_dir/cosign.pub" 2> /dev/null ||
  die "cannot read COSIGN_KEY_FILE (wrong COSIGN_PASSWORD?)"
chmod 0644 "$key_dir/$apk_name.rsa.pub" "$key_dir/cosign.pub"

if [[ $mode == release ]]; then
  # PEM text of the same key can differ (line breaks), so compare the DER form.
  # shellcheck disable=SC2016 # expanded by the container shell
  fp() { tool wolfi_sdk --entrypoint sh -v "$(dirname "$1"):/k:ro" -- -c \
    'openssl pkey -pubin -in "/k/$1" -outform DER | sha256sum | cut -d" " -f1' sh "$(basename "$1")"; }
  for f in "$apk_name.rsa.pub" cosign.pub; do
    [[ $(fp "$key_dir/$f") == "$(fp "$PWD/keys/$f")" ]] ||
      die "the key in the Jenkins credential does not match the committed keys/$f"
  done
fi
log_info "installed the $mode keys in $key_dir (apk key $apk_name)"
