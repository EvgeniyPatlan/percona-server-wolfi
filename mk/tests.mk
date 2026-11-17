# Image behaviour tests (tests/image/*.bats): run on the build host against built images, see docs/BUILD-HOST.md.
# IMAGE is the -dev image; the distroless image is derived from it (name without -dev), or set
# PS_IMAGE_DEV / PS_IMAGE_DISTROLESS. DOCKER may be overridden (see mk/images.mk). Every suite pulls its images from
# the registry in setup_file (a failed pull fails the suite; PS_PULL=0 uses images already in the local docker), and
# scripts/run-bats.sh fails a suite in which every test was skipped.
RUN_BATS = scripts/run-bats.sh $(BATS)
IMAGE ?= $(REGISTRY)/percona-server:9.7-dev

.PHONY: test-image
test-image: $(BATS)
	$(call logged, IMAGE=$(IMAGE) DOCKER="$(DOCKER)" $(RUN_BATS) tests/image/server-init.bats \
	  tests/image/server-runtime.bats tests/image/server-plugins.bats)

# Compatibility diff against the official image (needs docker and network for the pull; see docs/BUILD-HOST.md).
# OFFICIAL defaults to the digest pinned in the version file. Result: out/results/compat-<ts>.diff. IMAGE is pulled
# first, so a stale local copy of the tag is never compared.
OFFICIAL ?= $(shell source scripts/lib/common.sh; vars_get $(VERSION_FILE) official_ps_image)

.PHONY: test-compat
test-compat:
	$(call logged, $(DOCKER) pull -q "$(IMAGE)" > /dev/null; \
	  DOCKER="$(DOCKER)" tests/compat/compare.sh "$(OFFICIAL)" "$(IMAGE)")

# Upgrade gate: Wolfi -dev image on datadirs created by the official images (official_ps_image and
# official_ps_prev_image of the version file; pulls them, ~1 GB each). Expectations: out/results/upgrade-*.expect.
.PHONY: test-upgrade
test-upgrade: $(BATS)
	$(call logged, IMAGE=$(IMAGE) DOCKER="$(DOCKER)" $(RUN_BATS) tests/image/upgrade.bats)

# mysqlsh in the -dev image: three-member group replication cluster, util.dumpInstance/loadDump (docker only, ~10 min).
.PHONY: test-mysqlsh
test-mysqlsh: $(BATS)
	$(call logged, IMAGE=$(IMAGE) DOCKER="$(DOCKER)" $(RUN_BATS) tests/image/mysqlsh.bats)

# XtraBackup image: backup/prepare/copy-back, zstd/lz4 streams, xbcloud against MinIO, cross tests with the official
# images (pulls official_ps_image and official_pxb_image of the version file; see docs/BUILD-HOST.md).
PXB_IMAGE ?= $(REGISTRY)/percona-xtrabackup:9.7
.PHONY: test-xtrabackup
test-xtrabackup: $(BATS)
	$(call logged, IMAGE=$(IMAGE) PXB_IMAGE=$(PXB_IMAGE) DOCKER="$(DOCKER)" $(RUN_BATS) tests/image/xtrabackup.bats)

# MySQL Router image: versions and operator tools, entrypoint checks, bootstrap against a three-member InnoDB Cluster
# built from the -dev image, routing on 6446/6447 (docker only, ~10 min).
ROUTER_IMAGE ?= $(REGISTRY)/percona-mysql-router:9.7
.PHONY: test-router
test-router: $(BATS)
	$(call logged, IMAGE=$(IMAGE) ROUTER_IMAGE=$(ROUTER_IMAGE) DOCKER="$(DOCKER)" $(RUN_BATS) tests/image/router.bats)

# HAProxy image: versions and the tools of the official and operator scripts, add_pxc_nodes.sh + haproxy -c on a stub
# peer list, the entrypoint running haproxy (master socket, stats socket, /metrics), liveness-check.sh against a server
# from the -dev image (docker only, ~2 min).
HAPROXY_IMAGE ?= $(REGISTRY)/percona-haproxy:3.4
.PHONY: test-haproxy
test-haproxy: $(BATS)
	$(call logged, IMAGE=$(IMAGE) HAPROXY_IMAGE=$(HAPROXY_IMAGE) DOCKER="$(DOCKER)" $(RUN_BATS) tests/image/haproxy.bats)

# Log collector image: versions and tools, fluent-bit --dry-run on the shipped config, the entrypoint tailing a log to
# stdout, logrotate mode under supercronic (also as an arbitrary UID), postrotate-mysql.sh against a server from the
# -dev image (docker only, ~2 min).
FLUENTBIT_IMAGE ?= $(REGISTRY)/percona-fluentbit:5.0
.PHONY: test-fluentbit
test-fluentbit: $(BATS)
	$(call logged, IMAGE=$(IMAGE) FLUENTBIT_IMAGE=$(FLUENTBIT_IMAGE) DOCKER="$(DOCKER)" $(RUN_BATS) tests/image/fluentbit.bats)

