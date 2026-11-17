# Roadmap: MySQL-family components still to build on Wolfi

Status on 2026-11-16. Sources: the `percona` organisation on Docker Hub (51 repositories), the default images of
`percona-server-mysql-operator` and `percona-xtradb-cluster-operator` (`deploy/cr.yaml`), and the Dockerfiles in
`percona/percona-docker`.

Wolfi itself ships `percona-server-8.4` (8.4.2), `percona-server-9.1`, `percona-xtrabackup-8.4` (8.4.0) and `proxysql`
3.0.9. All but ProxySQL are far behind 9.7, so they are not a base for this work.

Done in this repository: Percona Server 9.7 (`percona-server`, plus `v8`, `mecab`, `mecab-ipadic`), MySQL Shell,
the telemetry agent and the docker scripts; Percona XtraBackup 9.7 (item 1); MySQL Router 9.7 (item 2); Percona Binlog Server 0.4.1 (item 6); images `percona-server:9.7`,
`percona-server:9.7-dev`, `percona-xtrabackup:9.7`, `percona-mysql-router:9.7` and `percona-binlog-server:0.4`.

## Components to create

Effort is a rough estimate (S, M, L).

| # | Component | Used by | Package to build | Image | Wolfi today | Effort |
|---|---|---|---|---|---|---|
| 1 | ~~Percona XtraBackup 9.7~~ **done** | PS operator backups, PXC | `percona-xtrabackup`, `percona-xtrabackup-docker-scripts` | `percona-xtrabackup:9.7` (no garbd, no AWS/Azure CLIs: not used by the PS operator) | 8.4.0 only | S |
| 2 | ~~MySQL Router 9.7~~ **done** | PS operator (group replication routing) | `percona-mysql-router`, a subpackage of the `percona-server` recipe (same source tree), and `percona-mysql-router-docker-scripts` | `percona-mysql-router:9.7` (router, mysqlsh with the jit library by owner ruling, entrypoint) | none | S-M |
| 3 | Orchestrator | PS operator (async replication) | `percona-orchestrator`, `percona-orchestrator-client` (Go, `percona/orchestrator`) | `percona-orchestrator` | none | M |
| 4 | HAProxy, operator flavour | PS and PXC operators | Wolfi `haproxy-3.x` instead of Percona's `percona-haproxy` rpm, plus the operator check scripts | `haproxy` | haproxy 3.2/3.3 | S |
| 5 | Percona Toolkit | PS and PXC operators (toolkit image, pt-heartbeat, ...) | `percona-toolkit` (Perl) and `perl-DBD-mysql` against `percona-server-libs` | `percona-toolkit` | neither | M |
| 6 | ~~Percona Binlog Server~~ **done** | PS operator (binlog storage, PITR) | `percona-binlog-server` (C++, 0.4.1, with Boost 1.90 and the AWS SDK 1.11.774 static), `percona-binlog-server-docker-scripts` | `percona-binlog-server:0.4` | none | M |
| 7 | Log collector | both operators | Wolfi `fluent-bit` and `supercronic`, PS client, logrotate | `fluentbit` (logcollector) | fluent-bit, supercronic | S |
| 8 | Operator binaries | both operators | `percona-server-mysql-operator`, `percona-xtradb-cluster-operator` (Go) | operator images | none (only the MongoDB operator) | S each |
| 9 | Percona XtraDB Cluster 9.7 | PXC operator | `percona-xtradb-cluster` with Galera (`galera`, `garbd`) | `percona-xtradb-cluster:9.7`, `-backup` | none | L |
| 10 | ProxySQL, Percona flavour | PXC operator | Wolfi `proxysql` 3.0.9 compared with Percona's `proxysql3` 3.0.9-1.1, plus the `proxysql-admin` tools | `proxysql3` | proxysql 3.0.9 | S-M |
| 11 | PMM client | sidecar in every operator | `pmm-client`: pmm-agent, vmagent and the exporters (Go, several repositories) | `pmm-client:3` | none | L |

## Third-party pieces Wolfi does not have

| Needed by | Piece | Notes |
|---|---|---|
| Toolkit, ProxySQL tools | `perl-DBD-mysql` | Perl MySQL driver, built against `percona-server-libs` |
| Router image (arbitrary uid on OpenShift) | `nss_wrapper` | small C library |
| XtraBackup image | `garbd` | comes with item 9; until then the XtraBackup image lacks it (the official one ships it) |
| `validate_password` dictionary | `cracklib-dicts` | listed in `docs/deviations.md` |

Already in Wolfi: `socat`, `jq`, `qpress`, `pv`, `libev`, `lz4`, `zstd`, `aws-cli-2`, `az` (Azure CLI),
`boost-program_options`, `supercronic`, `iproute2`, `bind-tools`, `netcat-openbsd`, `gdb`, `strace`, `tcpdump`.

## Order

1. ~~XtraBackup~~ (done): the images cover PS operator backups.
2. ~~MySQL Router~~ (done): a subpackage of the existing server build.
3. HAProxy, the log collector and the operator binaries: mostly Wolfi packages plus scripts.
4. Orchestrator, Toolkit (with DBD::mysql) and Binlog Server: the whole PS operator stack on Wolfi.
5. PXC with Galera and garbd, then ProxySQL: the PXC operator stack.
6. PMM client: the largest item, shared with the MongoDB and PostgreSQL stacks.

## Out of scope for now

Other Percona families with images: MongoDB (server, operator, PBM, clustersync, search, `mongodb_exporter`),
PostgreSQL (distribution 11-18, pgBackRest, PgBouncer, PostGIS, pgAdmin, upgrade, operator), PMM server, Valkey and
its modules, Everest.
