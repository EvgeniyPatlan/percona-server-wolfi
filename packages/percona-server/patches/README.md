# percona-server patches

Patches applied to the Percona Server source tree (`ps-src/`, the `ps_tag` checkout incl. submodules)
before CMake runs. The recipe applies every `*.patch` here in `LC_ALL=C` glob order with `patch -p1`,
from the top of the source tree. Add one only for a concrete build or test failure
seen on the build host (typically GCC 15 / glibc 2.4x breaks), never pre-emptively.

## Naming

`NNNN-short-topic.patch`, e.g. `0001-rocksdb-missing-cstdint.patch`. Numbers fix the order.

## Required header

Each patch starts with a free-text header above the first `---`/`diff` line (`patch` ignores it):

    Subject: <one line: what the patch changes>
    Error: <the exact compiler/linker/test error text, trimmed to the relevant lines>
    Why: <root cause, and why a patch rather than a flag>
    Upstream: <link to the upstream fix/commit/bug, or "none found (searched <where>)">
    Drop-when: <condition that makes it obsolete, e.g. "ps_tag >= Percona-Server-9.7.3-x">

Patches under submodules (`storage/rocksdb/rocksdb/`, `extra/coredumper/`, `extra/libkmip/`,
`extra/jwt-cpp/`) use paths relative to `ps-src/` too.

Each patch gets its own commit (`fix: <topic>`) and, if it changes behaviour rather than just making
the build work, a row in `docs/deviations.md`.
