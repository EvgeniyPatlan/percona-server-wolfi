#!/usr/bin/env bash
# sign.sh <sign|verify> <percona-server|percona-server-dev|percona-xtrabackup|percona-mysql-router|percona-haproxy|percona-fluentbit|percona-orchestrator|percona-server-mysql-operator|percona-xtradb-cluster-operator|percona-proxysql3|percona-xtradb-cluster|percona-xtradb-cluster-backup|percona-binlog-server|percona-toolkit|pmm-client>
# sign:   cosign sign + cosign attest --type spdxjson (the apko SBOM) of the published index digest
#         (out/results/<name>.digest, $REGISTRY/<repo>@<digest>), key $KEY_DIR/cosign.key (COSIGN_PASSWORD from env).
# verify: cosign verify + verify-attestation with $KEY_DIR/cosign.pub.
# Plain-HTTP local registry: --allow-http-registry. No transparency log: an empty signing config
# (keys/cosign-signing-config.json) stops cosign 3 from uploading to the public Rekor; verify ignores the tlog.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
# shellcheck source=lib/keys.sh
. "$here/lib/keys.sh"
cd "$here/.."

(($# == 2)) || die "usage: sign.sh <sign|verify> <image>"
mode=$1 name=$2
case $name in
  percona-server | percona-server-dev) repo=percona-server ;;
  percona-xtrabackup) repo=percona-xtrabackup ;;
  percona-mysql-router) repo=percona-mysql-router ;;
  percona-haproxy) repo=percona-haproxy ;;
  percona-fluentbit) repo=percona-fluentbit ;;
  percona-orchestrator) repo=percona-orchestrator ;;
  percona-server-mysql-operator | percona-xtradb-cluster-operator) repo=$name ;;
  percona-proxysql3) repo=percona-proxysql3 ;;
  percona-xtradb-cluster | percona-xtradb-cluster-backup) repo=$name ;;
  percona-binlog-server) repo=percona-binlog-server ;;
  percona-toolkit) repo=percona-toolkit ;;
  pmm-client) repo=pmm-client ;;
  *) die "unknown image: $name" ;;
esac
case $mode in sign | verify) ;; *) die "unknown mode: $mode (sign|verify)" ;; esac

registry=${REGISTRY:-localhost:5000}
digest_file=${RESULTS_DIR:-out/results}/$name.digest
[[ -s $digest_file ]] || die "no digest file $digest_file (make image-$name first)"
digest=$(head -n1 "$digest_file")
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "bad digest in $digest_file"
ref=$registry/$repo@$digest

[[ -d $KEY_DIR ]] || die "no key dir $KEY_DIR (make keys)"
KEY_DIR=$(cd "$KEY_DIR" && pwd)
export COSIGN_PASSWORD=${COSIGN_PASSWORD-}
cosign=(tool cosign --user "$(id -u):$(id -g)" -e HOME=/tmp -e COSIGN_PASSWORD --network host)

# Release key dir: cosign.pub must match the committed keys/cosign.pub (copied there by `make keys`).
if [[ $KEY_DIR == "$(cd "$DEFAULT_KEY_DIR" 2>/dev/null && pwd || echo "$DEFAULT_KEY_DIR")" ]]; then
  pub=${COSIGN_PUBKEY:-keys/cosign.pub}
  [[ -r $pub ]] || die "no committed public key $pub (copy $KEY_DIR/cosign.pub there and commit it)"
  cmp -s "$pub" "$KEY_DIR/cosign.pub" || die "$KEY_DIR/cosign.pub differs from the committed $pub"
fi

if [[ $mode == sign ]]; then
  [[ -r $KEY_DIR/cosign.key ]] || die "no cosign key: $KEY_DIR/cosign.key (make keys)"
  sbom_dir=${OUT_IMAGES:-out/images}/$name
  sbom=$sbom_dir/sbom-index.spdx.json
  if [[ ! -s $sbom ]]; then
    shopt -s nullglob
    cands=("$sbom_dir"/sbom-*.spdx.json)
    shopt -u nullglob
    ((${#cands[@]} == 1)) || die "no unique SBOM in $sbom_dir (expected sbom-index.spdx.json)"
    sbom=${cands[0]}
  fi
  sbom=$(cd "$(dirname "$sbom")" && pwd)/$(basename "$sbom")
  [[ $sbom == "$PWD"/* ]] || cosign+=(-v "$(dirname "$sbom"):$(dirname "$sbom"):ro")
  cosign+=(-v "$KEY_DIR/cosign.key:/keys/cosign.key:ro")
  common=(--key /keys/cosign.key --allow-http-registry --yes --signing-config keys/cosign-signing-config.json)
  log_info "signing $ref"
  "${cosign[@]}" -- sign "${common[@]}" "$ref"
  log_info "attesting SBOM $sbom"
  "${cosign[@]}" -- attest "${common[@]}" --type spdxjson --predicate "$sbom" "$ref"
  log_info "signed $name: $ref"
else
  [[ -r $KEY_DIR/cosign.pub ]] || die "no cosign public key: $KEY_DIR/cosign.pub"
  cosign+=(-v "$KEY_DIR/cosign.pub:/keys/cosign.pub:ro")
  common=(--key /keys/cosign.pub --allow-http-registry --insecure-ignore-tlog)
  rc=0
  log_info "verifying $ref"
  "${cosign[@]}" -- verify "${common[@]}" "$ref" || rc=1
  "${cosign[@]}" -- verify-attestation "${common[@]}" --type spdxjson "$ref" >/dev/null || rc=1
  if ((rc)); then die "verification FAILED for $ref"; fi
  log_info "verified $name: signature and SBOM attestation"
fi
