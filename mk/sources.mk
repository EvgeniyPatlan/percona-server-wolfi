# Pinned source tarballs (see scripts/fetch-all-sources.sh).
.PHONY: sources
sources:
	$(call logged, scripts/fetch-all-sources.sh $(VERSION_FILE))

# Local git mirrors of the repositories the recipes clone (scripts/git-mirror.sh, out/cache/git): melange-build.sh
# makes git in the builds use them, so a slow or dropping GitHub costs at most the first fetch. Pins come from the
# version file. Optional seeds (existing local clones, used instead of the network for the superproject):
# PS_SEED=<path to a percona-server clone>, PXB_SEED=<path to a percona-xtrabackup clone>.
.PHONY: git-mirrors
git-mirrors:
	$(call logged, source scripts/lib/common.sh; v() { vars_get $(VERSION_FILE) "$$1"; }; \
	  scripts/git-mirror.sh https://github.com/percona/percona-server "$$(v ps_tag)" "$$(v ps_commit)" \
	    $(if $(PS_SEED),--seed "$(PS_SEED)") && \
	  scripts/git-mirror.sh https://github.com/percona/percona-xtrabackup "$$(v pxb_tag)" "$$(v pxb_commit)" \
	    $(if $(PXB_SEED),--seed "$(PXB_SEED)"))

# Vendor the V8 source tree (depot_tools, several GB, network) into sources/v8-<v8_tag>.tar.gz and print
# the v8_src_sha256 line to paste into $(VERSION_FILE). When the tarball already exists it is only hashed (no fetch;
# FORCE=1 re-vendors). Either way the target FAILS unless $(VERSION_FILE) holds that sha, so phase-a / all stop right
# here on a fresh clone: paste the line into the version file, commit, re-run.
.PHONY: vendor-v8
vendor-v8:
	$(call logged, tag=$$(source scripts/lib/common.sh; vars_get $(VERSION_FILE) v8_tag); \
	  if [ -z "$(FORCE)" ] && [ -s "sources/v8-$$tag.tar.gz" ]; then scripts/vendor-v8.sh --check $(VERSION_FILE); \
	  else scripts/vendor-v8.sh $(VERSION_FILE); fi)
