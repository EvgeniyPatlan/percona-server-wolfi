# Research: pins for the PS 9.7 Wolfi build

> **Historical document.** Written for the original combined project (Percona Server, MySQL Shell and Percona
> XtraBackup). This repository builds Percona Server and its two images only; the XtraBackup parts (recipes, image,
> tests, `pxb_*` pins) were not carried over. Sections on them are kept for the record.

Date: 2026-11-13. All values are in `versions/9.7.yaml` / `versions/tools.yaml`.
"Official image" = `percona/percona-server:9.7` as of 2026-11-13.

## 0. Open flags (read first)

1. **Version gap, PS:** the official image is `9.7.2-3.1` (Docker Hub tags `9.7`, `9.7.2`, `9.7.2-3`, pushed 2026-11-12), but the newest
   GitHub tag is `Percona-Server-9.7.2-2` (tags that exist: `9.7.1-1`, `9.7.2-2`; `Percona-Server-9.7.2-3` returns 404). The `9.7` branch
   HEAD (`730c85de69`, 2026-11-12) still has `MYSQL_VERSION_EXTRA=-2`. Pinned `Percona-Server-9.7.2-2`. Re-check for a `9.7.2-3` tag before release.
2. **mysql-shell has no V8.** Step 3 does not apply (no `v8_shell_tag`, no deviation row). mysqlsh 9.7.1 JavaScript uses an optional prebuilt
   GraalVM "polyglot jit executor" library (`libjitexecutor.so`) that Percona downloads as a binary blob. Decision needed from the owner in the
   mysqlsh task: ship that blob (parity with the official image, JS mode works) or build without it (`\js` unavailable). See section 1.
3. **Telemetry agent version is inferred** (`1.0.20`), see section 4.
4. **`v8_src_sha256` is `TODO-UNRESOLVED`**: it is the hash of the tarball our own `scripts/vendor-v8.sh` will produce on the build host.
5. **MinIO:** official MinIO images are no longer published on Docker Hub or quay.io (`pull access denied` / 401). The pin is the Chainguard build.
6. `registry:2` image is from 2023-10 (latest 2.x release); fine for a local test registry.
7. PXB official image also ships extras (azure-cli, aws-cli v2, socat, jq, qpress, `percona-xtradb-cluster-garbd`); see section 2.

## 1. Percona MySQL Shell 9.7.1-2

- Version in official image: `MYSQL_SHELL_VERSION 9.7.1-2` (rpm `percona-mysql-shell-9.7.1-2.el9`), from
  `percona/percona-docker` `percona-server-9.x/Dockerfile` @ `91391598878bb16a47a2655147cb85878858ca36`.
- Source: **upstream** `https://github.com/mysql/mysql-shell` tag `9.7.1` (commit `ad74f712a312fa62bfc9e3c9c92a509369bca55e`, 2026-06-03;
  `MYSQL_VERSION` = 9.7.1). Tarball `https://github.com/mysql/mysql-shell/archive/refs/tags/9.7.1.tar.gz`,
  sha256 `dbafcad09acb50d203a64dd33e25b475dba40fc31c56d45de88f365b42b4fc04` (downloaded twice, identical; 11.7 MB).
- Percona packaging repo: `https://github.com/percona/mysql-shell-packaging`, `main` @ `a01decf9af2e34d98d011f24c819505f95722932`
  (2026-11-04). Files: `mysql-shell_builder.sh` (1663 lines), `build_v8.sh`, `build_graal.sh`, `use_full_protobuf`, `exeutils.cmake-*.patch`.
  No patches are applied to mysql-shell 9.x itself (the `PS-10413` patch lines in `get_sources` are commented out); only `cmake/exeutils.cmake`
  is sed-edited (patchelf lines commented out, `if(NOT TARGET ...)` guard) and RPM spec/debian rules are sed-edited with the flags below.
