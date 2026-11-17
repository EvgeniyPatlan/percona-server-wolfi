# percona-xtradb-cluster patches

Patches applied to the Percona XtraDB Cluster source tree (`pxc-src/`, the `pxc_tag` checkout incl. submodules)
before CMake runs, in `LC_ALL=C` glob order with `patch -p1` from the top of the tree. Same rules, naming and
header as `packages/percona-server/patches/README.md`.

PXC 9.7.2-2.1 is Percona Server 9.7.2-2 plus Galera/wsrep. The tree carries the same CMake files the percona-server
patches fix, and this recipe uses the same build choices (OpenSSL 3.6 headers, `WITH_CURL=bundled`), so `0001` and
`0002` are the percona-server patches with the paths of this tree; their `Error:` lines are from the first
percona-server build of the same 9.7.2-2 code. Patches for Galera (`percona-xtradb-cluster-galera/`) or wsrep-lib use
paths relative to `pxc-src/` too.
