# Tool container helpers. All tools run as digest-pinned images (versions/tools.yaml).
.PHONY: tools-pull
tools-pull:
	$(call logged, source scripts/lib/common.sh; \
	  grep -E '^[a-z0-9_-]+:[[:space:]]' versions/tools.yaml \
	  | while read -r name _; do \
	      img=$$(vars_get versions/tools.yaml "$${name%:}"); \
	      log_info "pulling $$img"; retry 3 $(DOCKER) pull "$$img"; \
	    done)

# Signing keys (melange + cosign), generated in containers. KEY_DIR defaults to ~/.config/ps-wolfi.
.PHONY: keys
keys:
	$(call logged, scripts/keys.sh)
