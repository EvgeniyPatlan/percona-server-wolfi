# Supply chain: CVE gate (grype + trivy, OpenVEX in vex/<image>.openvex.json), cosign signing, SBOM attestation.
# Results: out/results/cve-<image>-{grype,trivy}.json; vulnerability DBs cached in out/cache/{grype,trivy}.
# Needs the images in the registry (make images) and, for sign/verify-sign, the cosign key pair (make keys).
.PHONY: scan sign verify-sign $(addprefix scan-,$(IMAGES))

# repo of an image name: the -dev image lives in the percona-server repository
image_repo = $(if $(filter percona-xtrabackup percona-mysql-router percona-server-mysql-operator percona-xtradb-cluster-operator,$(1)),$(1),percona-server)

# All images are scanned even if one fails; the gate fails at the end.
scan:
	$(call logged, rc=0; for i in $(IMAGES); do $(MAKE) --no-print-directory scan-$$i || rc=1; done; exit $$rc)

$(addprefix scan-,$(IMAGES)): scan-%:
	$(call logged, test -s out/results/$*.digest || { echo "no digest: make image-$* first" >&2; exit 1; }; \
	  DOCKER="$(DOCKER)" scripts/cve-gate.sh "$(REGISTRY)/$(call image_repo,$*)@$$(cat out/results/$*.digest)" vex/$*.openvex.json)

# COSIGN_PASSWORD is read from the environment (empty for a key made with an empty password).
sign:
	$(call logged, for i in $(IMAGES); do DOCKER="$(DOCKER)" REGISTRY=$(REGISTRY) scripts/sign.sh sign $$i || exit 1; done)

verify-sign:
	$(call logged, for i in $(IMAGES); do DOCKER="$(DOCKER)" REGISTRY=$(REGISTRY) scripts/sign.sh verify $$i || exit 1; done)
