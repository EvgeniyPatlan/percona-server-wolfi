# Percona Server for MySQL 9.7 on Wolfi

Builds Percona Server for MySQL 9.7 from source as Wolfi apk packages (melange) and assembles two container images
from them (apko). Not an official Percona image.

| Image | What it is |
|---|---|
| `percona-server:9.7` | Distroless: `ENTRYPOINT /usr/sbin/mysqld`, no shell, no package manager, no interpreters. |
| `percona-server:9.7-dev` | Drop-in replacement for the official `percona/percona-server:9.7`: same entrypoint script and environment-variable initialisation, plus MySQL Shell and the telemetry agent. |

## Packages

Built in this order (`PACKAGES` in `mk/packages.mk`); each recipe is `packages/<name>/melange.yaml.tmpl`.

| Package | Why it is here |
|---|---|
| `mecab`, `mecab-ipadic` | MeCab full-text parser plugin and its dictionary (not in Wolfi) |
| `v8` | V8 for the JavaScript stored-program component (`percona-server-js`) |
| `percona-server` | The server; subpackages `-server`, `-client`, `-libs`, `-rocksdb`, `-js`, `-scripts`, `-dev`, `-test`, `-icu-data-files` |
| `percona-mysql-shell` | MySQL Shell, `-dev` image only |
| `percona-telemetry-agent` | Percona telemetry agent, `-dev` image only (as in the official image) |
| `percona-server-docker-scripts` | Entrypoint script and image config from percona-docker; `percona-server-docker-config` (my.cnf) is used by both images |

Every version, commit and checksum is pinned in `versions/9.7.yaml`; every tool runs as a digest-pinned container
(`versions/tools.yaml`).

## Usage

The build needs a large Linux host (see `docs/BUILD-HOST.md` for the full runbook and the first-run order):

    make tools-pull keys     # once
    make phase-a             # sources, V8 vendoring, packages, reproducibility check
    make phase-b             # registry, images, image tests, compat diff, CVE gate, signing
    make all                 # phase-a + phase-b, then a report tarball

For day-to-day work, `scripts/build.sh` (or `make build`) builds only what is out of date: a package when its
recipe, patches, pins, build scripts or the packages it is built against changed, and an image when its packages,
template or lock file changed or its digest is not in the registry. It re-locks an image whose lock file no longer
matches the apks (commit the rewritten lock file).

    scripts/build.sh -n                       # show the plan: BUILD/SKIP for each package and image, with the reason
    scripts/build.sh                          # build what is needed for both images
    scripts/build.sh percona-server           # only the distroless image and the packages it needs
    scripts/build.sh --dev-keys               # laptop: sign with ~/.config/ps-wolfi-dev
    scripts/build.sh -f                       # rebuild everything

It skips the reproducibility checks, tests, CVE gate and signing, and a commit alone triggers no rebuild, so releases
still go through `make all`.

Quick checks without docker builds: `make lint test-unit`.

Differences from the official image and from Percona's DEB/RPM builds, each with its reason: `docs/deviations.md`.
Design and its decisions: `docs/design.md`; pins and their sources: `docs/research.md`.

## Official image vs this build

Measured on 2026-11-16 against `percona/percona-server:9.7` (9.7.2-3.1, pinned by digest as `official_ps_image`).
CVE counts are distinct (CVE, package) pairs from the pinned grype and trivy, with no VEX and no ignore list.

| | Official `percona/percona-server:9.7` | Wolfi `:9.7` (distroless) | Wolfi `:9.7-dev` |
|---|---|---|---|
| Base | RHEL 9.9 (UBI) | Wolfi | Wolfi |
| Server version | 9.7.2-3.1 | 9.7.2-2 | 9.7.2-2 |
| Built from | Percona rpms | source (melange), reproducible | source (melange), reproducible |
| Size on disk / download | 1.72 GB / 462 MB | 413 MB / 137 MB | 886 MB / 322 MB |
| Layers | 11 | 1 | 1 |
| CVEs (grype / trivy) | 382 / 387, 21 High | 0 / 0 | 1 Medium (perl) / 0 |
| Shell, package manager | yes | no | yes (busybox, bash; no apk) |
| Entrypoint | `docker-entrypoint.sh` (env-var init) | `mysqld` | `docker-entrypoint.sh` (same script) |
| MySQL Shell | yes | no | yes |
| Telemetry agent | yes | no | yes |
| JS stored programs | no | yes | yes |
| OpenSSL | 3.5 (el9) | 3.6 (LDAP/Kerberos libs load 4.0 too) | same |
| User | `mysql` (1001) | 1001 | 1001 |
| `VOLUME` / `EXPOSE` declared | yes | no (apko cannot; dirs exist writable) | no |
| SBOM | not checked | SPDX from apko, cosign attestation (`make sign`) | same |

The CVE gap is mostly the distro base: the official image's High findings are all in RHEL libraries (krb5-libs,
sqlite-libs, expat, json-glib). Neither scanner covers Percona's own packages in either image, so CVEs in mysqld itself
are tracked from Percona/Oracle release notes. A zero is a snapshot: the images stay clean only when rebuilt.

## Planned move into `percona/percona-server`

The tree is meant to move later into `build-ps/` of https://github.com/percona/percona-server (for example as
`build-ps/wolfi/`), next to `build-ps/debian` and `build-ps/rpm`. It is self-contained for that: every script and
make target resolves paths from its own directory, not from a repository root. Known follow-ups for the move:

- `packages/percona-server/melange.yaml.tmpl` checks out `ps_tag` from GitHub (`git-checkout` with
  `expected-commit`); inside the server tree it should build the enclosing checkout instead.
- The version pins in `versions/9.7.yaml` (`ps_tag`, `ps_commit`, `ps_version`, `ps_release`) would come from the
  tree (`MYSQL_VERSION`, `build-ps/version.sh`) rather than being kept by hand.
- `.gitignore` entries (`out/`, `sources/`, keys) move into the server repository's ignore rules for that directory.
