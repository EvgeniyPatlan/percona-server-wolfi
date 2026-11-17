# Build host guide

This is the runbook for the build host. The top half (up to "Reference by component") is the procedure; the
reference sections below it explain each component, what to send back when it fails, and the host-only checks. The
"First host run checklist" at the end collects every open item.

## Overview: the targets in order

    make tools-pull keys          # once: pull pinned tool images, generate signing keys (then commit the public keys)
    make phase-a                  # sources vendor-v8 packages repro-all verify-repro
    make phase-b                  # registry-up images repro-images test-image test-compat test-upgrade test-mysqlsh
                                  #   test-xtrabackup test-router scan sign verify-sign
    make all                      # phase-a phase-b, then report (always, even after a failure)
    make mtr-nightly              # not part of `all`: upstream MTR suites, run separately (hours)
    scripts/build.sh              # incremental: only out-of-date packages/images (-n: plan only); not for releases
    make report                   # always: bundle out/logs, out/results, versions/ into out/report-<ts>.tar.gz

First run on a fresh clone, in exactly this order (`make all` cannot get past `vendor-v8` otherwise):

    make tools-pull keys                                   # 1. tools + signing keys
    git add keys/ps-wolfi.rsa.pub keys/cosign.pub && git commit -m "chore: public keys"   # 2. commit the public keys
    make vendor-v8                                         # 3. vendors V8, prints v8_src_sha256 and STOPS (exit 1)
    # 4. paste the printed v8_src_sha256 line into versions/9.7.yaml (replacing TODO-UNRESOLVED), then
    git commit -am "chore: pin v8_src_sha256"
    make all                                               # 5. everything else, then the report

`vendor-v8` (also the second step of `phase-a`) fails with `STOP: paste v8_src_sha256: "<sha>" into
versions/9.7.yaml, commit, re-run` whenever the version file does not hold the tarball's sha, before any package is
built. Re-running it with the tarball present only re-hashes it (no download).

`make -n all` prints the full ordered list without running anything. The targets run strictly in the listed order
(`.NOTPARALLEL`); do not use `make -j`. Every target logs to `out/logs/<target>-<timestamp>.log`.

## Prerequisites

- Linux x86_64 with Docker. melange runs privileged containers, so the user must be able to
  run `docker run --privileged`.
- At least 200 GB free disk (each package build checks for 100 GB; keep headroom for the
  apk repo, image layers and caches).
- Internet access (source tarballs, Wolfi packages, container images, vulnerability DBs).
- No other tools are required: melange, apko, cosign, shellcheck and friends all run as
  digest-pinned containers (`versions/tools.yaml`). `make` and `git` come from the host.

## Moving the repo to the build host

On the machine that has the repo:

    git bundle create ps-wolfi.bundle --all

Copy `ps-wolfi.bundle` to the build host, then:

    git clone ps-wolfi.bundle ps-wolfi
    cd ps-wolfi
    git checkout feat/ps97-wolfi

Commits made on the host (keys, lock files, the V8 hash) are sent back the same way: `git bundle create
host.bundle <base>..HEAD` or simply `git format-patch`.

## First run: tools and signing keys

    make tools-pull keys

`make keys` writes `ps-wolfi.rsa{,.pub}` and `cosign.key/.pub` to `~/.config/ps-wolfi`
(override with `KEY_DIR`; it refuses to overwrite existing keys). Set `COSIGN_PASSWORD` in
the environment to protect the cosign key (and export the same value for `make sign`). It copies the public keys to
`keys/ps-wolfi.rsa.pub` and `keys/cosign.pub`. **Commit both** (never private keys). `make sign` refuses to run when the key dir's `cosign.pub` differs from the committed one, and
release image builds use the committed `keys/ps-wolfi.rsa.pub`.

Key names matter: apk tools pick the key that verifies a signature by file name (an apk signed with `ps-wolfi.rsa`
carries `.SIGN.RSA256.ps-wolfi.rsa.pub` and only verifies against a keyring file named `ps-wolfi.rsa.pub`). The scripts
name the pair `APK_KEY_NAME` (`scripts/lib/keys.sh`): `ps-wolfi` for the release key dir, `ps-wolfi-dev` for any other,
so the private key, the public key and every keyring copy always match, and host-signed and laptop-signed apks never
claim the same key name. Do not rename the files by hand.

Throwaway builds (laptop smoke builds) use a separate dev key dir outside the repo,
`KEY_DIR=$HOME/.config/ps-wolfi-dev make keys`; in that case the public key used for `--keyring-append` is
`$KEY_DIR/ps-wolfi-dev.rsa.pub` and nothing is copied into `keys/`. A key dir inside the repo (e.g. `out/dev-keys`) still
works when set explicitly, but every tool container mounts the repo at `/work`, so its private keys are visible to all
of them (`make keys` warns).

## Phase A: sources and packages (`make phase-a`)

1. `make vendor-v8` first, on a fresh checkout: it vendors V8 (several GB), prints `v8_src_sha256: "<sha>"` and stops
   (exit 1) because `versions/9.7.yaml` still says `TODO-UNRESOLVED`. Paste the line into `versions/9.7.yaml` and
   commit, then re-run. `phase-a` runs `vendor-v8` itself: with `sources/v8-<tag>.tar.gz` present it only re-hashes the
   tarball (no fetch; `FORCE=1` re-vendors) and passes when the sha matches; an unset, `TODO-UNRESOLVED` or different
   hash stops `phase-a` / `all` there, before any package is built. See "V8".
2. `make phase-a` then runs `sources` (pinned tarballs), `git-mirrors` (see "Git mirrors"), `vendor-v8`, `packages` (the ten packages in the order of
   `PACKAGES` in `mk/packages.mk`: mecab, mecab-ipadic, v8, percona-server (including the percona-mysql-router
   subpackage), percona-mysql-shell, percona-xtrabackup, percona-telemetry-agent and the three docker-scripts packages, each with its `melange test`), then the
   reproducibility check.
