SHELL := bash
.SHELLFLAGS := -euo pipefail -c
VERSION_FILE ?= versions/9.7.yaml
MIN_GB ?= 100
ts = $(shell date -u +%Y%m%dT%H%M%SZ)
BATS := out/tools/bats/bin/bats

# logged: tee a recipe's output to out/logs/<target>-<ts>.log, keep exit status.
# usage: $(call logged,<shell commands>)
define logged
mkdir -p out/logs; \
LOG=out/logs/$@-$(ts).log; \
{ $(1); } 2>&1 | tee "$$LOG"; exit "$${PIPESTATUS[0]}"
endef

include mk/tools.mk
include mk/packages.mk
include mk/repro.mk
include mk/sources.mk
include mk/images.mk
include mk/tests.mk
include mk/supply.mk

.PHONY: test-unit lint check-disk report phase-a phase-b all build

# End-to-end, in order (see docs/BUILD-HOST.md). Prerequisites run in the listed order, never in parallel.
# REPRO=0 skips the second package build and the comparison in phase-a (not for a release).
REPRO ?= 1
.NOTPARALLEL:
phase-a: sources git-mirrors vendor-v8 packages $(if $(filter 0,$(REPRO)),,repro-all verify-repro)
phase-b: registry-up images repro-images test-image test-compat test-upgrade test-mysqlsh test-xtrabackup test-router test-pxc scan sign verify-sign
# `all` always produces the report, even after a failure, and exits with the original status.
all:
	@$(MAKE) phase-a phase-b; rc=$$?; $(MAKE) report; exit $$rc

# Incremental build: only the packages and images whose inputs changed (scripts/build.sh).
# ARGS passes options and image names, e.g. make build ARGS="-n" (plan only) or ARGS="--dev-keys percona-server".
build:
	$(call logged, scripts/build.sh $(ARGS))

$(BATS):
	scripts/get-bats.sh

test-unit: $(BATS)
	$(BATS) tests/unit

# SC2329: bats tests define stub functions that are invoked indirectly via `run`.
# SC2030/SC2031: each @test runs in its own subshell, so exported test state is intentionally local.
SC_BATS_EXCLUDE := SC2154,SC1090,SC1091,SC2034,SC2317,SC2329,SC2030,SC2031
SH_FILES = $(shell find scripts tests packages -name '*.sh' -o -name '*.bash' | sort)
BATS_FILES = $(shell find tests -name '*.bats' | sort)

# shellcheck runs in its pinned container; bats files are checked as bash.
lint:
	$(call logged, source scripts/lib/common.sh; \
	  tool shellcheck -- -x -P SCRIPTDIR $(SH_FILES); \
	  tool shellcheck -- -s bash -e $(SC_BATS_EXCLUDE) $(BATS_FILES))

check-disk:
	$(call logged, MIN_GB=$(MIN_GB) scripts/check-disk.sh)

report:
	$(call logged, scripts/report.sh)
