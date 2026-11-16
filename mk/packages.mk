# Template rendering and recipe validation (melange/apko run via tool containers).
# lint-recipes uses `melange compile` (validates the recipe); `melange lint` only checks built apks.
PKG_TMPLS := $(wildcard packages/*/melange.yaml.tmpl)
IMG_TMPLS := $(wildcard images/*.tmpl)

.PHONY: render lint-recipes

render:
	$(call logged, \
	  if [ -z "$(strip $(PKG_TMPLS) $(IMG_TMPLS))" ]; then echo "render: no templates found - nothing to do"; fi; \
	  for t in $(PKG_TMPLS); do \
	    n=$$(basename "$$(dirname "$$t")"); \
	    scripts/render.sh "$$t" $(VERSION_FILE) "out/rendered/packages/$$n.yaml"; \
	  done; \
	  for t in $(IMG_TMPLS); do \
	    n=$$(basename "$$t" .tmpl); n=$${n%.yaml}; \
	    scripts/render.sh "$$t" $(VERSION_FILE) "out/rendered/images/$$n.yaml"; \
	  done)

lint-recipes: render
	$(call logged, source scripts/lib/common.sh; \
	  shopt -s nullglob; n=0; \
	  for f in out/rendered/packages/*.yaml; do n=$$((n+1)); tool melange -- compile "$$f" --arch x86_64 >/dev/null; done; \
	  for f in out/rendered/images/*.yaml; do n=$$((n+1)); tool apko -- show-config "$$f"; done; \
	  if [ $$n -eq 0 ]; then log_info "lint-recipes: no rendered recipes - nothing to lint"; fi)

# Package builds (melange, privileged container). Order matters: later packages depend on earlier ones.
PACKAGES := mecab mecab-ipadic v8 percona-server percona-mysql-shell percona-xtrabackup \
  percona-telemetry-agent percona-server-docker-scripts percona-xtrabackup-docker-scripts

.PHONY: packages $(addprefix pkg-,$(PACKAGES))

$(addprefix pkg-,$(PACKAGES)): pkg-%:
	$(call logged, MIN_GB=$(MIN_GB) scripts/check-disk.sh && scripts/melange-build.sh $*)

packages:
	$(foreach p,$(PACKAGES),$(MAKE) pkg-$(p) &&) true
