# Percona Server for MySQL 9.7 on Wolfi — Design

> **Historical document.** Written for the original combined project (Percona Server, MySQL Shell and Percona
> XtraBackup), which this repository continues; current state: README.md, docs/BUILD-HOST.md, docs/roadmap.md.

Date: 2026-11-13
Status: approved (v4: prepare on a laptop, build on a remote host)

## 1. Intent

Produce a production-grade, publicly distributable container image of
Percona Server for MySQL 9.7 built on Wolfi. Percona does not ship Wolfi
packages, so the server and every dependency Wolfi lacks must be built from
source as Wolfi-native `.apk` packages, then assembled into images.

Why Wolfi: minimal, glibc-based, rolling, low-CVE base with first-class SBOM
and signing tooling. The image must be a **drop-in replacement for
`percona/percona-server:9.7`** (the official image built from RPMs on
`redhat/ubi9-minimal`, see `percona/percona-docker/percona-server-9.x`).

## 2. Goals

1. Build Percona Server 9.7 from the GitHub tag `percona/percona-server`
   `Percona-Server-9.7.x-y` (current: `Percona-Server-9.7.2-2`) as melange
   packages, amd64.
2. Feature parity with Percona's official DEB build (see §5), including
   MyRocks, PAM, LDAP (simple + SASL), Kerberos, FIDO, keyring Vault/KMIP
   components, encryption UDFs, NUMA, telemetry component, MeCab parser,
   JavaScript stored programs (V8), LTO.
3. **Approach (decided): apks first, images second.** Phase A builds and
   tests all apks into a local signed repo — `percona-server`,
   `percona-mysql-shell` and `percona-xtrabackup` (plus build deps). Phase B
   installs those apks into images **with apko** (no Dockerfile `apk add`).
4. Images via apko:
   - `percona-server:9.7` — distroless (no shell, no apk).
   - `percona-server:9.7-dev` — with busybox/bash, the Percona entrypoint,
     telemetry agent and **mysqlsh**; **this is the drop-in image**, and with
     mysqlsh present the operator's group-replication bootstrap should work.
   - `percona-xtrabackup:9.7` — **separate image**, drop-in for the official
     `percona/percona-xtrabackup:9.7` used by the PS operator's backup jobs.
5. **MySQL Shell** built the way Percona builds `percona-mysql-shell`
   (upstream mysql-shell + Percona packaging/patches, from
   `percona/mysql-shell-packaging` or equivalent), same version as the
   official image (currently `9.7.1-2`), compiled against the PS 9.7 source
   tree, reusing the `v8` package if the required V8 version matches
   (otherwise a second pinned `v8` version). Python is embedded as Percona
   does.
6. **XtraBackup** `percona-xtrabackup` 9.7 from its GitHub tag (self-contained
   server tree), with `xbcloud`, `xbstream`, `xbcrypt`; flags follow Percona's
   own XtraBackup DEB packaging, same rules as §5 (DEB wins, CVE bumps allowed).
7. Drop-in compatibility (for `-dev`): UID/GID 1001 `mysql`, same env vars
   (`MYSQL_ROOT_PASSWORD`, `MYSQL_RANDOM_ROOT_PASSWORD`,
   `MYSQL_ALLOW_EMPTY_PASSWORD`, `MYSQL_ONETIME_PASSWORD`, `MYSQL_DATABASE`,
   `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_ROOT_HOST`,
   `MYSQL_INITDB_SKIP_TZINFO`, `MYSQL_INIT_ONLY`, `INIT_ROCKSDB`,
   `PERCONA_TELEMETRY_*`), same paths (`/etc/my.cnf`, `/etc/my.cnf.d/`,
   `/var/lib/mysql`, `/var/run/mysqld`, `/var/log/mysql`,
   `/docker-entrypoint-initdb.d`, `/docker-entrypoint.sh`), volumes, exposed
   ports 3306/33060, `USER mysql`, `CMD ["mysqld"]`, jemalloc preloaded.
8. Telemetry behaves as in the official image (server telemetry component +
   `percona-telemetry-agent` + supervisor script + `call-home.sh`, opt-out via
   `PERCONA_TELEMETRY_DISABLE`).
9. Supply chain: SPDX SBOM attached as attestation, cosign-signed image and
   attestations, CVE gate (fail on Critical/High), reproducible apks and
   image digests verified by a second independent build (§9).