- The shell is built against a **built Percona Server source tree** (`-DMYSQL_SOURCE_DIR`, `-DMYSQL_BUILD_DIR`). Percona first configures that PS
  tree with: `-DENABLE_DOWNLOADS=1 -DWITH_SSL=system -DWITH_BOOST=<boost> -DWITH_ABSEIL=bundled -DWITH_ZLIB=bundled -DWITH_COREDUMPER=OFF
  -DWITH_CURL=system -DALLOW_NO_SSE42=1 -DWITH_ADMINAPI=OFF`, then builds only these targets: `authentication_oci_client mysqlclient
  mysqlxclient mysqlxclient_lite mysqlxmessages_lite libprotobuf-lite gmock gmock_main` + ~70 `absl_*` libs +
  `authentication_ldap_sasl_client authentication_kerberos_client authentication_webauthn_client authentication_openid_connect_client
  mysql_native_password mysqlbinlog mysql_binlog_event_standalone`, then `patchelf --set-rpath '$ORIGIN' library_output_directory/lib*.so*`.
  Note: the script hardcodes `BOOST_VER=1.77.0`, but PS/PXB 9.7 `cmake/boost.cmake` require `boost_1_87_0` (script is not current for 9.7).
  For 9.x it also pre-generates `router/src/routing_guidelines/src/parser.cc` with `bison -t --no-lines --warnings=all,no-yacc,no-precedence
  --defines=parser.h` and copies it into the build dir.
- Shell cmake flags (deb path, `sed` into `debian/rules`; rpm path adds the same via spec defines):
  `-DBUNDLED_PYTHON_DIR=/usr/local/python312 -DPYTHON_INCLUDE_DIRS=.../python3.12 -DPYTHON_LIBRARIES=.../libpython3.12.so
  -DBUNDLED_ANTLR_DIR=/opt/antlr4/usr/local -DCMAKE_BUILD_TYPE=RelWithDebInfo -DMYSQL_SOURCE_DIR=<ps> -DMYSQL_BUILD_DIR=<ps>/bld
  -DMYSQL_EXTRA_LIBRARIES='-lz -ldl -lssl -lcrypto -licui18n -licuuc -licudata' -DWITH_PROTOBUF_LITE=ON
  -DJIT_EXECUTOR_LIB=<polyglot-nativeapi-native-library> -DHAVE_PYTHON=1 -DWITH_STATIC_LINKING=ON -DWITH_OCI=<oci_sdk>
  -DZLIB_LIBRARY=<ps>/extra/zlib -DBUNDLED_ABSEIL_LIBRARIES=<ps>/bld/library_output_directory -DUSE_LD_GOLD=ON`, `-DBUNDLED_SHARED_PYTHON=yes` (rpm).
  rpm path additionally: `-DHAVE_PYTHON=2 -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF -DPACKAGE_YEAR=<year>` and `-Wno-error=stringop-overflow
  -Wno-error=maybe-uninitialized -Wno-odr` in CXX flags; `-DWITH_PROTOBUF=...` is stripped from the spec/rules.
- **V8:** upstream mysql-shell 9.7.1 `CMakeLists.txt` contains no V8 reference (only `JIT_EXECUTOR_LIB` -> `HAVE_JIT_EXECUTOR`, optional).
  Percona's `get_v8()` (downloads `v8_12.0.267.8.tar.gz`, x86_64) exists but every call site is commented out (`#get_v8`). `build_v8.sh` in
  that repo defaults to `12.0.267.8`. So: **mysql-shell needs no V8; the PS server's V8 stays `12.9.202.22`.** The `v8` package is
  server-only (and never shipped in runtime images).
- **JIT executor:** `https://downloads.percona.com/downloads/packaging/polyglot-nativeapi-native-library-lje_23.0.1_x86_64_el8.tar.gz`
  (65401582 bytes, Last-Modified 2025-05-04), sha256 `36153377bcb65a7b2fd65f0a25d658c5a6b56070f4959feb9344d55912e2e436`; contains
  `polyglot-nativeapi-native-library/{libjitexecutor.so,graal_isolate*.h,polyglot_*.h,maven-archiver/}`. Built for el8 (glibc 2.28): should load on
  Wolfi glibc; untested. Upstream has `ext/polyglot/polyglot-nativeapi-native-library/pom.xml` (building it needs GraalVM; not attempted).
- Bundled Python: rpm path `3.11.13` (`/usr/local/python311`, `--enable-shared`, `--with-openssl=/usr`), deb path `3.12.11`
  (`/usr/local/python312`). Official image is el9 (rpm) -> 3.11.13. Extra pip modules installed into the bundled Python: pyyaml, certifi,
  virtualenv, cryptography, oci, setuptools>=82, msgpack, urllib3 (pip and cffi removed afterwards; wheels deleted).
- Other bundled/built deps: ANTLR4 C++ runtime tag `4.13.2` (built shared with `-DANTLR4_INSTALL=1`, rpath `$ORIGIN`), OCI Python SDK tag `v2.6.2`
  (`build_oci_sdk`, virtualenv, `pip install -r requirements.txt`), protobuf (`PROTOBUF_BRANCH=v4.24.4` default, but 9.x uses the PS-bundled protobuf),
  libssh (deb build-dep `libssh-dev`; rpm `BUNDLED_SSH_DIR=''`), OpenSSL system for el9 (`BUNDLED_OPENSSL_DIR=system`), cmake >= 3.14.6.
