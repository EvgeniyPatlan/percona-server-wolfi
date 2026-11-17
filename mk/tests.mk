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

# Percona Toolkit image: every pt-* tool, DBD::mysql against a server from the -dev image, pt-summary and
# pt-mysql-summary, and the Percona Operator's pt-heartbeat sidecar (tests/fixtures/heartbeat-entrypoint.sh) on the
# server's datadir volume (docker only, ~5 min).
TOOLKIT_IMAGE ?= $(REGISTRY)/percona-toolkit:3.7
.PHONY: test-toolkit
test-toolkit: $(BATS)
	$(call logged, IMAGE=$(IMAGE) TOOLKIT_IMAGE=$(TOOLKIT_IMAGE) DOCKER="$(DOCKER)" $(RUN_BATS) tests/image/toolkit.bats)

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