10. Recipes parameterized so another series (8.4, next 9.x) can be added by
   adding a version file, not copying recipes.

## 3. Non-goals (for now)

- MySQL Router, percona-toolkit, orchestrator, HAProxy/ProxySQL images.
- A standalone `mysqlsh` image (mysqlsh ships only inside `:9.7-dev`).
- arm64.
- CI pipelines and remote registries — everything runs locally via `make`.
- Upstreaming to `wolfi-dev/os`; packages live in a local, self-signed apk repo.
- PGO, FIPS, a debug-build (`-DWITH_DEBUG`) image.

## 4. Anti-goals (failure even if it builds)

- Behaviour differs from the official image for documented env vars/paths.
- Unverifiable binaries in the image (prebuilt blobs without source build).
- Image or any apk cannot be rebuilt bit-for-bit (LTO stays on; fix the
  non-determinism instead).
- Known Critical/High CVEs at publish time without an explicit, justified VEX entry.
- Cannot start on a datadir created by the official `percona/percona-server:9.x`.

## 5. Build configuration (decided: follow Percona DEB `debian/rules`)

Where RPM and DEB differ, DEB wins. CMake flags for the release build
(mirrors `build-ps/debian/rules` @ `Percona-Server-9.7.2-2`):

```
-DBUILD_CONFIG=mysql_release -DCMAKE_BUILD_TYPE=RelWithDebInfo
-DWITH_SYSTEM_LIBS=ON -DWITH_PACKAGE_FLAGS=OFF
-DWITH_SSL=system -DWITH_ZSTD=system -DWITH_ZLIB=system -DWITH_LZ4=system
-DWITH_CURL=system -DWITH_LDAP=system -DWITH_MECAB=system
-DWITH_PROTOBUF=bundled -DWITH_RAPIDJSON=bundled -DWITH_ICU=bundled
-DWITH_EDITLINE=bundled -DWITH_LIBEVENT=bundled -DWITH_FIDO=bundled
-DWITH_ROCKSDB=ON -DROCKSDB_DISABLE_AVX2=1 -DROCKSDB_DISABLE_MARCH_NATIVE=1
-DWITH_PAM=ON -DWITH_ENCRYPTION_UDF=ON -DWITH_NUMA=ON
-DWITH_PERCONA_TELEMETRY=ON -DWITH_COMPONENT_KEYRING_VAULT=ON
-DWITH_AUTHENTICATION_CLIENT_PLUGINS=ON
-DWITH_INNODB_MEMCACHED=ON -DWITH_ARCHIVE_STORAGE_ENGINE=ON
-DWITH_BLACKHOLE_STORAGE_ENGINE=ON -DWITH_FEDERATED_STORAGE_ENGINE=ON
-DWITH_EXTRA_CHARSETS=all
-DWITH_JS_LANG=ON -DV8_INCLUDE_DIR=<v8-dev>/include -DV8_LIB_DIR=<v8-dev>/lib
-DWITH_LTO=ON
-DCOMPILATION_COMMENT="Percona Server (GPL), Release <extra>, Revision <rev>"
```

Compiler: Wolfi default `gcc` (currently 15). `-Werror` off; DEB's
`-Wno-error=free-nonheap-object -Wno-error=implicit-function-declaration`
retained. Any GCC-15 / glibc build breaks are fixed with patches kept under
`packages/percona-server/patches/`, each with a header explaining why.

Install layout: keep official-image paths (§2.4). Builder's choice of
`INSTALL_LAYOUT` (RPM-style is the closest match) as long as every path the
official entrypoint, `my.cnf` and operator reference resolves. Wolfi's
`/usr/lib` vs RPM `/usr/lib64`: provide whatever symlink is needed (e.g. the
jemalloc `LD_PRELOAD` path).

Debug info: release binaries stripped; symbols in `percona-server-dbg`.

## 6. Packages (melange)