- Which PS tree Percona builds the shell against for 9.7.1-2 is a job parameter (`--branch_db`), not recorded in the repo. We use the pinned PS tag.

## 2. Percona XtraBackup 9.7

- Repo `https://github.com/percona/percona-xtrabackup`. Tags: `percona-xtrabackup-9.7.1-rc1`, `percona-xtrabackup-9.7.2-2`.
  Official image `percona/percona-xtrabackup:9.7` = `9.7.2-2.1`, so tag **`percona-xtrabackup-9.7.2-2`**, tag object
  `06d530626d48702fb045339089d881b6c418d9b8`, commit `59328573fbbad763b20e0057f639634102f0a2f9` (2026-10-22T14:57:47Z).
  `XB_VERSION` = 9.7.2 / `-2`; `MYSQL_VERSION` = 9.7.2, maturity LTS.
- Submodules (`.gitmodules`): `extra/libkmip` -> `https://github.com/Percona-Lab/libkmip.git` only.
- Packaging in-tree: `storage/innobase/xtrabackup/utils/{debian/rules,debian/control,percona-xtrabackup.spec,percona-xtrabackup-8.0_builder.sh,build-rpm.sh}`.
- DEB `rules` (same flags in rpm spec), both a Debug and a release build:
  release: `-DBUILD_CONFIG=xtrabackup_release -DCMAKE_INSTALL_PREFIX=/usr -DWITH_SSL=system
  -DINSTALL_MYSQLTESTDIR=/usr/share/percona-xtrabackup-test-97 -DINSTALL_MANDIR=/usr/share/man -DWITH_MAN_PAGES=1 -DMINIMAL_RELWITHDEBINFO=OFF
  -DDOWNLOAD_BOOST=1 -DWITH_BOOST=libboost -DMYSQL_UNIX_ADDR=/var/run/mysqld/mysqld.sock -DINSTALL_PLUGINDIR=lib/xtrabackup/plugin
  -DFORCE_INSOURCE_BUILD=1 -DWITH_ZLIB=bundled -DWITH_ZSTD=bundled -DWITH_PROTOBUF=bundled` (default CMAKE_BUILD_TYPE). Debug build
  has the same flags plus `-DCMAKE_BUILD_TYPE=Debug` and only `runtime_output_directory/xtrabackup` is shipped as `/usr/bin/xtrabackup-debug`
  (rpath `$ORIGIN/../lib/private`). `libprotobuf-lite.so*` is copied to `/usr/lib/private/` (rpath `$ORIGIN`). rpm uses
  `MYSQL_UNIX_ADDR=/var/lib/mysql/mysql.sock`. Boost: `boost_1_87_0` (`cmake/boost.cmake`). Correction: it is in-tree
  (`extra/boost/boost_1_87_0`) and `cmake/boost.cmake` "always uses the bundled version", so `DOWNLOAD_BOOST`/`WITH_BOOST` are inert and
  nothing is pre-fetched.
- DEB build-deps: automake bison ca-certificates cmake debhelper libaio-dev libncurses-dev libssl-dev libtool libz-dev libgcrypt-dev libev-dev
  libcurl-dev lsb-release fakeroot libsasl2-dev vim-common python3-sphinx python3-docutils (+ `patchelf`, used in rules). Runtime Depends:
  libcurl4-openssl-dev rsync zstd lz4. rpm BuildRequires: cmake libaio-devel libgcrypt-devel ncurses-devel readline-devel zlib-devel libev-devel
  openssl-devel libcurl-devel (+ bison, patchelf).