# Orchestrator image: version, tools, uid, the shipped configuration with the SQLite backend answering /api/health,
# orchestrator-client against it, and discovery of a replica pair built from the -dev image (docker only, ~3 min).
ORC_IMAGE ?= $(REGISTRY)/percona-orchestrator:$(shell source scripts/lib/common.sh; vars_get $(VERSION_FILE) orc_version)
.PHONY: test-orchestrator
test-orchestrator: $(BATS)
	$(call logged, IMAGE=$(IMAGE) ORC_IMAGE=$(ORC_IMAGE) DOCKER="$(DOCKER)" $(RUN_BATS) tests/image/orchestrator.bats)

# Operator images (percona-server-mysql-operator, percona-xtradb-cluster-operator): binaries start, the files the init
# containers copy are at the official paths, uid 2, an init-container run into a volume (docker only, no Kubernetes).
PS_OPERATOR_IMAGE ?= $(REGISTRY)/percona-server-mysql-operator:$(shell source scripts/lib/common.sh; vars_get $(VERSION_FILE) ps_operator_version)
PXC_OPERATOR_IMAGE ?= $(REGISTRY)/percona-xtradb-cluster-operator:$(shell source scripts/lib/common.sh; vars_get $(VERSION_FILE) pxc_operator_version)
.PHONY: test-operators
test-operators: $(BATS)
	$(call logged, PS_OPERATOR_IMAGE=$(PS_OPERATOR_IMAGE) PXC_OPERATOR_IMAGE=$(PXC_OPERATOR_IMAGE) DOCKER="$(DOCKER)" \
	  $(RUN_BATS) tests/image/operators.bats)

# ProxySQL image: versions and tools, uid, the shipped configuration (admin on 6032, offline), a backend from the -dev
# server image added through the admin interface and queried through ProxySQL (docker only, ~2 min).
PROXYSQL_IMAGE ?= $(REGISTRY)/percona-proxysql3:3.0
.PHONY: test-proxysql
test-proxysql: $(BATS)
	$(call logged, IMAGE=$(IMAGE) PROXYSQL_IMAGE=$(PROXYSQL_IMAGE) DOCKER="$(DOCKER)" $(RUN_BATS) tests/image/proxysql.bats)

# Percona XtraDB Cluster images: single-node bootstrap through the entrypoint, a three-node cluster on a docker network
# (SST by xtrabackup), a write replicated to every node, garbd from the backup image joining as an arbitrator, and
# garbd in the XtraBackup image (docker only, no network access, ~10 min).
PXC_IMAGE ?= $(REGISTRY)/percona-xtradb-cluster:9.7
PXC_BACKUP_IMAGE ?= $(REGISTRY)/percona-xtradb-cluster-backup:9.7
.PHONY: test-pxc
test-pxc: $(BATS)
	$(call logged, PXC_IMAGE=$(PXC_IMAGE) PXC_BACKUP_IMAGE=$(PXC_BACKUP_IMAGE) PXB_IMAGE=$(PXB_IMAGE) DOCKER="$(DOCKER)" \
	  $(RUN_BATS) tests/image/pxc.bats)

# Nightly MTR: percona-server-test from out/repo, run in a container built from wolfi_sdk (versions/tools.yaml) with the
# local repo and its public key (APK_PUBKEY). Results: out/results/mtr-<suite>.txt; exit 1 on any failed test that is not
# in tests/mtr/skip-<suite>.txt (lines "<test> <reason>"). The var dir is a tmpfs (MTR_TMPFS_SIZE).
SUITES ?= main,innodb,rocksdb,sys_vars,audit_log_filter,component_keyring_file
MTR_PARALLEL ?= $(shell nproc)
MTR_TMPFS_SIZE ?= 24g
comma := ,
MTR_ARGS ?=
MTR_EXTRA_PKGS ?=

.PHONY: mtr-nightly
mtr-nightly:
	$(call logged, source scripts/lib/common.sh; source scripts/lib/keys.sh; \
	  test -s "$$APK_PUBKEY" || die "public key not found: $$APK_PUBKEY (run make keys)"; \
	  test -f out/repo/x86_64/APKINDEX.tar.gz || die "no out/repo: run make packages first"; \
	  for s in $$(tr , ' ' <<<"$(SUITES)"); do test -f "tests/mtr/skip-$$s.txt" || die "no tests/mtr/skip-$$s.txt"; done; \
	  mkdir -p out/results; \
	  $(DOCKER) run --rm --user 0 --tmpfs /mtrvar:exec$(comma)size=$(MTR_TMPFS_SIZE) \
	    -v "$$PWD:/work:ro" -v "$$PWD/out/repo:/repo:ro" -v "$$PWD/out/results:/results" \
	    -v "$$(realpath "$$APK_PUBKEY"):/etc/apk/keys/ps-wolfi.rsa.pub:ro" \
	    -e SUITES="$(SUITES)" -e PARALLEL="$(MTR_PARALLEL)" -e MTR_ARGS="$(MTR_ARGS)" -e MTR_EXTRA_PKGS="$(MTR_EXTRA_PKGS)" \
	    -e HOST_UID="$$(id -u)" -e HOST_GID="$$(id -g)" \
	    --entrypoint /work/scripts/mtr-container.sh "$$(vars_get versions/tools.yaml wolfi_sdk)")
