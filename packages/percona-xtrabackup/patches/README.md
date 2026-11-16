# percona-xtrabackup patches

Patches applied to the Percona XtraBackup source tree (`xb-src/`, the `pxb_tag` checkout incl. the
`extra/libkmip` submodule) before CMake runs. The recipe applies every `*.patch` here in `LC_ALL=C` glob
order with `patch -p1`, from the top of the source tree. None are needed yet: add one only for a concrete
build or test failure seen on the build host (typically GCC 15 / glibc 2.4x breaks), never pre-emptively.
XtraBackup carries a full MySQL server tree, so a fix already made for `packages/percona-server/patches/`
often applies here unchanged (check the paths first).

## Naming

`NNNN-short-topic.patch`, e.g. `0001-xbcloud-missing-cstdint.patch`. Numbers fix the order.

## Required header

Each patch starts with a free-text header above the first `---`/`diff` line (`patch` ignores it):

    Subject: <one line: what the patch changes>
    Error: <the exact compiler/linker/test error text, trimmed to the relevant lines>
    Why: <root cause, and why a patch rather than a flag>
    Upstream: <link to the upstream fix/commit/bug, or "none found (searched <where>)">
    Drop-when: <condition that makes it obsolete, e.g. "pxb_tag >= percona-xtrabackup-9.7.3-x">

Each patch gets its own commit (`fix: <topic>`) and, if it changes behaviour rather than just making
the build work, a row in `docs/deviations.md`.