- Official image `percona/percona-docker` `percona-xtrabackup-9.x/Dockerfile` (blob `0affa0019b1ac6799cf47da0e1e165f60867f1ee`, dir last
  changed in commit `9cbade5ebe4e1e27f1ea003608a49e6f52aa4b34`, 2026-11-04; pinned repo commit `91391598...`):
  base `redhat/ubi9-minimal`; `ENV XTRABACKUP_VERSION 9.7.2-2.1`, `PS_VERSION 9.7.2-2.1`, `PXB_TELEMETRY_VERSION=$XTRABACKUP_VERSION`,
  `CALL_HOME_VERSION 0.1`, `CALL_HOME_OPTIONAL_PARAMS=" -s el9"`; user/group `mysql` uid/gid **1001** (`/sbin/nologin`); `/backup` created
  `install -d -o 1001 -g 0 -m 0775`; `/usr/local/percona` owned mysql; `/call-home.sh` (+x) from telemetry-agent tag `phase-0.1`;
  `COPY pxb-entry.sh /docker-entrypoint.sh`; `ENTRYPOINT ["/docker-entrypoint.sh"]`, `VOLUME ["/backup"]`, `USER 1001`, `CMD ["/usr/bin/xtrabackup"]`;
  no EXPOSE. Packages: `percona-xtrabackup-97`, `percona-xtradb-cluster-garbd`, `percona-server-shared`, `percona-server-client`, socat, hostname,
  jq, procps-ng, qpress, lz4, azure-cli (urllib3 upgraded), zstd, tar, unzip, shadow-utils, glibc-langpack-en, libev (el9 rpm), AWS CLI v2 (zip
  installer), python3.12-pip (removed afterwards).
- `pxb-entry.sh` (blob `5dfa046c...`, identical in 8.x and 9.x): builds `CALL_HOME_OPTIONAL_PARAMS` from `PERCONA_INSTANCE_ID` (`-i`),
  `PERCONA_TELEMETRY_CONFIG_FILE_PATH` (`-j`), `PERCONA_SEND_TIMEOUT` (`-t`, default 7), `PERCONA_CONNECT_TIMEOUT` (`-c`, default 2); runs
  `/call-home.sh -f PRODUCT_FAMILY_PXB -v $PXB_TELEMETRY_VERSION -d DOCKER ... &>/dev/null || :`, then `exec "$@"`.
- Official image digest: `percona/percona-xtrabackup:9.7` index `sha256:07e883d6aab312ba14a5bf47d8d647690ce0db10a083d9d2d572c19c84884b4b`
  (amd64 manifest `sha256:5d57e6ebb7d1...`, pushed 2026-11-04).

## 3. Percona Server 9.7.2-2 source

- Repo `https://github.com/percona/percona-server`, tag `Percona-Server-9.7.2-2`: tag object `d24a2a506b173318b5820cb23bf1a155f65e1d63`
  (tagger Vadim Yalovets, 2026-09-28T10:14:34Z), **commit `91438a0430fbcd52dd85472edf3b357484484c22`**, committer time
  `2026-09-20T11:01:38Z` -> `source_date_epoch=1789902098` (author time 10:58:37Z not used; convention: committer date, `git log -1 --format=%ct`).
- Submodules (`.gitmodules` @ tag, gitlink SHAs):
  - `storage/rocksdb/rocksdb` -> `https://github.com/percona/rocksdb.git` @ `d0e615524b52e98b1b8862e13aaad3c04a5d252e`
  - `extra/coredumper` -> `https://github.com/Percona-Lab/coredumper.git` @ `8f2623b6d34bfc4e691bdf67b4a0d37c77513ac7`
  - `extra/libkmip` -> `https://github.com/Percona-Lab/libkmip.git` @ `82988b2de6a0687791a3ae549fc2bd5cbeb457ab`
  - `extra/jwt-cpp` -> `https://github.com/Thalhammer/jwt-cpp` @ `3e037df3e669633a3044618e30550ea2f212e915`
