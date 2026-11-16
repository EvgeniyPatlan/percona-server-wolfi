# percona-mysql-shell patches

Add one only for a concrete build or test failure seen on a build, never
pre-emptively. The recipe applies, in `LC_ALL=C` glob order with `patch -p1`:

- `patches/ps/*.patch` to the Percona Server tree (`ps-src/`, after Percona's own
  `build-ps/rpm/mysql-5.7-sharedlib-rename.patch`, which the recipe always applies with `-p0`);
- `patches/*.patch` to the mysql-shell source (`shell-src/`).

Naming (`NNNN-short-topic.patch`), the required header (`Subject`, `Error`, `Why`, `Upstream`,
`Drop-when`) and the commit rules are the same as in `packages/percona-server/patches/README.md`.

Known candidate (from Percona's builder, not applied): if CMake fails with "another target with the same
name already exists" for a `copy_<lib>` target in `cmake/exeutils.cmake`, Percona guards that
`add_custom_target` with `if(NOT TARGET "${COPY_TARGET}")` (`mysql-shell_builder.sh`, `sed` on exeutils.cmake).
