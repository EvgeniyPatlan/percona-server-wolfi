# Reproducibility: second build without ccache into a separate workspace/repo, then compare apks by sha256 (signature excluded).
# APKINDEX is signed per run and is excluded from the comparison (only *.apk are compared).
REPRO_A ?= out/repo
REPRO_B ?= out/repo-repro
A ?= $(REPRO_A)
B ?= $(REPRO_B)

.PHONY: repro-build repro-all verify-repro repro-import clean-workspaces

# Second (no-cache) build of every package, in PACKAGES order, into out/repo-repro. Roughly doubles the package build
# time (the first build benefits from ccache, this one does not). Needed before a full verify-repro.
repro-all:
	$(call logged, $(foreach p,$(PACKAGES),$(MAKE) --no-print-directory repro-build PKG=$(p) &&) true)

# Remove the per-package workspaces and staging dirs that failed builds leave behind. The build output is root-owned,
# so the removal runs inside the wolfi_sdk container. Keeps out/repo, out/cache, out/results and out/logs.
clean-workspaces:
	$(call logged, source scripts/lib/common.sh; mkdir -p out; \
	  tool wolfi_sdk -v "$$PWD/out:/o" --entrypoint sh -- -c 'cd /o && rm -rf workspace ws-repro stage rendered'; \
	  log_info "cleaned out/workspace out/ws-repro out/stage out/rendered")

repro-build:
	@test -n "$(PKG)" || { echo "usage: make repro-build PKG=<name>" >&2; exit 2; }
	$(call logged, MIN_GB=$(MIN_GB) scripts/check-disk.sh && \
	  scripts/melange-build.sh $(PKG) --no-cache --workspace-root out/ws-repro --out $(REPRO_B) --deps-repo $(REPRO_A))

# Set SUBSET=1 when out/repo-repro holds only some packages (per-package runs): names only in A are then skipped.
verify-repro:
	$(call logged, scripts/verify-repro.sh apks $(if $(SUBSET),--subset-of-b) $(A) $(B))

# laptop: unpack a host repo tarball (tar of the host's out/repo) to compare against a laptop repro-build
repro-import:
	@test -n "$(BUNDLE)" -a -f "$(BUNDLE)" || { echo "usage: make repro-import BUNDLE=<repo.tar[.gz]>" >&2; exit 2; }
	rm -rf out/repo-host && mkdir -p out/repo-host
	tar -xf "$(BUNDLE)" -C out/repo-host
	@echo "unpacked into out/repo-host. Next (docs/BUILD-HOST.md, laptop procedure): cp -a out/repo-host/. out/repo/;"
	@echo "make repro-build PKG=<name>; make verify-repro SUBSET=1 A=out/repo-host B=out/repo-repro"
