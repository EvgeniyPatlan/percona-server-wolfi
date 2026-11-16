# Images (apko) and the local registry. scripts/apko-build.sh renders, locks (images/<name>.lock.json, committed),
# builds (out/images/<name>/: image.tar + sbom-*.spdx.json) and publishes to $(REGISTRY); the index digest goes to
# out/results/<name>.digest.
IMAGES := percona-server percona-server-dev percona-xtrabackup percona-mysql-router
REGISTRY ?= localhost:5000
REGISTRY_NAME ?= ps-wolfi-registry
REGISTRY_PORT ?= 5000
DOCKER ?= docker

.PHONY: registry-up registry-down images images-lock repro-images $(addprefix image-,$(IMAGES))

# registry:2 (digest-pinned in versions/tools.yaml) on 127.0.0.1:$(REGISTRY_PORT); data in the docker volume
# $(REGISTRY_NAME). Idempotent: an already running registry is left alone.
registry-up:
	$(call logged, source scripts/lib/common.sh; \
	  if [ "$$($(DOCKER) inspect -f '{{.State.Running}}' $(REGISTRY_NAME) 2>/dev/null)" = true ]; then \
	    log_info "registry $(REGISTRY_NAME) already running"; \
	  else \
	    $(DOCKER) container rm --force $(REGISTRY_NAME) >/dev/null 2>&1 || true; \
	    $(DOCKER) run -d --name $(REGISTRY_NAME) --restart unless-stopped \
	      -p 127.0.0.1:$(REGISTRY_PORT):5000 -v $(REGISTRY_NAME):/var/lib/registry \
	      "$$(vars_get versions/tools.yaml registry)"; \
	    log_info "registry on localhost:$(REGISTRY_PORT)"; \
	  fi)

# Stops and removes the container; the image data stays in the docker volume $(REGISTRY_NAME).
registry-down:
	$(DOCKER) container rm --force $(REGISTRY_NAME)

$(addprefix image-,$(IMAGES)): image-%:
	$(call logged, REGISTRY=$(REGISTRY) scripts/apko-build.sh $*)

images:
	$(foreach i,$(IMAGES),$(MAKE) image-$(i) &&) true

# Re-resolve every package and rewrite images/*.lock.json (then rebuild and commit the lock files).
images-lock:
	$(foreach i,$(IMAGES),RELOCK=1 $(MAKE) image-$(i) &&) true

# Image reproducibility (spec section 9, part of phase-b after `images`): scripts/repro-images.sh builds every image a
# second time from the lock files the first build used, with a fresh apko cache, separate output dirs (out/repro-images/) and
# registry namespace ($(REGISTRY)/repro/...), and compares each index digest with out/results/<name>.digest.
repro-images:
	$(call logged, REGISTRY=$(REGISTRY) scripts/repro-images.sh $(IMAGES))