3. Reproducibility cost: `verify-repro` needs a second, ccache-less build of every package (`repro-all` runs
   `make repro-build PKG=<name>` for each, into `out/repo-repro`). That second build repeats the full compile, so it
   roughly doubles the time of `packages` (percona-server and V8 are the long ones: several hours each, and the second
   build gets no ccache help). Disk: a second package repo plus `out/ws-repro` workspaces. `make phase-a REPRO=0` skips
   `repro-all` and `verify-repro` for iteration; never for a release. On a failure fix the cause (see "Reproducibility
   checks"), then re-run only the failing package: `make repro-build PKG=<name> verify-repro SUBSET=1`.

A failed package build keeps its workspace under `out/workspace/<name>` for debugging; `make clean-workspaces` removes
`out/workspace`, `out/ws-repro`, `out/stage` and `out/rendered` (build output is root-owned, so this runs in a
container). It never touches `out/repo`, `out/cache`, `out/results` or `out/logs`.

## Phase B: images, tests, supply chain (`make phase-b`)

Needs phase A's `out/repo` and committed build inputs (images record the last commit that touched `packages scripts
versions mk Makefile images/*.tmpl` as their revision; committing the lock files or docs does not change it). It runs `registry-up` (local registry
on 127.0.0.1:5000), `images` (percona-server, percona-server-dev, percona-xtrabackup, percona-mysql-router; creates `images/*.lock.json` on
the first run), `repro-images` (a second, independent build of each image from the same lock files, digests must
match: see "Images"), `test-image`, `test-compat`, `test-upgrade`, `test-mysqlsh`, `test-xtrabackup`, `test-router`, `scan`, `sign` and
`verify-sign`. apko publishes the images to the registry only (nothing is loaded into the local docker), so every image
test suite starts with `docker pull` of the refs it tests (`setup_file`); a failed pull fails the whole suite (never a
skip). `scripts/run-bats.sh` also fails a suite in which every test was skipped, so a wrong `IMAGE` cannot pass
silently.
Expect roughly 2-3 hours for the tests (25-40 min image tests, 10 min mysqlsh, 25-35 min xtrabackup, 10 min router, upgrade and
compat pulls of about 1 GB each) plus scanning.

Stops that need a decision rather than a retry: `test-compat` fails on any difference not in
`tests/compat/allowlist.yaml` (owner approval), `scan` fails on a Critical/High finding not covered by an approved VEX
statement, and `sign` needs `COSIGN_PASSWORD` if the key has a password. Fix, then re-run the failed target alone and
continue with the rest of the list (`make test-compat test-upgrade ...`); `make phase-b` can be re-run from the top,
images are rebuilt reproducibly.

## Nightly MTR (`make mtr-nightly`)

Not part of `all`. Runs the upstream MySQL Test Run suites from the `percona-server-test` apk in a container made of the
pinned `wolfi_sdk` image plus the local repo (`out/repo`, signed with `APK_PUBKEY`). The test subpackage is built with
`no-depends`, so the container installs `percona-server-{server,client,rocksdb,js}`, `perl`, `bash`, `procps`,
`diffutils` explicitly (add more with `MTR_EXTRA_PKGS="a b"`). MTR runs as the non-root user `mtr` (uid 1001) in
`/usr/share/mysql-test`, `--parallel=$(nproc)` (`MTR_PARALLEL`), `--vardir` on a tmpfs (`MTR_TMPFS_SIZE`, default 24g),
`--force --max-test-fail=0 --retry-failure=1`.

    make mtr-nightly                                   # SUITES default: main,innodb,rocksdb,sys_vars,audit_log_filter,component_keyring_file
    make mtr-nightly SUITES=main MTR_ARGS="--do-test=1st"   # quick trial

Results: `out/results/mtr-<suite>.txt` (full MTR output plus a summary block). Exit 1 when a test fails that is not in
`tests/mtr/skip-<suite>.txt`, or when MTR exits non-zero without any test result (broken startup is never a pass).
Retries: a test that fails and then passes (`[ retry-pass ]`) counts as a pass; the last result line per test decides
(host-verify the format against the first real `mtr-<suite>.txt`). Skip files hold one `<test> <reason>` per line (`#` comments allowed); an entry without a reason makes the run fail.
The files ship empty. Triage after the first run: a real bug gets a patch in `packages/percona-server/patches/`; a
failure caused only by the container environment (tmpfs without O_DIRECT, missing host tooling, no network) gets a skip
entry with the reason, and the **owner reviews every skip entry before it is committed**. If MTR cannot find the server
binaries in the packaged layout, send the head of `mtr-main.txt`; likely fixes are `MTR_ARGS` such as `--mysqld=...`
or a missing apk in `MTR_EXTRA_PKGS`. Send back `make mtr-nightly report`.

## What a failure log means

| Log (`out/logs/`) | Meaning and first look |
|---|---|
| `sources-*` | a pinned tarball failed download or its sha256 differs: fix the pin in `versions/9.7.yaml`, never skip the check |
| `vendor-v8-*` | depot_tools fetch/sync or `lastchange` hook failed (network, disk); the tarball is written only on success |
| `pkg-<name>-*` | compile, install, split or `melange test` failed; the workspace stays in `out/workspace/<name>`. First `error:` / `FAILED:` line, `UNEXPECTED-PATH`, `BUILD-PATH LEAK`, `CMD-DEP <pkg>: cmd:<x>` (a `#!` file landed in a distroless subpackage: move it to the `-scripts` subpackage; see the component sections) |
| `repro-build-*` | the second build failed (same causes as `pkg-*`) |
| `verify-repro-*` | `DIFF` lines: diffoscope HTML in `out/results/diffoscope-<apk>.html`; fix the non-determinism, rebuild the reference too |
| `image-*` / `images-*` | apko failed: a missing package in `out/repo`, a stale lock (`make images-lock`), a distroless violation message, or key mismatch |
| `test-image-*`, `test-upgrade-*`, `test-mysqlsh-*`, `test-xtrabackup-*`, `test-router-*` | bats output with `not ok` and the failing step; leftovers: `docker ps -a --filter name=psw-` |
| `test-compat-*` and `out/results/compat-*.diff` | a runtime difference from the official image; owner decides on an allowlist entry |
| `scan-*`, `out/results/cve-*` | a Critical/High finding not covered by VEX (triage order in the supply-chain section) |
| `sign-*` / `verify-sign-*` | key or registry problem; signing refuses if the committed `keys/cosign.pub` differs from the key dir |
| `mtr-nightly-*`, `out/results/mtr-<suite>.txt` | `UNEXPECTED FAILURES:` block at the end of the suite file |

## Sending results back

    make report

writes `out/report-<timestamp>.tar.gz` (logs, results, versions, MANIFEST with git HEAD and docker version). Copy it
off the host (`scp`) together with any commits you made (keys, lock files, the V8 hash). `make all` runs `make report` itself after phase-a/phase-b, also when they fail, and exits with the failure's status;
after a failure of any other single target run `make report` by hand.

## Reference by component

## Building packages

`make pkg-<name>` (e.g. `make pkg-mecab pkg-mecab-ipadic`) builds into the local signed repo `out/repo/x86_64/`
and runs the recipe's melange tests. It requires `MIN_GB=100` free by default; on a small machine override it
(`make pkg-mecab MIN_GB=5`) and use dev keys (`KEY_DIR=$HOME/.config/ps-wolfi-dev scripts/keys.sh` once, then
`KEY_DIR=$HOME/.config/ps-wolfi-dev make pkg-mecab`). Workspaces are kept after a failed build or test for debugging.

## Git mirrors (`make git-mirrors`)

The server, mysqlsh and XtraBackup recipes clone large repositories with submodules (percona-server with RocksDB,
percona-xtrabackup). `make git-mirrors` (first step after `sources` in `phase-a` and in `scripts/build.sh`) keeps bare
mirrors in `out/cache/git/<host>/<path>.git` (`scripts/git-mirror.sh`): the superproject at its pinned tag
(`ps_tag`/`ps_commit`, `pxb_tag`/`pxb_commit`) and, for every submodule, only the commit it pins (shallow fetch).
`scripts/melange-build.sh` then passes git `url.<mirror>.insteadOf` rules to the build (env file, excluded from the
recorded config), so melange's `git-checkout` clones from disk. The recipes keep their GitHub URLs, tags and
`expected-commit` checks; the source tree is the same.

    make git-mirrors                                   # network: shallow fetch of the pinned tags and submodule commits
    make git-mirrors PS_SEED=/path/to/percona-server   # superproject from an existing local clone (no network for it)

Mirrors that already hold the pinned commits are not touched, so later builds need no GitHub access for these
sources; after a pin bump only the new commits are fetched. `GIT_MIRRORS=0` makes a build clone from the network.
`out/cache` is the melange cache (also ccache); keep it between runs.

## V8

The `v8` package (static `libv8_monolith.a` + headers, subpackage `v8-dev`, build-time only) builds from a
vendored, deterministic source tarball. One-time, on the build host (needs network and several GB):

    make vendor-v8

This runs depot_tools in the `depot_env` container (`fetch --nohooks`, `gclient sync --nohooks --no-history`
at the `v8_tag`, plus the `lastchange` hook), writes `sources/v8-<v8_tag>.tar.gz` and prints a line like
`v8_src_sha256: "<sha>"`, then exits 1 until the version file holds it. Paste that line into `versions/9.7.yaml`
(replacing `TODO-UNRESOLVED`), commit, then:

    make pkg-v8 report

The recipe refuses to build while `v8_src_sha256` is still `TODO-UNRESOLVED`. If `gn gen` rejects the V8 12.9
build files with Wolfi's (much newer) `gn`, set `GN_BIN=buildtools/linux64/gn` in the recipe's configure step
(the gn revision pinned by V8's DEPS, shipped inside the vendored tree) and add a row to `docs/deviations.md`.

Host-verify for `v8` reproducibility: after the first successful `make pkg-v8`, build it a second time without
the cache, into a separate workspace and output repo (see "Reproducibility checks" below):

    make repro-build PKG=v8

and compare the two `v8-dev` apks (sha256, then diffoscope if they differ). If `libv8_monolith.a` differs, check
that the `cc_wrapper` prefix-map reached the compile commands (`ninja -C out.gn/static -t commands | head`).

## Percona Server (`percona-server`)

Needs `v8-dev`, `mecab`, `mecab-dev` and `mecab-ipadic` in `out/repo` first (`make pkg-mecab pkg-mecab-ipadic pkg-v8`).
Then:

    make pkg-percona-server report

What it does: `git-checkout` of `ps_tag` with submodules (network), patches from `packages/percona-server/patches/`,
CMake (spec section 5 flags) + Ninja with LTO, install, split into `percona-server-{server,client,libs,dev,rocksdb,js,
icu-data-files,scripts,test,dbg}` (`-scripts`: every `#!` file such as `mysqld_safe`, `mysqldumpslow`, `ps-admin`, so the
distroless subpackages get no `cmd:` dependencies; after the build `scripts/check-no-cmd-deps.sh` fails on a `CMD-DEP`
line for any package in `packages/percona-server/no-cmd-deps`), then `melange test` runs `packages/percona-server/tests/smoke.sh` (version, paths,
plugins, a throwaway server with RocksDB / JS / MeCab, and MTR `main.1st main.mysqldump rocksdb.rocksdb`).
Expect several hours and ~30 GB in the workspace; RAM peaks during LTO links (4 concurrent links, each
`-flto=$(nproc)`; lower `link=4` in the recipe's "Limit concurrent LTO links" step if the host runs out of memory).
ccache lives in `out/cache/ccache` and makes rebuilds after a packaging/test failure much faster (LTO links are
not cached).

`melange-build.sh` stages `packages/percona-server/` (minus the template) as melange's `--source-dir`, so
`patches/` and `tests/` appear in the build and test workspaces. If the test fails with
"tests/smoke.sh missing from the test workspace", the pinned melange does not copy `--source-dir` into the test
workspace: report it (fallback: inline the script into the recipe at render time).

On failure, send back the `make report` tarball plus:

- the last ~200 lines of `out/logs/pkg-percona-server-*.log` (first compiler error: search for `error:`; CMake
  errors: `CMake Error`);
- for a compile error, the full failing command (`FAILED:` line and the following lines in the log);
- for a test failure, the `=== ...` step it stopped at, the "last 60 lines of mysqld error log" block, and for MTR
  the `out/workspace/percona-server/` path of the failing test's log if the workspace was kept;
- every `UNEXPECTED-PATH` line from the build log (files that landed in `percona-server-server` without being
  expected - each needs a decision);
- `ls -la out/repo/x86_64/percona-server*`.

Each GCC 15 / glibc fix becomes a patch in `packages/percona-server/patches/` with the header described in
`packages/percona-server/patches/README.md`.

Host checks after the first green build (record results in the task report):

1. `mysqld --version` in the apk says `Release 2, Revision 91438a04` (compare `docker run --rm --entrypoint mysqld
   <official_ps_image> --version`: `Revision` is 8 hex digits there).
2. The build log has no `UNEXPECTED-PATH` lines (or each is explained).
3. Reproducibility: after the normal `make pkg-percona-server`, build once more without ccache, into a separate
   workspace and repo (see "Reproducibility checks"):

       make repro-build PKG=percona-server

   The `percona-server-*` apk sha256s in `out/repo/x86_64/` and `out/repo-repro/x86_64/` must match (diffoscope the
   first mismatching apk only).

## MySQL Shell (`percona-mysql-shell`)

Needs `percona-server-server` and `percona-server-client` in `out/repo` (test only: the smoke test starts a
throwaway mysqld) and the three pinned tarballs in `sources/` (`make sources` fetches `9.7.1.tar.gz`,
`4.13.2.tar.gz` (ANTLR4) and `polyglot-nativeapi-native-library-lje_23.0.1_x86_64_el8.tar.gz`, 65 MB). Then:

    make sources pkg-percona-mysql-shell report

What it does: `git-checkout` of `ps_tag` (with submodules) plus Percona's `build-ps/rpm/mysql-5.7-sharedlib-rename.patch`,
configures that tree and builds only the client-side targets the shell consumes (no LTO), builds the ANTLR4 4.13.2
C++ runtime (shared), then configures and builds mysql-shell 9.7.1 with Python 3.11 (Wolfi) and the GraalVM jit
executor (JavaScript). Output: `percona-mysql-shell` (mysqlsh, bundled libs under `/usr/lib/mysqlsh`, auth plugins
in `/usr/lib/mysql/plugins`), `percona-mysql-shell-jit` (only `libjitexecutor.so`, the prebuilt blob, hard
dependency of the main package) and `percona-mysql-shell-dbg`. `melange test` runs
`packages/percona-mysql-shell/tests/smoke.sh`: `--version`, `--js print(1+1)`, `--py print(1+1)`, and against a
throwaway mysqld `mysqlsh root@localhost --sql -e 'select 1'` (classic and X protocol) plus `--js session.runSql`.
Expect roughly an hour and ~15 GB in the workspace.

Host checks after the first green build (record results in the task report):

1. `mysqlsh --version` from the apk vs the official image
   (`docker run --rm --entrypoint mysqlsh <official_ps_image> --version`); note any difference (e.g. "for MySQL 9.7.x").
2. The build log: no `UNEXPECTED-PATH` lines (or each explained); the "rewriting DT_NEEDED" line (expected: the
   absolute build path of `libjitexecutor.so`) or its absence.
3. `readelf -d usr/bin/mysqlsh` from the apk: `NEEDED [libjitexecutor.so]`, RUNPATH `$ORIGIN/../lib/mysqlsh`, no
   absolute NEEDED entries; `ldd` inside the test container resolves everything.
4. Melange's generated dependencies (`tar -xOf out/repo/x86_64/percona-mysql-shell-9.7.1.2-r0.apk .PKGINFO`): no
   `so:` dependency on a library that only lives in `/usr/lib/mysqlsh` (libprotobuf-lite, libabsl_*, libantlr4-runtime,
   libfido2); `percona-mysql-shell-jit` is listed.
5. No Python bytecode: the recipe fails if any `*.pyc`/`__pycache__` lands in the install tree (it sets
   `PYTHONDONTWRITEBYTECODE=1`); if the shell's install ever byte-compiles on purpose, report it (the fallback is
   `python3 -m compileall --invalidation-mode unchecked-hash` under `SOURCE_DATE_EPOCH`). Also: no `BUILD-PATH LEAK`.
6. Reproducibility: after the normal build, once more without ccache into a separate workspace and repo (see
   "Reproducibility checks"):

       make repro-build PKG=percona-mysql-shell

   The three `percona-mysql-shell*` apk sha256s must match (diffoscope the first mismatching apk only).

On failure, send back the `make report` tarball plus: the last ~200 lines of `out/logs/pkg-percona-mysql-shell-*.log`;
the first `CMake Error` block (PS or shell configure; for the shell also `out/workspace/percona-mysql-shell/shell-build/CMakeFiles/CMakeError.log`
if present) or the first `FAILED:` command with its error; for a test failure the `=== ...` step it stopped at and the
log tail it printed. Likely first-build issues and their fix:

- unknown ninja target in "Build Percona Server client targets": drop/rename that target in the recipe (the list
  follows Percona's builder and mysql-shell's CMake checks);
- PythonLibs not found: check `/usr/lib/libpython3.11.so` / `/usr/include/python3.11` in `python-3.11-dev`;
- `find_package(libssh)` fails: Wolfi `libssh-dev` lacks the CMake config; report the file list of `libssh-dev`;
- duplicate `copy_<lib>` target in `cmake/exeutils.cmake`: see `packages/percona-mysql-shell/patches/README.md`.

## Percona XtraBackup (`percona-xtrabackup`)

Needs `percona-server-server` and `percona-server-client` in `out/repo` (test only: the smoke test backs up a
throwaway mysqld). No source tarballs (git checkout, Boost 1.87.0 is in-tree). Then:

    make pkg-percona-xtrabackup report

What it does: `git-checkout` of `pxb_tag` with submodules (`extra/libkmip`), checks `XB_VERSION` against
`pxb_version`/`pxb_release`, patches from `packages/percona-xtrabackup/patches/`, CMake with the DEB rules' release
flags (no LTO) + Ninja, man pages via sphinx-build, install, RPM layout (`/usr/lib64/xtrabackup/plugin` shipped as
`/usr/lib/xtrabackup/plugin`), split into `percona-xtrabackup` (xtrabackup, xbstream, xbcrypt, xbcloud, xbcloud_osenv,
bundled libs in `/usr/lib/private`, keyring components), `percona-xtrabackup-test` (`/usr/share/percona-xtrabackup-test-97`)
and `percona-xtrabackup-dbg`. `melange test` runs `packages/percona-xtrabackup/tests/smoke.sh`: `--version` (version
and `revision id: <pxb_revision>`), file list, `ldd`, `xbstream -c`/`-x` and `xbcrypt` round trips (byte-identical),
then against a throwaway Percona Server `xtrabackup --backup` and `--prepare` (both exit 0, `xtrabackup_checkpoints`
says `full-backuped` / `full-prepared`). Expect 1-2 hours and ~20 GB in the workspace (a full MySQL tree is compiled).

Host checks after the first green build (record results in the task report):

1. `xtrabackup --version` from the apk vs the official image
   (`docker run --rm --entrypoint xtrabackup <official_pxb_image> --version`): same `9.7.2-2`, `based on MySQL server
   9.7.2`, and `revision id: 59328573` (8 digits there too?).
2. The build log: no `UNEXPECTED-PATH` lines (or each explained), no `BUILD-PATH LEAK`, the smoke step
   "xtrabackup-plugin-dir default" printed `ok` (not the `NOTE:` fallback).
3. File list vs the official image: `docker run --rm --entrypoint sh <official_pxb_image> -c 'rpm -ql percona-xtrabackup-97'`
   against `tar -tzf out/repo/x86_64/percona-xtrabackup-9.7.2.2-r0.apk`. Expected differences only: no
   `xtrabackup-debug`, no `kmip*.h` / `libkmip*.a`, `/usr/lib64` -> `/usr/lib`, man pages not gzipped
   (docs/deviations.md). Send both lists if anything else differs (e.g. the set of `/usr/lib/private` libs).
4. Melange's generated dependencies (`tar -xOf out/repo/x86_64/percona-xtrabackup-9.7.2.2-r0.apk .PKGINFO`): no `so:`
   dependency on a library that only lives in `/usr/lib/private` (libprotobuf*, libabsl_*, libicu*); send the
   `depend =` lines. Same for `percona-xtrabackup-test` (should only need percona-xtrabackup, percona-server-client, bash).
5. Reproducibility: after the normal build, once more without ccache into a separate workspace and repo (see
   "Reproducibility checks"):

       make repro-build PKG=percona-xtrabackup

   The three `percona-xtrabackup*` apk sha256s must match (diffoscope the first mismatching apk only; man pages are
   sphinx output, so check those first if `percona-xtrabackup` alone differs).

On failure, send back the `make report` tarball plus: the last ~200 lines of `out/logs/pkg-percona-xtrabackup-*.log`;
the first `CMake Error` block (also `out/workspace/percona-xtrabackup/xb-build/CMakeFiles/CMakeError.log` if present)
or the first `FAILED:` command with its error; for a test failure the `=== ...` step it stopped at and the log tails
it printed (mysqld error log, `backup.log` / `prepare.log`). Likely first-build issues and their fix:

- `sphinx-build` fails (Sphinx 9 vs the old `doc/source/conf.py`): send the sphinx error; fallback is
  `-DWITH_MAN_PAGES=0` plus a deviations row (no man pages);
- `Cannot find proc/sysinfo.h or libproc2/meminfo.h`: report `apk info -L procps-dev`;
- the `rev-parse --short HEAD` check in Configure fails: report the value (git safe.directory / abbrev issue);
- GCC 15 / glibc compile errors: a patch in `packages/percona-xtrabackup/patches/` (header in its README); check
  first whether the same fix already exists in `packages/percona-server/patches/`.

## Build-path leak scan (percona-server, percona-mysql-shell, percona-xtrabackup)

After install, these recipes run `scripts/check-build-path-leaks.sh` (staged by `melange-build.sh` into the source
dir as `build-tools/`) over the install tree: any regular file containing the workspace path (`/home/build`) fails the
build with `BUILD-PATH LEAK: <path>` lines. For each hit, first try to fix the cause (a missing `-ffile-prefix-map`,
a generated file that records the build dir); only if the reference is harmless, add an anchored regex for the path
to `packages/<name>/build-path-allowlist` with a `#` comment giving the reason. Send back every `BUILD-PATH LEAK` line
with `strings <file> | grep /home/build | head` for binaries (or the matching lines for text files).

First host run: a leak stops a multi-hour build at its very end, and the next leak would only show after the next
rebuild. To collect every leak in one pass, run the first `phase-a` with `LEAK_SCAN=warn` (`LEAK_SCAN=warn make
phase-a`, or `make all LEAK_SCAN=warn`): the scan still prints every `BUILD-PATH LEAK` line plus `LEAK_SCAN=warn: not
failing the build`, but exits 0. `melange-build.sh` hands it to the build through `--env-file` and excludes it from the
recorded config (`--exclude-env-from-recorded-config LEAK_SCAN`), so the apks are the same as with the default. The
default is `LEAK_SCAN=fatal`; never release from a `warn` run: fix or allow-list every reported leak, then rebuild
without it.

## Hardening baseline (percona-server, percona-mysql-shell, percona-xtrabackup)

All three compiled recipes add `hardening_cflags` / `hardening_ldflags` from `versions/9.7.yaml` (ruling R7: stack
protector, stack-clash, CET, `_FORTIFY_SOURCE=2`, `-Werror=format-security`, full RELRO). Configure fails if the flags
are missing from `CMakeCache.txt`; `melange test` fails (step "hardening") if a shipped binary lacks `GNU_RELRO`,
`BIND_NOW` or the `__stack_chk_fail` import. A compile error from `-Werror=format-security` or a
`_FORTIFY_SOURCE` redefinition warning: send the `FAILED:` command and error; fix with a patch (format string), never
by dropping the flag from the shared key.

## Reproducibility checks

Normal builds use a persistent ccache (`out/cache/ccache`, via melange `--cache-dir`; the percona-server recipe
routes every compile through it). A second build that reuses that cache just replays cached objects, so it cannot
show non-determinism in the compiler output. Every comparison build must therefore:

- run with `--no-cache` (or point `--cache-dir` at a separate, empty directory), and
- write to a separate workspace root and output repo (`--workspace-root out/ws-repro --out out/repo-repro`), so
  the reference apks in `out/repo` are not overwritten.

`make repro-build PKG=<name>` does exactly this (it runs `scripts/melange-build.sh <name> --no-cache
--workspace-root out/ws-repro --out out/repo-repro --deps-repo out/repo`, after the disk check; dependencies come from
the reference repo so the recorded build config matches). Then:

    make repro-build PKG=<name>      # second build, no ccache, separate workspace + repo
    make verify-repro                # sha256 of every *.apk without its signature: out/repo vs out/repo-repro

`verify-repro` prints `OK|DIFF|ONLY-IN-A|ONLY-IN-B <apk>` per apk and exits 1 on anything but OK. Each apk is
hashed without its first gzip member, the signature (`scripts/lib/apk-content-hash.py`; the control member pins the
data member by its sha256, so everything else is still compared byte for byte): builds signed with different keys
compare equal. The hashing runs with local `python3`, or in the pinned `python` tool container when there is none. `APKINDEX.tar.gz`
is signed per run and always differs: it is excluded, only `*.apk` are compared. For each DIFF it runs diffoscope
on that pair only and writes `out/results/diffoscope-<apk>.html`. Compare other directories with
`make verify-repro A=<dir> B=<dir>` (add `SUBSET=1` when B holds only some of the packages in A, so apks only in A are
skipped; names only in B still fail) (or `scripts/verify-repro.sh apks <dirA> <dirB>`).

Images: `scripts/verify-repro.sh images <A> <B>`, where each side is a digest (`sha256:...`), a file holding one
(`out/results/<name>.digest`), or a registry ref (resolved with `docker buildx imagetools inspect --format
'{{.Manifest.Digest}}'`). Exit 1 if the digests differ.

Host procedure, for every package in build order: `make repro-build PKG=<name> verify-repro
SUBSET=1 report`. For each DIFF read the diffoscope report and fix the cause (prefix maps, `-frandom-seed`, sorted globs,
embedded timestamps in `mysql_config`/`INFO_BIN`, LTO partition settings) as a patch or recipe flag; repeat until
all OK. Tar the host repo for the laptop: `tar -C out/repo -cf repo-host.tar .`.

Laptop procedure (step 4), one package at a time, from the same build inputs as the host reference build
(`git checkout <host commit>`; the last commit that touched the build inputs is recorded in every apk):

1. `make repro-import BUNDLE=repo-host.tar` unpacks the host repo to `out/repo-host`; then make it the laptop's
   `out/repo` too (`cp -a out/repo-host/. out/repo/`, APKINDEX included). The laptop's second build resolves its
   dependencies from its own `out/repo` (`--deps-repo out/repo`, the same path the host build recorded), which is now
   the imported host repo, so it uses exactly the host's dependency apks.
2. Keys: the laptop signs with its own dev key and never needs the host's private key. Set
   `KEY_DIR=$HOME/.config/ps-wolfi-dev` (create it once with `make keys`) and `APK_PUBKEY=keys/ps-wolfi.rsa.pub`
   (the committed host public key, which verifies the imported dependencies). The build trusts only `APK_PUBKEY`, as
   the host build did, so the recorded build config is the same; `melange test` also trusts the dev public key, which
   signed the apks just built. `verify-repro` ignores the signatures, so the two signers do not cause a `DIFF`.
3. `make check-disk MIN_GB=35`, then build without ccache with `make repro-build PKG=<name>` (never the cached
   `make pkg-<name>`) into `out/repo-repro`, and compare `make verify-repro SUBSET=1 A=out/repo-host B=out/repo-repro`.

`SUBSET=1` skips apks that exist only in A, so a per-package build can be compared with the whole host repo;
names only in B still fail.

What the build pins so that two builds can be identical:

- Git commit: melange records a commit in every apk. `melange-build.sh` records the last commit that touched the build
  inputs, `git log -1 --format=%H -- packages scripts versions mk Makefile` (not HEAD), so commits that change only
  `docs/`, `tests/` or `images/*.lock.json` leave the apks (and the lock checksums) unchanged. Uncommitted changes
  under those paths are recorded as `<sha>-dirty` with a warning, and `RELEASE=1` refuses them unless `ALLOW_DIRTY=1`
  (changes elsewhere do not count). `REPRO_GIT_COMMIT=<value>` overrides detection (iteration only, never for release).
  Consequence: the reference build must be redone whenever the build inputs change (a commit touching one of those
  paths), and both builds of a comparison must record the same commit.
- Dependencies: repro builds resolve build dependencies from the reference repo (`--deps-repo out/repo`), so the inputs
  are the reference apks and the repository path recorded in the apk is the same; the output goes to `out/repo-repro`.
- ccache: `CCACHE_DIR`/`CCACHE_MAXSIZE` are excluded from the recorded build config
  (`--exclude-env-from-recorded-config`, present in the pinned melange), so cached and `--no-cache` builds record the same.

## Images (apko) and the local registry

Needs every package in `out/repo` (`make packages`), the signing key's public half (`keys/ps-wolfi.rsa.pub`, or
`$KEY_DIR/ps-wolfi-dev.rsa.pub` with a non-default `KEY_DIR`) and committed build inputs (the image records the last commit that touched `packages scripts versions mk Makefile
images/*.tmpl` as `org.opencontainers.image.revision`; `RELEASE=1` refuses uncommitted changes there). Then:

    make registry-up            # registry:2 (pinned) on 127.0.0.1:5000, data in the docker volume ps-wolfi-registry
    make images report          # percona-server, percona-server-dev, percona-xtrabackup, percona-mysql-router

`scripts/apko-build.sh <name>` (one image: `make image-<name>`) renders `images/<name>.apko.yaml.tmpl` to
`out/rendered/images/<name>.apko.yaml`, locks it (`images/<name>.lock.json`), runs `apko build` (`out/images/<name>/image.tar`
for `docker load`, SBOMs `out/images/<name>/sbom-{index,x86_64}.spdx.json`) and `apko publish` (host network), and writes the
index digest to `out/results/<name>.digest`. Tags (`REGISTRY`, default `localhost:5000`; add `BUILD_ID=<n>` for a
`-<n>` tag): `percona-server:9.7`, `:9.7.2-2`, `percona-server:9.7-dev`, `:9.7.2-2-dev`, `percona-xtrabackup:9.7`, `:9.7.2-2`,
`percona-mysql-router:9.7`, `:9.7.2-2`.

Lock files: the first run creates `images/*.lock.json` (every package pinned by version and checksum, including
the Wolfi ones). **Commit them** (`git add images/*.lock.json && git commit -m "chore: image lock files"`); later
runs use them as they are. apko refuses a lock file whose recorded config checksum differs from the rendered
config, so after any change to a template or to `versions/9.7.yaml` values it uses, run `make images-lock`
(`RELOCK=1`: re-resolve, rebuild, rewrite) and commit the new lock files. With `RELEASE=1` a missing lock file is an error (never generated silently); only `RELOCK=1` / `make images-lock` creates one. Rebuilding an apk changes its checksum
too: a reproducible rebuild keeps the lock valid, a changed apk needs a relock.

Reproducibility: `make repro-images` (in `phase-b` right after `images`, before the tests, scanning and signing) runs
`scripts/repro-images.sh`: a second build of all four from the lock files the first build used (`RELOCK` cleared; a lock
file that changes fails), with a fresh apko cache and separate output dirs (`out/repro-images/`), published to
`localhost:5000/repro/...` so the first build's tags, digests and SBOMs stay untouched, then compares each index digest
with `out/results/<name>.digest` (`scripts/verify-repro.sh images`); every line must be `OK`. Build date =
`source_date_epoch`, VCS detection off, revision = the last build-input commit (unchanged by committing the locks).

Host checks (record in the task report):

1. `make repro-images`: four `OK` lines.
2. Distroless: `apko-build.sh percona-server` did not stop with "must not contain" (a runtime dependency pulling in a
   shell, mysqlsh or the agent) or "is distroless but the image contains" (a shell/apk file in the image). If it did,
   send the lock file's package list and the message.
3. **Hard pass/fail** - the edited `/etc/my.cnf` from `percona-server-docker-config` must win over the RPM copy in
   `percona-server-server` (`replaces`). Both commands must print `PASS`; anything else stops the image task:

       test "$(docker run --rm --entrypoint tail localhost:5000/percona-server:9.7-dev -n1 /etc/my.cnf)" = '!includedir /etc/my.cnf.d' && echo PASS
       c=$(docker create localhost:5000/percona-server:9.7) && \
         test "$(docker cp "$c:/etc/my.cnf" - | tar -xO | tail -n1)" = '!includedir /etc/my.cnf.d' && echo PASS; docker rm "$c" >/dev/null

   Then, informational: `docker run --rm --entrypoint bash localhost:5000/percona-server:9.7-dev -c 'id; stat -c "%u:%g %a %n"
   /var/lib/mysql /run/mysqld /etc/my.cnf /etc/my.cnf.d /usr/local/percona/telemetry/history /usr/bin/percona-telemetry-agent'`:
   `uid=1001(mysql)`, owners `1001:0` (history `1001:1001`).
4. Drop-in run: `docker run -d --name ps -e MYSQL_ROOT_PASSWORD=x -p 3306:3306 localhost:5000/percona-server:9.7-dev`, then
   `docker exec ps mysql -uroot -px -e 'select @@version, @@version_comment'` and `docker exec ps mysqlsh --version`.
   Distroless: `docker run --rm -v d:/var/lib/mysql localhost:5000/percona-server:9.7-dev mysqld --initialize-insecure`, then
   `docker run -d -v d:/var/lib/mysql localhost:5000/percona-server:9.7` and connect with the -dev image's client.
5. `docker run --rm localhost:5000/percona-xtrabackup:9.7 xtrabackup --version`;
   `docker run --rm --entrypoint mysqlrouter localhost:5000/percona-mysql-router:9.7 --version`.
6. Image size vs the official ones (`docker image ls`); SBOMs present in `out/images/*/`.

`make registry-down` removes the registry container (the volume keeps the images). The apko cache is
`out/apko-cache`.

## Image behaviour tests (`make test-image`)

Bats suites in `tests/image/` exercise the built server images with plain `docker` (override with `DOCKER=...`);
bats is vendored into `out/tools/bats` on first use. Run on the build host after `make images`:

    make test-image IMAGE=localhost:5000/percona-server:9.7-dev report

`IMAGE` is the `-dev` image. The distroless image is derived by dropping `-dev` (`:9.7`); set `PS_IMAGE_DEV` /
`PS_IMAGE_DISTROLESS` to name the pair explicitly. Which image is which comes from the tag only (a tag ending in `-dev`
is the `-dev` image), never from docker; for a ref without a tag (`name@sha256:...`) set `PS_IMAGE_KIND=dev` or
`distroless`. Each suite `docker pull`s its images in `setup_file` (a failed pull or a missing image fails the suite);
with `PS_PULL=0` nothing is pulled and the images must already be in the local docker (e.g. `docker load` of
`out/images/*/image.tar`). A suite whose tests were all skipped fails (`ALL-SKIPPED <suite>` in the log), and each
suite ends with a `suite <file>: <n> test(s), <k> skipped` line. `make test-image` runs the three server suites below;
`upgrade`, `mysqlsh` and `xtrabackup` have their own targets.

- `server-init.bats`: entrypoint initialisation (root password variants, random password, one-time password,
  `MYSQL_DATABASE`/`USER`, initdb.d `.sql`/`.sql.gz`/`.sh`, missing-password error text, `MYSQL_INIT_ONLY`, `--user 4242:0`).
- `server-runtime.bats`: restart on the same volume, clean `docker stop` (no crash recovery), uid 1001 / pid 1,
  jemalloc present but not preloaded (both images, ruling R8), telemetry on/off, socket and ports, distroless on a `-dev`-initialised datadir.
- `server-plugins.bats`: PAM, LDAP simple/SASL, client plugins (kerberos, webauthn; ruling R6: no server-side
  kerberos/fido plugins exist), RocksDB (also `INIT_ROCKSDB=1`), encryption UDF, MeCab, JS routine,
  `component_keyring_vault` (hashicorp vault dev server) and `component_keyring_kmip` (PyKMIP).

Expected runtime: 25-40 minutes (about 35 containers, each initialising a datadir; Vault/PyKMIP add a few minutes).
Prerequisites: the digest-pinned `vault`, `python` and `wolfi_sdk` tool images (`make tools-pull`), and internet access
for `pip install pykmip` inside the python container (PyKMIP is pinned to 0.10.0 with `sqlalchemy<2`).
Every test removes its containers, volumes and networks in `teardown` (names `psw-<pid>-<test>-*`); after a killed run,
`docker ps -a --filter name=psw-` shows leftovers. Send the results back with `make report` (the log is in `out/logs/test-image-*.log`).
The helpers have unit tests that need no docker (`tests/unit/image-helpers.bats`, part of `make test-unit`).

## Upgrade gate (`make test-upgrade`)

The Wolfi `-dev` image must start on a datadir written by the official images. `tests/image/upgrade.bats` runs two
cases, `official_ps_image` and `official_ps_prev_image` from the version file (no 9.6/9.5 tags exist on Docker Hub, so
the matrix is two 9.7 builds). Needs docker, network, and ~1 GB per official image pulled on first use:

    make test-upgrade IMAGE=localhost:5000/percona-server:9.7-dev report

`tests/fixtures/make-upgrade-datadir.sh <official-ref> <volume>` builds the volume with the official image: InnoDB
table (1000 rows), RocksDB table, a `component_keyring_file` encrypted table (manifest and keyring file live in the
volume), a JavaScript function, `auth_pam` and `caching_sha2_password` users. The expected state (CHECKSUM TABLE values
etc.) goes to `out/results/upgrade-<volume>.expect`; the test starts the Wolfi image on the volume (ready within 300 s)
and compares. Each case prints the fixture version, the Wolfi version and the direction (`upgrade`, `same-version` or
`downgrade`). `official_ps_image` (9.7.2-3.1) is currently newer than our build (9.7.2-2), so that is a downgrade case
within the 9.7.2 series; `official_ps_prev_image` (9.7.2-2) is same-version. The "server upgrade completed" log line is
required only when the numeric server version is strictly newer. If the server refuses a non-same-version jump (log
lines such as "Cannot upgrade from"), the case is `skip`ped with the server's text (dropped from the matrix); a refusal
for a same-version start fails. If both cases are skipped the suite fails (`ALL-SKIPPED upgrade.bats`): nothing was
tested. Containers and volumes are removed in teardown. The pure helpers
are unit-tested in `tests/unit/upgrade-lib.bats`.

## mysqlsh and XtraBackup tests (`make test-mysqlsh`, `make test-xtrabackup`)

    make test-mysqlsh test-xtrabackup IMAGE=localhost:5000/percona-server:9.7-dev PXB_IMAGE=localhost:5000/percona-xtrabackup:9.7 report

`tests/image/mysqlsh.bats` (3 tests, about 10 minutes, docker only): `mysqlsh --js` version, a three-member group
replication cluster on a dedicated network (`dba.configureInstance`, `createCluster('c')`, `addInstance` x2 with
`recoveryMethod: incremental` after `RESET BINARY LOGS AND GTIDS` on all members, so init GTIDs are not errant; clone is not used because mysqld is PID 1; asserts 3 ONLINE and that a write replicates), and `util.dumpInstance` into a volume plus
`util.loadDump` into a fresh server (row counts and CHECKSUM TABLE equal). Server flags: `--gtid-mode=ON
--enforce-gtid-consistency=ON --log-bin --log-replica-updates --binlog-format=ROW`, unique `--server-id`, `--report-host`,
`group_replication.so` loaded; the operator's exact flag set was not confirmed.

`tests/image/xtrabackup.bats` (6 tests, about 25-35 minutes): the xtrabackup container mounts the server's datadir volume
as uid 1001 and shares the server's network namespace (as the operator's sidecar does). Datadirs come from
`tests/fixtures/make-upgrade-datadir.sh` (InnoDB, RocksDB, keyring-encrypted table), so restored checksums are compared
with the fixture expectations: backup, prepare in a separate volume, copy-back into an empty volume, start the Wolfi server
(also `--stream=xbstream --compress=zstd` and `lz4` through extract, decompress, prepare; `xbcloud put/get` against the
digest-pinned `minio` tool image with credentials generated per run; and two cross tests: Wolfi xtrabackup on an
official server datadir, official xtrabackup on a Wolfi datadir, both prepare). The cross tests pull `official_ps_image`
and `official_pxb_image` from `versions/9.7.yaml` (~1 GB each) and pass `--no-server-version-check`. Needs the `minio`
tool image (`make tools-pull`). Resources are removed in teardown; leftovers show with `docker ps -a --filter name=psw-`.

Send back `make report` (logs `out/logs/test-mysqlsh-*.log`, `out/logs/test-xtrabackup-*.log`). Likely first
fixes on the host: the keyring-encrypted table needs `--component-keyring-config` (and possibly an `xtrabackup.my`
manifest next to the binary).
Helpers with unit tests: `tests/image/gr-lib.bash`, `tests/image/xb-lib.bash`, `tests/unit/gr-lib.bats`,
`tests/unit/xb-lib.bats`.

## MySQL Router (`percona-mysql-router`, `make test-router`)

The router is built by the `percona-server` recipe (subpackage `percona-mysql-router`, as in the RPM spec); its
`melange test` step checks `mysqlrouter --version`, that every router binary and plugin resolves its libraries
(bundled ones from `/usr/lib/mysqlrouter/private`) and `mysqlrouter_plugin_info`. The build log lists anything
router-named left in the server tree as `ROUTER-LEFTOVER`. The image adds the official entrypoint
(`percona-mysql-router-docker-scripts`, percona-docker `mysql-router/dockerdir` at `percona_docker_commit`) and mysqlsh.

    make test-router IMAGE=localhost:5000/percona-server:9.7-dev ROUTER_IMAGE=localhost:5000/percona-mysql-router:9.7 report

`tests/image/router.bats` (3 tests, about 10 minutes, docker only): versions and the tools the operator's router scripts
call (`python3`, `curl`, `mysqlrouter_passwd`), the entrypoint refusing to start without `MYSQL_*`, and a bootstrap
against a three-member InnoDB Cluster (built with the -dev image, `tests/image/gr-lib.bash` `gr_cluster`): 6446
reaches the primary, 6447 a secondary, a write through 6446 is read through 6447, 6447 refuses writes.

## PMM client (`pmm-client`, `make test-pmm-client`)

`packages/pmm-client` builds what PMM's `build/scripts/build-client-binary` (percona/pmm at `pmm_commit`, tag
v3.10.0) puts into the client tarball, each Go component at the commit of the release (`pmm_*` keys of the version
file: the gitlinks of Percona-Lab/pmm-submodules v3.10.0, and vmagent/nomad/redis_exporter from `build/scripts/vars`),
with the Go commands of each upstream Makefile target and the version stamps the official binaries print. One build,
twelve repositories (module downloads need the network; nomad is the largest, about 160 MB). Subpackages install
`/usr/local/percona/pmm` as `install_tarball` does (owner 1002:0). `pmm-client-tools` depends on `percona-toolkit`
(pt-summary, pt-mysql-summary): build that package first, or the `melange test` of `pmm-client` cannot resolve it.

    make pkg-pmm-client
    make test-pmm-client IMAGE=localhost:5000/percona-server:9.7-dev PMM_CLIENT_IMAGE=localhost:5000/pmm-client:3 report

`tests/image/pmm-client.bats` (5 tests, about 3 minutes, docker only): every binary's version; user 1002, working
directory, ownership of the layout and the tools the official Dockerfile copies (jq, tar, curl, sed, grep, awk, mysql,
perl); the entrypoint with `PMM_AGENT_SETUP=1` against an unreachable server (setup fails with "Failed to register
pmm-agent on PMM Server", no panic) and `pmm-admin status` without an agent; node_exporter, vmagent, postgres_exporter
and valkey_exporter serving `/metrics`; mysqld_exporter scraping a server started from the -dev image (`mysql_up 1`).
The same commands were checked against the official `percona/pmm-client:3.10.0`.

## Compatibility diff against the official image (`make test-compat`)

The official `percona/percona-server:9.7` (digest `official_ps_image` in `versions/9.7.yaml`) wins: every runtime
difference is a bug unless the owner approves an allowlist entry. `tests/compat/compare.sh` starts both images with the
same environment (`MYSQL_ROOT_PASSWORD`), collects `SHOW GLOBAL VARIABLES`, `SHOW PLUGINS`, `mysql.component`, a
`find` over `@@plugin_dir`, `docker inspect` Env, and Entrypoint/Cmd/User/ExposedPorts/Volumes/WorkingDir, then compares.
Collection (`collect.sh`, needs docker) is separate from the comparison (pure, unit-tested in `tests/unit/compat.bats`).

Run (needs the `-dev` image in the local docker and network access to pull the official image):

    docker pull "$(grep official_ps_image versions/9.7.yaml | cut -d'"' -f2)"
    make test-compat IMAGE=localhost:5000/percona-server:9.7-dev report

`OFFICIAL=<ref>` overrides the pinned official image. Output: `out/results/compat-<ts>.diff` (log in
`out/logs/test-compat-*.log`); set `COMPAT_KEEP_FIXTURES=1` to keep the raw fixtures next to it. Exit status is 1 when
any difference is not matched by `tests/compat/allowlist.yaml`.

Reading the diff: each unallowed difference is `<kind> <name>` followed by `-` (official) and `+` (ours) lines;
`<absent>` means the item exists on one side only. Lines starting `# allowed (reason)` are allowlisted differences.

Resolving: first fix the recipe/image so ours matches the official image. Where the difference is deliberate, do NOT
edit the allowlist yourself: send the diff (`make report`) to the owner with, per difference, the proposed entry
(`kind`, `name` exact or glob, `reason`; the reason is mandatory, the file is rejected without it). The owner approves,
then the entry goes into `allowlist.yaml`; `allowlist.yaml` already holds a commented "candidates for owner approval"
block for the documented deviations (`docs/deviations.md`, version skew R5) to uncomment once approved. Repeat until PASS.

## Supply chain: CVE gate, signing, SBOM attestation (`make scan sign verify-sign`)

Needs the images in the registry (`make images`, which also writes `out/results/<name>.digest` and the apko SBOMs
`out/images/<name>/sbom-*.spdx.json`), network for the vulnerability DBs, and the cosign key pair (`make keys`).

- `make scan` runs `scripts/cve-gate.sh <registry>/<repo>@<digest> vex/<image>.openvex.json` for each image
  (percona-server, percona-server-dev, percona-xtrabackup, percona-mysql-router). Both grype (`--fail-on high --vex`) and trivy
  (`--severity CRITICAL,HIGH --exit-code 1 --vex`) run; the gate fails when either finds a Critical/High not covered
  by the image's OpenVEX file. Reports: `out/results/cve-<image>-{grype,trivy}.json`. The scanners pull the image from
  the plain-HTTP registry (`--network host`, grype `GRYPE_REGISTRY_INSECURE_USE_HTTP`, trivy `--insecure`).
- The vulnerability DBs are cached in `out/cache/grype` and `out/cache/trivy` (override with `SCAN_CACHE`), so only
  the first scan downloads them; delete those directories to force a refresh. DB freshness changes results over
  time: re-run before every release.
- `make sign` signs every image (index digest) with `$KEY_DIR/cosign.key` (default `~/.config/ps-wolfi`; set
  `COSIGN_PASSWORD` if the key has a password) and attaches the apko SBOM as an `spdxjson` attestation. The key is
  only mounted read-only into the cosign container and never printed. Signatures are not uploaded to a transparency
  log: `keys/cosign-signing-config.json` is an empty cosign signing config, and verification uses
  `--insecure-ignore-tlog`. The registry is plain HTTP, hence `--allow-http-registry`.
- `make verify-sign` runs `cosign verify` and `cosign verify-attestation --type spdxjson` with `cosign.pub`.
- Then `make report`.

Triage of a Critical/High finding (the order matters):

1. Fixable by bumping the component or unbundling it (V8, protobuf, ICU, libevent, editline, fido): change the recipe
   flag or version, add a row to `docs/deviations.md`, rebuild the packages and images, and re-run the image tests
   (`make test-image test-upgrade test-mysqlsh test-xtrabackup test-router`), then scan again.
2. Genuinely not applicable (the vulnerable code is not reachable or not shipped): write an OpenVEX statement
   (`status: not_affected` with a `justification`) in `vex/<image>.openvex.json` as a draft, and **get the project
   owner's approval before committing it**. VEX is never used to silence a fixable finding. Keep the fixed
   `timestamp`; bump `version` and the statement timestamps only with the change.
3. Nothing is suppressed any other way: no scanner ignore lists, no lowered thresholds.

Hardening notes for the gate: the scanners run with config and ignore files disabled (grype gets an empty `--config`,
trivy `--config "" --ignorefile ""`), and `cve-gate.sh` refuses to run when `.grype.yaml`, `.trivyignore` or similar
exists in the repo. A scanner that exits 0 without a valid report (grype `matches`, trivy `SchemaVersion`) fails the
gate. Only `cosign.key` / `cosign.pub` are mounted into the cosign container. With the default `KEY_DIR`, `make keys`
copies `cosign.pub` to `keys/cosign.pub`: **commit it**; `sign.sh` refuses to run if the key dir's public key differs
from the committed one. `make verify-sign` keeps the `cosign verify` JSON in the log.

## First host run checklist

Work through this once, in order, on the first run on the build host. Each item names where it is explained.

Before and during phase A:

- [ ] `make tools-pull keys`; **commit `keys/ps-wolfi.rsa.pub` and `keys/cosign.pub`** (First run). Keep `~/.config/ps-wolfi`
  backed up: the private keys are not in the repo and `make keys` will not overwrite them.
- [ ] `make vendor-v8`; **paste `v8_src_sha256` into `versions/9.7.yaml`** (replaces `TODO-UNRESOLVED`) and commit (V8). If
  `gn gen` rejects the V8 build files, set `GN_BIN=buildtools/linux64/gn` in the recipe and add a row to
  `docs/deviations.md`.
- [ ] `LEAK_SCAN=warn make phase-a` (first run only; see "Build-path leak scan"), then the same without `LEAK_SCAN`
  once every reported leak is fixed or allow-listed. `make phase-a`: all packages built, `melange test` green, no `UNEXPECTED-PATH`, `BUILD-PATH LEAK` or `CMD-DEP`
  lines; the `SCRIPT (moved into percona-server-scripts)` lines of `pkg-percona-server-*.log` reviewed.
- [ ] Host checks of each component section recorded: `mysqld --version` says `Release 2, Revision 91438a04`; mysqlsh
  `NEEDED [libjitexecutor.so]` and the `--js print(1+1)` smoke test passed; xtrabackup file list vs the official image;
  generated `.PKGINFO` dependencies reviewed.
- [ ] `make verify-repro` prints only `OK` (including `v8-dev`); every `DIFF` explained by its diffoscope report and fixed.

Phase B:

- [ ] `make phase-b`; then **commit `images/*.lock.json`** created by the first `make images` (Images). Its
  `repro-images` step printed four `OK` lines.
- [ ] Hard pass/fail from the Images section: the edited `/etc/my.cnf` wins over the RPM copy (both commands print
  `PASS`); distroless build did not stop with a "must not contain" message.
- [ ] `make test-image test-upgrade test-mysqlsh test-xtrabackup test-router` green; no `ALL-SKIPPED` line; skipped upgrade cases (server refuses the jump)
  reviewed.
- [ ] `make test-compat` PASS. **Owner approval required** for every `tests/compat/allowlist.yaml` entry (including
  uncommenting the "candidates for owner approval" block).
- [ ] `make scan`: no Critical/High left. **Owner approval required** before committing any statement in
  `vex/*.openvex.json`; fixable findings are fixed, never VEX'd.
- [ ] `make sign verify-sign` pass (both the image signature and the `spdxjson` attestation).
- [ ] `make mtr-nightly` run once and triaged; **owner reviews every entry added to `tests/mtr/skip-<suite>.txt`**;
  real bugs get patches.
- [ ] `make report`, send `out/report-*.tar.gz` and the host commits back.

VERIFY-BEFORE-RELEASE (`docs/research.md` section 9):

- [ ] PS tag skew: look for a `Percona-Server-9.7.2-3` tag (official image is 9.7.2-3.1, pinned 9.7.2-2); if it exists,
  re-pin `ps_tag`, `ps_commit` and `source_date_epoch`, then rebuild everything and relock the images.
- [ ] Telemetry agent: confirm `rpm -q percona-telemetry-agent` in the official image (`telemetry_agent_version` 1.0.20 is
  inferred).
- [ ] JIT executor: the `mysqlsh --js` smoke test passed with `percona-mysql-shell-jit` (only in the `-dev` image).
- [ ] `v8_src_sha256` filled in (see above).
- [ ] Release builds: `RELEASE=1` (clean tree, lock files present), vulnerability DBs refreshed (delete `out/cache/grype`
  and `out/cache/trivy`), and the scan, sign and verify steps re-run on the final images.
