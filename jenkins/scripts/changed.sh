#!/usr/bin/env bash
# changed.sh images            < plan: the images a `scripts/build.sh -n` plan rebuilds ("BUILD image <name> (...)")
# changed.sh tests <image...>:        the make targets that test those images, once each, in phase-b order
# The incremental job runs only these suites, the CVE gate (scan-<image>) and signing for the images it rebuilt.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here/../.."
# shellcheck source=../../scripts/lib/common.sh
. scripts/lib/common.sh

# Suites per image (mk/tests.mk). The distroless image is tested by test-image, which runs both server images.
declare -A TESTS=(
  [percona-server]="test-image"
  [percona-server-dev]="test-image test-compat test-upgrade test-mysqlsh"
  [percona-xtrabackup]="test-xtrabackup test-pxc"
  [percona-mysql-router]="test-router"
  [percona-haproxy]="test-haproxy"
  [percona-fluentbit]="test-fluentbit"
  [percona-orchestrator]="test-orchestrator"
  [percona-server-mysql-operator]="test-operators"
  [percona-xtradb-cluster-operator]="test-operators"
  [percona-proxysql3]="test-proxysql"
  [percona-xtradb-cluster]="test-pxc"
  [percona-xtradb-cluster-backup]="test-pxc"
  [percona-binlog-server]="test-binlog-server"
  [percona-toolkit]="test-toolkit"
  [pmm-client]="test-pmm-client"
)
# phase-b order
ORDER=(test-image test-compat test-upgrade test-mysqlsh test-xtrabackup test-router test-haproxy test-fluentbit
  test-orchestrator test-operators test-proxysql test-pxc test-binlog-server test-toolkit test-pmm-client)

case ${1:-} in
  images)
    awk '$1 == "BUILD" && $2 == "image" {print $3}'
    ;;
  tests)
    shift
    declare -A want=()
    for i in "$@"; do
      [[ -n ${TESTS[$i]:-} ]] || die "no test suites known for image: $i"
      for t in ${TESTS[$i]}; do want[$t]=1; done
    done
    for t in "${ORDER[@]}"; do [[ -z ${want[$t]:-} ]] || echo "$t"; done
    ;;
  *) die "usage: changed.sh images < plan | changed.sh tests <image...>" ;;
esac