- Boost `boost_1_87_0` (`cmake/boost.cmake`). V8 `12.9.202.22` (`build-ps/build_v8.sh` @ tag; https://github.com/percona/percona-server/blob/Percona-Server-9.7.2-2/build-ps/build_v8.sh).
- Latest earlier tag: `Percona-Server-9.7.1-1`. Version gap vs official image: see section 0.

## 4. Telemetry agent and docker scripts (official PS 9.7 image)

- Official PS Dockerfile (`percona-server-9.x/Dockerfile`, blob `9bd4ca6c262ab28d601e63c3f582e0557dd996ff`, unchanged since commit `91391598...`):
  base `redhat/ubi9-minimal`; user/group `mysql` uid/gid 1001; installs rpm `percona-server-server`, `-devel`, `-rocksdb`, `percona-icu-data-files`,
  `percona-mysql-shell` at `9.7.2-3.1.el9` / `9.7.1-2.el9`, + hostname tzdata jemalloc(EPEL) gflags(EPEL) which cracklib-dicts tar policycoreutils;
  `percona-release enable ps-97-lts testing`, `telemetry testing`, `mysql-shell experimental`. Env: `PS_VERSION 9.7.2-3.1`, `MYSQL_SHELL_VERSION 9.7.1-2`,
  `PS_TELEMETRY_VERSION 9.7.2-3-1`, `CALL_HOME_VERSION 0.1`, `PERCONA_TELEMETRY_CHECK_INTERVAL=86400`, `..._HISTORY_KEEP_INTERVAL=604800`,
  `..._RESEND_INTERVAL=60`, `PERCONA_TELEMETRY_URL=https://check.percona.com/v1/telemetry/GenericReport`, `CALL_HOME_OPTIONAL_PARAMS=" -s el9"`.
  `ENTRYPOINT ["/docker-entrypoint.sh"]`, `USER mysql`, `EXPOSE 3306 33060`, `CMD ["mysqld"]`, `VOLUME ["/var/lib/mysql","/var/log/mysql"]`.
- `percona-telemetry-agent` is **not** a Dockerfile step: it arrives as an rpm dependency of `percona-server-server` from the `telemetry` repo
  (binary `/usr/bin/percona-telemetry-agent`, `/etc/sysconfig/percona-telemetry-agent` env file, `/var/log/percona/telemetry-agent/`). The Dockerfile
  then does `COPY dockerdir/ /` and `chown mysql` on the agent binary, `/usr/local/percona/telemetry/history` and `chmod -R go+w /var/log/percona`.
  `dockerdir/` contains only `usr/sbin/mysqld.my` (`{ "read_local_manifest": true }`) and
  `usr/lib64/mysql/plugin/component_keyring_vault.cnf` (`{ "read_local_config": true }`).
  `telemetry-agent-supervisor.sh` (blob `6ad026eefcae14dea4c1904de46e4ac19db816db`): phase-0 `call-home.sh -f PRODUCT_FAMILY_PS -v $PS_TELEMETRY_VERSION
  -d DOCKER`, then up to 3 tries of `/usr/bin/percona-telemetry-agent` (stdout/stderr to `/var/log/percona/telemetry-agent{,-error}.log`), then `sleep infinity`.
- Agent version: the Dockerfile does not pin it. Image build step "rpm install" ran 2026-11-12T12:41:12Z. Rpm build times (from rpm headers):
  `1.0.19` 2026-10-21T11:44Z, `1.0.20` 2026-11-08T15:20Z, `1.0.21` 2026-11-12T14:43Z (after the image). So the image has **`1.0.20`**
  (inference; not confirmed from the image's rpmdb because the host has 5 GB free disk). Repo `https://github.com/percona/telemetry-agent`
  tag `v1.0.20` -> commit `33457ea97dd22dd22b0c5b9e9ee0f65314135691` (2026-11-08T14:58:50Z). Newer: `v1.0.21` `ddbfb045f7e82812a211e419e29860ba11595da9`
  (2026-11-12). Agent packaging (`packaging/conf/percona-telemetry-agent.env`, `.service`, `.logrotate`) is in the same repo.
- call-home.sh: tarball `https://github.com/Percona-Lab/telemetry-agent/archive/refs/tags/phase-0.1.tar.gz`, sha256
  `5e84d2f1a5d57f44c46e6a1f16794d649d3de09fe8021f0294bc321c89e51068` (verified by download = Dockerfile value); contents `call-home.sh`, `README`.
- `percona-docker` pin: `91391598878bb16a47a2655147cb85878858ca36` (main HEAD 2026-11-13T12:44:13Z; `percona-server-9.x` last changed there).
  Entry script `percona-server-9.x/ps-entry.sh` blob `a7fe81b6f450908e5b9d77cffb4fa158b93a8b15` (matches the copy used for analysis).
  `percona-xtrabackup-9.x` last changed in `9cbade5ebe4e1e27f1ea003608a49e6f52aa4b34`; both are contained in the pinned commit.

## 5. MeCab

Upstream (Google Drive links) is not scriptable. Debian orig tarballs (stable pool URLs):
- `mecab_0.996.orig.tar.gz`, sha256 `e073325783135b72e666145c781bb48fada583d5224fb2490fb6c1403ba69c59` (1398663 bytes)
- `mecab-ipadic_2.7.0-20070801+main.orig.tar.gz`, sha256 `b62f527d881c504576baed9c6ef6561554658b175ce6ae0096a60307e49e3523` (12208105 bytes)
Neither exists in Wolfi. MeCab 0.996 is old C++ and may need `-std=gnu++14`/patches with GCC 15.

## 6. Official image digests (index digests)

| Tag | Index digest | linux/amd64 manifest |
|---|---|---|
| `percona/percona-server:9.7` = `9.7.2` = `9.7.2-3` = `9.7.2-3.1` (2026-11-12) | `sha256:7b1225974980bfb2f7eda4ee54f5d8fdf01e0a647741a26d6222f948470cb684` | `sha256:0fb6e1669a0a535b8a92d1e62bea8803fee14fe6a44c2ffa2abac5c5e3608e22` |
| `percona/percona-server:9.7.2-2` (2026-10-26) previous | `sha256:47f8f2f5bb3e66f597525ad9accd1ec49d377df02b0519b9f6819a0cdc78a7a2` | `sha256:0c6304a3e391...` (hub list) |
| `percona/percona-server:9.7.1-1` (2026-09-09) | `sha256:3507079874a6fc7a540818e2c303ae49664c3346cd7abda0db6deb07602e58c9` | |
| `percona/percona-xtrabackup:9.7` = `9.7.2-2` (2026-11-04) | `sha256:07e883d6aab312ba14a5bf47d8d647690ce0db10a083d9d2d572c19c84884b4b` | `sha256:5d57e6ebb7d1...` |

No `9.6`, `9.5` or other earlier 9.x Innovation tags exist on Docker Hub (`not found`), so "previous 9.x" = `9.7.2-2`. Total compressed size of the 9.7
amd64 image is 462 MB (11 layers). Image history confirms the official Dockerfile text above (built 2026-11-12T12:41Z).

## 7. Tool images (versions/tools.yaml)

All are index digests containing `linux/amd64`, resolved with `docker buildx imagetools inspect` on 2026-11-13. Chainguard `latest` images carry no
version label; digest is the pin. `grype` 0.121.3, `trivy` 0.76.2, `vault` 2.2.2 (from image labels). `depot_env` is the full `python:3.12`
(Debian bookworm: git, curl, python3 present) so depot_tools can run; `python` is `python:3.12-slim` for PyKMIP. `wolfi_sdk` =
`ghcr.io/wolfi-dev/sdk:latest` (built 2026-11-13). `diffoscope` from the Debian salsa registry (the GitLab registry denies anonymous pulls).
`minio`: see section 0.5.

## 8. Unresolved

- `v8_src_sha256` = `TODO-UNRESOLVED` (produced by `scripts/vendor-v8.sh`).
- Telemetry agent `1.0.20` inferred, not read from the official image's rpmdb.
- PS 9.7.2-3 has no GitHub tag (pinned 9.7.2-2).
- Which PS tag Percona builds mysql-shell 9.7.1-2 against.

## 9. Release verification checklist

- [ ] PS tag skew: re-check for a `Percona-Server-9.7.2-3` tag (official image is 9.7.2-3.1); if present re-pin `ps_tag`, `ps_commit`, `source_date_epoch`.
- [ ] Telemetry agent: confirm `rpm -q percona-telemetry-agent` in the official image; `telemetry_agent_version` 1.0.20 is inferred.
- [ ] JIT executor: owner ruling is to ship `libjitexecutor.so` as a separate subpackage `percona-mysql-shell-jit`, only in `:9.7-dev`, because the operator calls `mysqlsh --js`. Implemented in `packages/percona-mysql-shell` (`percona-mysql-shell` hard-depends on it because mysqlsh links it, DT_NEEDED); confirm the host smoke test (`--js print(1+1)`) passed.
- [ ] `v8_src_sha256`: fill in after `make vendor-v8` (currently `TODO-UNRESOLVED`).

## V8 vendoring

- `scripts/vendor-v8.sh`: `fetch --nohooks --no-history v8`, `gclient sync -D --force --nohooks --no-history --revision tags/<v8_tag>`, then
  **only** the `lastchange` hook (`build/util/LASTCHANGE`, needed by gn and not regenerable without `.git`). All other DEPS hooks are skipped:
  `sysroot`/`clang`/toolchain downloads are unneeded with `use_sysroot=false`, `is_clang=false`; bazel/gcmole/jsfunfuzz/wasm-spec-test hooks are test-only.
- V8 12.9.202.22 DEPS pins `gn_version` `git_revision:54f5b539df8c4e460b18c62a11132d77b5601136`; Wolfi gn is a 2026 snapshot (see deviations.md).
- Not verified on the laptop (needs the host): that `gclient sync --no-history` at a tag works unattended, that GCC 15 compiles V8 12.9, that Wolfi gn accepts the 12.9 build files.
