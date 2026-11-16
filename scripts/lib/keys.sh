#!/usr/bin/env bash
# Key locations, meant to be sourced. Shared by keys.sh, melange-build.sh and apko builds.
# KEY_DIR holds $APK_KEY_NAME.rsa{,.pub} and cosign.key/.pub. The default is the release key dir;
# laptop smoke builds use a dev key dir outside the repo, KEY_DIR=$HOME/.config/ps-wolfi-dev (a dir inside the repo,
# such as out/dev-keys, still works but is visible to every tool container, which all mount the repo).
DEFAULT_KEY_DIR="$HOME/.config/ps-wolfi"
KEY_DIR=${KEY_DIR:-$DEFAULT_KEY_DIR}
# APK_KEY_NAME: base name of the apk signing key pair. apk tools pick the key that verifies a signature by file name
# (.SIGN.RSA256.<name>.rsa.pub must match a keyring file <name>.rsa.pub), so the private key, the public key and every
# keyring copy carry the same name. The release and the dev keys need different names: a laptop rebuild against the
# imported host repo trusts both at once.
if [[ -z ${APK_KEY_NAME:-} ]]; then
  if [[ $KEY_DIR == "$DEFAULT_KEY_DIR" ]]; then APK_KEY_NAME=ps-wolfi; else APK_KEY_NAME=ps-wolfi-dev; fi
fi
# APK_PUBKEY: public key handed to melange/apko via --keyring-append / -k.
# Release (default KEY_DIR): the committed copy. Otherwise the key from KEY_DIR.
if [[ -z ${APK_PUBKEY:-} ]]; then
  if [[ $KEY_DIR == "$DEFAULT_KEY_DIR" ]]; then
    APK_PUBKEY=keys/$APK_KEY_NAME.rsa.pub
  else
    APK_PUBKEY=$KEY_DIR/$APK_KEY_NAME.rsa.pub
  fi
fi