| Package | Source | Notes |
|---|---|---|
| `v8` (build-only `v8-dev`) | V8 `12.9.202.22` (tag used by `build-ps/build_v8.sh`) | Static monolith, same gn args as Percona's `build_v8.sh` (`v8_monolithic`, no sandbox, no pointer compression, `is_clang=false`, no i18n, `use_custom_libcxx=false`, `use_sysroot=false`). Uses Wolfi `gn`, `ninja-build`. Source fetched via depot_tools once into a **pinned, sha256-checked source tarball** so the melange build itself is offline/reproducible. Never installed in runtime images. |
| `mecab`, `mecab-ipadic` | upstream MeCab 0.996 + IPA dic | Needed for `-DWITH_MECAB=system` and the `mecab` full-text parser plugin. |
| `percona-server` | git tag + submodules | Subpackages: `-server`, `-client`, `-libs` (libperconaserverclient), `-dev`, `-rocksdb`, `-icu-data-files`, `-test` (mysql-test, for nightly), `-dbg`. |
| `percona-telemetry-agent` | `github.com/percona/telemetry-agent`, version matching official image | Go build via melange go pipeline; plus `telemetry-agent-supervisor.sh` and `call-home.sh` (`Percona-Lab/telemetry-agent` tag `phase-0.1`) from percona-docker. |
| `percona-mysql-shell` | Percona's mysql-shell build (upstream `mysql/mysql-shell` 9.7.x tarball/tag + Percona packaging patches), version = official image's `MYSQL_SHELL_VERSION` | Build-deps: `percona-server` source tree (same pinned tag), `v8-dev` (version per mysql-shell requirement), Wolfi `python-3.x-dev`, `openssl`, `curl`, `libssh` (if Percona's build enables it), `antlr4` runtime if required. Embedded Python modules (certifi, etc.) pinned. Subpackages: main, `-dbg`. |
| `percona-xtrabackup` | `percona/percona-xtrabackup` tag `percona-xtrabackup-9.7.x-y` (+ submodules) | Self-contained server tree; build-deps libgcrypt, libev, curl, libaio, procps, zstd, lz4, openssl. Subpackages: main (`xtrabackup`, `xbstream`, `xbcloud`, `xbcrypt`, `xbcloud_osenv`), `-test`, `-dbg`. CMake flags from Percona's XtraBackup DEB rules. |
| `percona-xtrabackup-docker-scripts` | `percona/percona-docker` `percona-xtrabackup-9.x` (or nearest) @ pinned commit | Whatever entrypoint/helper files the official xtrabackup image ships. |
| `percona-server-docker-scripts` | `percona/percona-docker` `percona-server-9.x` @ pinned commit | `ps-entry.sh` → `/docker-entrypoint.sh`, `dockerdir/` content, `docker.cnf`. Patched only where Wolfi paths/tools differ. |

Everything else comes from Wolfi as-is (verified present on 2026-11-13):
gcc, cmake, bison, openssl, krb5, openldap, cyrus-sasl, linux-pam, libfido2
deps (libcbor), curl, zstd, lz4, zlib, libaio, numactl, libtirpc,
rpcsvc-proto, jemalloc, gflags, snappy, ncurses, perl, gn, ninja-build,
busybox, bash, tzdata.

Build order (sequential, workspace deleted between steps because of disk):
`v8` → `mecab`/`mecab-ipadic` → `percona-server` → `percona-mysql-shell` →
`percona-xtrabackup` → telemetry agent + docker-scripts. Phase A is done
when every apk passes its melange tests and `verify-repro`.

Version parameterization: one `versions/9.7.yaml` (PS tag, revision,
mysql-shell version, xtrabackup tag, telemetry agent version, V8 tag(s),
percona-docker commit) feeds templated
melange/apko configs (`melange --vars-file`, apko config generation).

## 7. Images (apko)

- **`:9.7-dev`** (drop-in): wolfi-baselayout, glibc, busybox, bash, coreutils
  needed by the entrypoint (`hostname`, `which`, `tar`, `findutils`, `pwgen`
  equivalent), tzdata, jemalloc, cracklib dicts, `percona-server-server`,
  `-client`, `-rocksdb`, `-icu-data-files`, `-devel` equivalent (official
  image installs `percona-server-devel`), `percona-mysql-shell`, telemetry
  agent, docker scripts.
  `accounts`: `mysql` 1001:1001 (home `/home/mysql` (corrected: official useradd -m); group `root`
  ownership of writable dirs as in official image so arbitrary UID works).
  Entry/cmd/env/volumes/ports identical to official Dockerfile.
- **`:9.7`** (distroless): same server packages, no shell, no apk, no
  entrypoint script, no telemetry agent (it needs the shell supervisor).
  Entrypoint `mysqld`. Datadir initialisation is the caller's job
  (e.g. `mysqld --initialize-insecure` via an init container from `-dev`).
  *Approved — see §11.*
- **`percona-xtrabackup:9.7`** (separate, drop-in for official
  `percona/percona-xtrabackup:9.7`): busybox/bash, `percona-xtrabackup`,
  compression tools (zstd, lz4), the client libs it needs, its docker
  scripts; same user, entrypoint, env and paths as the official image (to be
  read from `percona-docker` during Phase B).

Tags: `9.7`, `9.7.2-2`, `9.7.2-2-<build>` (+ `-dev` variants); xtrabackup
image tagged by its own version. Pushed to a
local registry (`localhost:5000`) for now.

## 8. Testing

1. **melange `test:` (every build, minutes):** `mysqld --version`, plugin/
   component library presence, MTR smoke subset (e.g. `main.1st`,
   `main.mysqldump`, `rocksdb.rocksdb`, a JS stored-program test, a mecab
   parser test, `auth_sec` basics).
2. **Nightly/manual (`make mtr-nightly`, hours):** suites `main`, `innodb`,
   `rocksdb`, `percona-specific (sys_vars, audit_log_filter, component_*)`,
   using `percona-server-test`.
3. **Container tests (`make test-image`, every image build):**
   - init with each env-var mode; `/docker-entrypoint-initdb.d` `.sql/.sh/.sql.gz`.
   - load: `auth_pam`, `authentication_ldap_simple/sasl`,
     `authentication_kerberos`, `authentication_fido`, `component_keyring_vault`
     (against a throwaway Vault container), `component_keyring_kmip`
     (PyKMIP container), `rocksdb`, encryption UDFs, `mecab` parser,
     JS stored program executes.
   - runs as UID 1001 and as arbitrary UID (OpenShift-style).
   - telemetry: disabled via `PERCONA_TELEMETRY_DISABLE=1`, agent starts otherwise.
   - async replication official ⇄ Wolfi image.
   - **mysqlsh:** `mysqlsh --version`, JS + Python modes start,
     `dba.createCluster()` on 3 Wolfi `-dev` containers (group replication),
     `util.dumpInstance`/`loadDump` round trip.
   - **XtraBackup:** backup (incl. RocksDB, keyring-encrypted tablespace) of
     the Wolfi server → `--prepare` → restore → server starts and data
     matches; `xbstream` + zstd/lz4 compression; `xbcloud` against a MinIO
     container; cross-check: Wolfi xtrabackup backs up the *official* server
     image and vice versa.
   - (later, optional) PS operator smoke: deploy with Wolfi `-dev` +
     xtrabackup images, GR cluster comes up, one backup/restore succeeds.
   - diff of `SHOW VARIABLES`/`SHOW PLUGINS`/`SELECT * FROM mysql.component`
     and the plugin/component file list against the official image.
     **Decided: the official RPM-based image wins** — every runtime
     difference (including ones caused by following DEB build flags) is a
     bug to fix via flags/config/patches unless the project owner adds it to
     `tests/compat/allowlist.yaml` (expected candidates: hostname, version
     comment, paths that are Wolfi-specific but symlinked).
   - Upgrade gate scope (my call): direct in-place start on datadirs created
     by the official `percona/percona-server:9.7` (previous patch release)
     and the previous 9.x Innovation image still on Docker Hub; fixtures
     contain InnoDB + RocksDB tables, a keyring-encrypted tablespace
     (`component_keyring_file`), a JS stored program and users with
     PAM/LDAP-style auth plugins. If MySQL itself does not support the jump,
     that version is dropped from the matrix rather than treated as our bug.
     Rollback to the official image is out of scope.

## 9. Supply chain

- Local apk signing key via `melange keygen`, kept outside the tree
  (`~/.config/ps-wolfi/`), never committed; public key shipped in repo.
- SBOM: apko SPDX per image + melange per package. Percona's own SBOM
  component list (`build-ps/sbom/components.txt`) used to cross-check bundled
  libs (protobuf, rapidjson, icu, libevent, editline, fido, rocksdb bundled
  deps) are declared.
- Signing: cosign, key-based for now (keyless needs CI OIDC).
- CVE gate: grype **and** trivy on the image; fail on Critical/High not
  covered by a reviewed OpenVEX file (`vex/`).
- Reproducibility (**decided: identical apks AND identical image digest,
  LTO stays on**): `SOURCE_DATE_EPOCH` from tag commit time, melange
  defaults, `-ffile-prefix-map`/`-fdebug-prefix-map`, deterministic LTO
  (`-flto-partition` fixed, no `-flto=auto` job-count dependence, fixed
  `-frandom-seed` per object), pinned Wolfi package versions (apko lock
  file). `make verify-repro` builds twice in clean workspaces on the build host
  (different path and time), and — as the independent check — a second
  build on the laptop later (decided); it compares apk checksums and image
  digests. Any mismatch blocks release; diffoscope runs on the mismatching
  apk only (not whole build trees) and fixes become
  patches. This is an explicit, possibly long, work stream.
- CVE remediation policy (**decided**): to pass the gate, bumping V8 or
  switching a bundled library (protobuf, ICU, libevent, editline, fido) to
  the Wolfi system package **is allowed** even though it departs from DEB
  parity; each departure is recorded in `docs/deviations.md`. VEX is used
  only for findings that are genuinely not applicable (my call: VEX entries
  are reviewed by the project owner).

## 10. Constraints and where things run (decided)

- **Laptop (this machine, 20 cores / 62 GB RAM / ~50 GB free):** preparation
  only — write recipes, apko configs, scripts, tests, docs; lint/validate
  configs (`melange lint`, YAML schema checks, shellcheck) and small smoke
  builds that fit (e.g. mecab, telemetry agent). No full PS/mysqlsh/XtraBackup
  /V8 builds here. Later, optionally, the **second reproducibility build**
  runs here, one package at a time, if disk allows.
- **Build host (big x86_64 Linux server, 32+ cores, 64+ GB RAM, 200+ GB
  disk, full internet, Docker only):** all real builds, tests, signing and
  scanning. Nothing may be installed on the host besides what exists:
  **every tool runs as a container** — melange
  (`cgr.dev/chainguard/melange`), apko (`cgr.dev/chainguard/apko`), cosign,
  grype, trivy, diffoscope, a local `registry:2` on `localhost:5000`, MinIO,
  Vault, PyKMIP for tests. Image versions pinned by digest in
  `versions/tools.yaml`. melange runs with the Docker runner (privileged
  container or `--runner docker`) — builder to pick what works on that host.
- **No remote access from the laptop:** the user runs commands on the build host.
  Therefore every step is a single `make <target>` with clear logs written to
  `out/logs/<target>-<timestamp>.log`, and `make report` bundles logs/results
  into one tarball the user can bring back for analysis.
- **Transfer:** local git repo (`git init` here, no remote yet); the user
  moves it (push/clone/bundle) to the build host. Generated artefacts
  (`out/`, `packages/` repo, `sources/` cache, keys) are git-ignored.
- **Keys** are generated on the build host (`make keys`) into
  `~/.config/ps-wolfi/`, never committed; public apk key copied into the repo
  after generation.
- Disk on the build host is not a hard limit, but stages still clean their
  workspaces; ccache capped (default 30 GB, configurable). `make check-disk`
  warns below 100 GB free. LTO link phase: limit parallel link jobs; RAM
  pressure expected.
- Sources fetched on the build host into `sources/` with sha256 pins in
  `versions/9.7.yaml`; network flakiness handled with retries.

## 11. Calls made by the designer (please check)

1. **(Approved by owner)** Distroless `:9.7` has no env-var init and no
   telemetry agent; the drop-in promise applies to `:9.7-dev`.
2. V8 sources vendored into a pinned tarball before the melange build
   (gclient cannot run reproducibly inside melange).
3. Telemetry agent and percona-docker scripts packaged as apks (not copied
   into images ad hoc) so they appear in SBOMs.
4. Grype + trivy both used for the CVE gate; VEX file for accepted findings.
5. Local registry `localhost:5000` on the build host; key-based cosign.
7. All tools as pinned containers; one `make` target per step with log files, since the user runs the builds on the build host.
6. Project layout: `packages/<name>/melange.yaml`, `images/*.apko.yaml`,
   `versions/`, `tests/`, `vex/`, `Makefile`, `docs/`.

## 12. Left to the builder

Exact `INSTALL_LAYOUT` / dir flags, which patches GCC 15 needs, MTR smoke
test list, subpackage file splits, ccache placement, apko package pins.
