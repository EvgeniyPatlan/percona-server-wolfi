# Roadmap: MySQL-family components still to build on Wolfi

Status on 2026-11-16. Sources: the `percona` organisation on Docker Hub (51 repositories), the default images of
`percona-server-mysql-operator` and `percona-xtradb-cluster-operator` (`deploy/cr.yaml`), and the Dockerfiles in
`percona/percona-docker`.

Wolfi itself ships `percona-server-8.4` (8.4.2), `percona-server-9.1`, `percona-xtrabackup-8.4` (8.4.0) and `proxysql`
3.0.9. All but ProxySQL are far behind 9.7, so they are not a base for this work.

Done in this repository: Percona Server 9.7 (`percona-server`, plus `v8`, `mecab`, `mecab-ipadic`), MySQL Shell,
the telemetry agent and the docker scripts; Percona XtraBackup 9.7 (item 1); MySQL Router 9.7 (item 2); Orchestrator 3.2.6 (item 3); HAProxy (item 4); Percona Toolkit 3.7.1 (item 5); Percona Binlog Server 0.4.1 (item 6); the log collector (item 7); the operator images (item 8: `percona-server-mysql-operator` 1.3.0, `percona-xtradb-cluster-operator` 1.20.0); Percona XtraDB
Cluster 9.7 with Galera and garbd (item 9); PMM client 3.10.0 (item 11); images `percona-server:9.7`,
`percona-server:9.7-dev`, `percona-xtrabackup:9.7`, `percona-mysql-router:9.7`, `percona-orchestrator:3.2.6`, `percona-haproxy:3.4`, `percona-binlog-server:0.4`, `percona-toolkit:3.7`, `percona-fluentbit:5.0`, `percona-xtradb-cluster:9.7`, `percona-xtradb-cluster-backup:9.7` and `pmm-client:3`. ProxySQL (item 10): `percona-proxysql-admin`, `percona-proxysql-docker-scripts` and image `percona-proxysql3:3.0` (ProxySQL itself from Wolfi).

## Components to create

Effort is a rough estimate (S, M, L).

| # | Component | Used by | Package to build | Image | Wolfi today | Effort |
|---|---|---|---|---|---|---|
| 1 | ~~Percona XtraBackup 9.7~~ **done** | PS operator backups, PXC | `percona-xtrabackup`, `percona-xtrabackup-docker-scripts` | `percona-xtrabackup:9.7` (no garbd, no AWS/Azure CLIs: not used by the PS operator) | 8.4.0 only | S |
| 2 | ~~MySQL Router 9.7~~ **done** | PS operator (group replication routing) | `percona-mysql-router`, a subpackage of the `percona-server` recipe (same source tree), and `percona-mysql-router-docker-scripts` | `percona-mysql-router:9.7` (router, mysqlsh with the jit library by owner ruling, entrypoint) | none | S-M |
| 3 | ~~Orchestrator~~ **done** | PS operator (async replication) | `percona-orchestrator`, `percona-orchestrator-client` (Go, `percona/orchestrator`), `percona-orchestrator-docker-scripts` | `percona-orchestrator:3.2.6` | none | M |
| 4 | ~~HAProxy, operator flavour~~ **done** | PS and PXC operators | Wolfi `haproxy-3.4-nocaps` (3.4.7, as the official image) instead of Percona's `percona-haproxy` rpm, plus `percona-haproxy-docker-scripts` | `percona-haproxy:3.4` | haproxy 3.2/3.3/3.4 | S |
| 5 | ~~Percona Toolkit~~ **done** | PS and PXC operators (toolkit image, pt-heartbeat, ...) | `percona-toolkit` (Perl and Go tools) and `perl-dbd-mysql` against `percona-server-dev`/`-libs` | `percona-toolkit:3.7` | neither | M |
| 6 | ~~Percona Binlog Server~~ **done** | PS operator (binlog storage, PITR) | `percona-binlog-server` (C++, 0.4.1, with Boost 1.90 and the AWS SDK 1.11.774 static), `percona-binlog-server-docker-scripts` | `percona-binlog-server:0.4` | none | M |
| 7 | ~~Log collector~~ **done** | both operators | Wolfi `fluent-bit-5.0` and `supercronic`, PS client, logrotate, `percona-fluentbit-docker-scripts` | `percona-fluentbit:5.0` | fluent-bit (up to 5.0), supercronic | S |
| 8 | ~~Operator binaries~~ **done** | both operators | `percona-server-mysql-operator`, `percona-xtradb-cluster-operator` (Go) | operator images | none (only the MongoDB operator) | S each |
| 9 | ~~Percona XtraDB Cluster 9.7~~ **done** | PXC operator | `percona-xtradb-cluster` with Galera (`galera`, `garbd`) | `percona-xtradb-cluster:9.7`, `-backup` | none | L |
| 10 | ~~ProxySQL, Percona flavour~~ **done** | PXC operator | Wolfi `proxysql` 3.0.9 compared with Percona's `proxysql3` 3.0.9-1.1, plus the `proxysql-admin` tools | `proxysql3` | proxysql 3.0.9 | S-M |
| 11 | ~~PMM client~~ **done** | sidecar in every operator | `pmm-client` (pmm-agent, pmm-admin) with one subpackage per repository: vmagent, the seven exporters, valkey_exporter, nomad, the toolkit summaries (Go, 3.10.0) | `pmm-client:3` | none | L |

## Third-party pieces Wolfi does not have

| Needed by | Piece | Notes |
|---|---|---|
| Toolkit, ProxySQL tools | `perl-DBD-mysql` | Perl MySQL driver, built against `percona-server-libs` |
| Router image (arbitrary uid on OpenShift) | `nss_wrapper` | small C library |
| XtraBackup image | `garbd` | done: `percona-xtradb-cluster-garbd` (item 9) is in the XtraBackup image too |
| `validate_password` dictionary | `cracklib-dicts` | listed in `docs/deviations.md` |

Already in Wolfi: `socat`, `jq`, `qpress`, `pv`, `libev`, `lz4`, `zstd`, `aws-cli-2`, `az` (Azure CLI),
`boost-program_options`, `supercronic`, `iproute2`, `bind-tools`, `netcat-openbsd`, `gdb`, `strace`, `tcpdump`.

## Order

1. ~~XtraBackup~~ (done): the images cover PS operator backups.
2. ~~MySQL Router~~ (done): a subpackage of the existing server build.
3. ~~HAProxy, the log collector~~ (done) and the operator binaries: mostly Wolfi packages plus scripts.
4. Orchestrator, Toolkit (with DBD::mysql) and Binlog Server: the whole PS operator stack on Wolfi.
5. PXC with Galera and garbd, then ProxySQL: the PXC operator stack.
6. PMM client: the largest item, shared with the MongoDB and PostgreSQL stacks.

## Out of scope for now

Other Percona families with images: MongoDB (server, operator, PBM, clustersync, search, `mongodb_exporter`),
PostgreSQL (distribution 11-18, pgBackRest, PgBouncer, PostGIS, pgAdmin, upgrade, operator), PMM server, Valkey and
its modules, Everest.
