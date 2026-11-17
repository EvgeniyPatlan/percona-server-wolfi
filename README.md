# Percona Server for MySQL 9.7 on Wolfi

Builds Percona Server for MySQL 9.7 (with MySQL Router) and Percona XtraBackup 9.7 from source as Wolfi apk packages
(melange) and assembles four container images from them (apko). Not an official Percona image.

| Image | What it is |
|---|---|
| `percona-server:9.7` | Distroless: `ENTRYPOINT /usr/sbin/mysqld`, no shell, no package manager, no interpreters. |
| `percona-server:9.7-dev` | Drop-in replacement for the official `percona/percona-server:9.7`: same entrypoint script and environment-variable initialisation, plus MySQL Shell and the telemetry agent. |
| `percona-xtrabackup:9.7` | Drop-in replacement for the official `percona/percona-xtrabackup:9.7` (same entrypoint script), without garbd and the AWS/Azure CLIs (see `docs/deviations.md`). |
| `percona-mysql-router:9.7` | Drop-in replacement for the official `percona/percona-mysql-router:9.7`: MySQL Router with the same entrypoint (bootstrap from `MYSQL_HOST`/`MYSQL_PORT`/`MYSQL_USER`/`MYSQL_PASSWORD`) and MySQL Shell. |
| `percona-proxysql3:3.0` | Drop-in replacement for the official `percona/proxysql3:3.0.9-1.1` (PXC operator): ProxySQL 3.0.9 (Wolfi's `proxysql` package, same upstream release) with Percona's `proxysql-admin` tools, the same entrypoint and configuration, and the Percona Server client. |

## Packages

Built in this order (`PACKAGES` in `mk/packages.mk`); each recipe is `packages/<name>/melange.yaml.tmpl`.

| Package | Why it is here |
|---|---|
| `mecab`, `mecab-ipadic` | MeCab full-text parser plugin and its dictionary (not in Wolfi) |
| `v8` | V8 for the JavaScript stored-program component (`percona-server-js`) |
| `percona-server` | The server; subpackages `-server`, `-client`, `-libs`, `-rocksdb`, `-js`, `-scripts`, `-dev`, `-test`, `-icu-data-files`, and `percona-mysql-router` (MySQL Router, same source tree and build, as in the RPM) |
| `percona-mysql-shell` | MySQL Shell, `-dev` image only |
| `percona-xtrabackup` | XtraBackup (`xtrabackup`, `xbstream`, `xbcrypt`, `xbcloud`); subpackages `-test`, `-dbg` |
| `percona-telemetry-agent` | Percona telemetry agent, `-dev` image only (as in the official image) |
| `percona-server-docker-scripts` | Entrypoint script and image config from percona-docker; `percona-server-docker-config` (my.cnf) is used by both server images |
| `percona-xtrabackup-docker-scripts` | Entrypoint script of the XtraBackup image from percona-docker |
| `percona-mysql-router-docker-scripts` | Entrypoint script of the router image from percona-docker |
| `percona-proxysql-admin` | Percona's ProxySQL tools as in the `proxysql3` rpm: `proxysql-admin`, `proxysql-status`, `percona-scheduler-admin`, `pxc_scheduler_handler` (Go, built here), the galera checker scripts, `/etc/config.toml` |
| `percona-proxysql-docker-scripts` | Entrypoint, configuration and `add_*_nodes.sh` of the proxysql3 image from percona-docker; subpackage `percona-proxysql-my-print-defaults` (`my_print_defaults` alone, as the Dockerfile takes it from the server rpm) |

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
    scripts/build.sh                          # build what is needed for all four images
    scripts/build.sh percona-server           # only the distroless image and the packages it needs
    scripts/build.sh percona-xtrabackup       # only the XtraBackup image (and the server packages it links)
    scripts/build.sh percona-mysql-router     # only the router image (server build, mysqlsh, entrypoint)
    scripts/build.sh percona-proxysql3        # only the ProxySQL image (server client, admin tools, entrypoint)
    scripts/build.sh --dev-keys               # laptop: sign with ~/.config/ps-wolfi-dev
    scripts/build.sh -f                       # rebuild everything

It skips the reproducibility checks, tests, CVE gate and signing, and a commit alone triggers no rebuild, so releases
still go through `make all`.

Quick checks without docker builds: `make lint test-unit`.

Differences from the official image and from Percona's DEB/RPM builds, each with its reason: `docs/deviations.md`.
Design and its decisions: `docs/design.md`; pins and their sources: `docs/research.md`; what to build next (the rest
of the operator stacks): `docs/roadmap.md`.

## Running the images

The build publishes to the local registry; the examples use

    IMAGE=localhost:5000/percona-server

Always keep the data on a volume. The images do not declare `VOLUME` (apko cannot), so without `-v` the data lives
inside the container and is lost with it. The server runs as uid 1001, like the official image.

### `:9.7-dev`: same as the official image

Initialised from environment variables on the first start, exactly like `percona/percona-server:9.7`:

    docker run -d --name ps \
      -e MYSQL_ROOT_PASSWORD=secret \
      -v ps-data:/var/lib/mysql \
      -p 3306:3306 \
      $IMAGE:9.7-dev

    docker exec -it ps mysql -uroot -p          # or: mysql -h127.0.0.1 -P3306 -uroot -p from the host

Also supported as in the official image: `MYSQL_DATABASE`, `MYSQL_USER`/`MYSQL_PASSWORD`, `MYSQL_RANDOM_ROOT_PASSWORD`,
`MYSQL_ROOT_HOST`, scripts in `/docker-entrypoint-initdb.d`. MySQL Shell is included (`docker exec -it ps mysqlsh`).

### `:9.7`: distroless

The entrypoint is `mysqld` itself: there is no init script, so the datadir is initialised once, then the server is
started on it. Arguments after the image name go to `mysqld`.

1. Initialise the volume. `--init-file` sets the root password and creates users in the same step, so the server is
   never reachable with an empty password:

       cat > init.sql <<'EOF'
       ALTER USER 'root'@'localhost' IDENTIFIED BY 'secret';
       CREATE DATABASE appdb;
       CREATE USER 'app'@'%' IDENTIFIED BY 'apppass';
       GRANT ALL ON appdb.* TO 'app'@'%';
       EOF

       docker run --rm \
         -v ps-data:/var/lib/mysql \
         -v "$PWD/init.sql:/init.sql:ro" \
         $IMAGE:9.7 --initialize-insecure --init-file=/init.sql

2. Start the server on it (here with a read-only root filesystem; the two tmpfs mounts are the only other places
   mysqld writes to, and must be owned by uid 1001):

       docker run -d --name ps \
         --read-only \
         --tmpfs /tmp:uid=1001,gid=0,mode=1777 \
         --tmpfs /run/mysqld:uid=1001,gid=0,mode=0775 \
         -v ps-data:/var/lib/mysql \
         -p 3306:3306 \
         $IMAGE:9.7

3. Connect. The image has the `mysql` client but no shell:

       docker exec -it ps mysql -uroot -p
       mysql -h127.0.0.1 -P3306 -uapp -papppass appdb        # from the host

An existing datadir (for example one created by `:9.7-dev` or by the official image) needs no step 1.

### Configuration, logs, ports

- Server options: append them to the command (`$IMAGE:9.7 --max-connections=500`; for `:9.7-dev` after the image name
  too) or mount a file into `/etc/my.cnf.d/`: `-v "$PWD/my.cnf:/etc/my.cnf.d/zz-local.cnf:ro"`.
- Logs go to stderr: `docker logs ps`.
- Ports: 3306 (classic) and 33060 (X protocol). They are not declared in the image, so `docker run -P` publishes
  nothing; use `-p 3306:3306 [-p 33060:33060]`.

### Host folder instead of a named volume

A named volume takes the owner of `/var/lib/mysql` from the image. A host folder has to be writable by uid 1001 first
(the same applies to the official image):

    sudo mkdir -p /srv/mysql && sudo chown 1001:0 /srv/mysql
    docker run ... -v /srv/mysql:/var/lib/mysql ...

### Kubernetes

Mount the PVC at `/var/lib/mysql` and run as the image user:

    securityContext:
      runAsUser: 1001
      runAsNonRoot: true
      fsGroup: 1001

For the Percona Operator for MySQL use `:9.7-dev` (the operator calls `mysqlsh` and the entrypoint).

### `percona-xtrabackup:9.7`: backup and restore

    XB=localhost:5000/percona-xtrabackup:9.7

The XtraBackup container needs the server's datadir and its network (as the operator's sidecar has); it runs as uid
1001 like the server. With the server from above running as `ps`:

    # full backup into the volume ps-backup, then prepare it
    docker run --rm --volumes-from ps --network container:ps -v ps-backup:/backup $XB \
      xtrabackup --backup --target-dir=/backup/full --user=root --password=secret --host=127.0.0.1
    docker run --rm -v ps-backup:/backup $XB xtrabackup --prepare --target-dir=/backup/full

    # restore into a new volume (owned by uid 1001 first: the image has no /var/lib/mysql to take the owner from)
    docker run --rm --user 0 -v ps-restored:/var/lib/mysql --entrypoint chown $XB 1001:0 /var/lib/mysql
    docker run --rm -v ps-backup:/backup -v ps-restored:/var/lib/mysql $XB \
      xtrabackup --copy-back --target-dir=/backup/full --datadir=/var/lib/mysql
    docker run -d --name ps-restored -v ps-restored:/var/lib/mysql $IMAGE:9.7

Streamed and compressed (`--target-dir` is still required with `--stream`):

    docker run --rm --volumes-from ps --network container:ps -v ps-backup:/backup $XB sh -c \
      'xtrabackup --backup --stream=xbstream --compress=zstd --target-dir=/tmp \
         --user=root --password=secret --host=127.0.0.1 > /backup/full.xbs'
    docker run --rm -v ps-backup:/backup $XB sh -c 'mkdir /backup/x && xbstream -x -C /backup/x < /backup/full.xbs &&
      xtrabackup --decompress --remove-original --target-dir=/backup/x && xtrabackup --prepare --target-dir=/backup/x'

`xbcloud` (in the image) puts and gets backups on S3, GCS and Azure directly; the operator uses it that way.

### `percona-mysql-router:9.7`: MySQL Router

    ROUTER=localhost:5000/percona-mysql-router:9.7

The entrypoint is the official one: it bootstraps against an InnoDB Cluster member given by `MYSQL_HOST`, `MYSQL_PORT`,
`MYSQL_USER`, `MYSQL_PASSWORD` (all four are required), then starts `mysqlrouter` with the generated configuration.
With a cluster on the docker network `db` (members reachable by name, `n1` one of them):

    docker run -d --name router --network db \
      -e MYSQL_HOST=n1 -e MYSQL_PORT=3306 -e MYSQL_USER=root -e MYSQL_PASSWORD=secret \
      -p 6446:6446 -p 6447:6447 \
      $ROUTER

    mysql -h127.0.0.1 -P6446 -uroot -p     # read-write: the primary
    mysql -h127.0.0.1 -P6447 -uroot -p     # read-only: a secondary

The image also has MySQL Shell (`docker exec -it router mysqlsh`), `python3` and `curl`, which the Percona Operator's
router scripts use. A cluster can be created from the `:9.7-dev` image with `mysqlsh` (`dba.createCluster`).

### `percona-proxysql3:3.0`: ProxySQL

    PROXYSQL=localhost:5000/percona-proxysql3:3.0

The entrypoint is the official one: it writes `PROXY_ADMIN_USER`/`PROXY_ADMIN_PASSWORD`, `MONITOR_PASSWORD`,
`OPERATOR_USERNAME`/`OPERATOR_PASSWORD` into `/etc/proxysql/proxysql.cnf` and `/etc/proxysql-admin.cnf`, then starts
`proxysql -f -c /etc/proxysql/proxysql.cnf --reload`. Clients connect on 3306 (and 33062), the admin interface is 6032
(the `admin` user may only connect from inside the container):

    docker run -d --name proxysql --network db -e PROXY_ADMIN_PASSWORD=secret -p 3306:3306 $PROXYSQL
    docker exec -e MYSQL_PWD=secret proxysql mysql -h127.0.0.1 -P6032 -uadmin \
      -e "INSERT INTO mysql_servers (hostgroup_id, hostname, port, use_ssl) VALUES (0, 'db1', 3306, 1);
          INSERT INTO mysql_users (username, password, default_hostgroup) VALUES ('app', 'apppw', 0);
          LOAD MYSQL SERVERS TO RUNTIME; LOAD MYSQL USERS TO RUNTIME"
    mysql -h127.0.0.1 -P3306 -uapp -papppw

With a PXC cluster, `proxysql-admin` (and the operator's `add_pxc_nodes.sh`) configures the hostgroups instead.

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

XtraBackup: the official `percona/percona-xtrabackup:9.7` (9.7.2-2.1) is 1.54 GB on disk / 464 MB to download; the
Wolfi `percona-xtrabackup:9.7` (9.7.2-2, same release) is 275 MB / 94 MB. A third of the official size is the Azure
CLI (500 MB); it also ships the AWS CLI and garbd, which the Wolfi image does not (`docs/deviations.md`).
CVEs (2026-11-16, same scanners and rules): official 551 (grype) / 570 (trivy), with 3 / 2 Critical and 48 / 58 High,
in the RHEL 9.8 base (krb5-libs, sqlite-libs, util-linux, expat) and the Azure CLI's Python packages (PyJWT,
cryptography, certifi); Wolfi 0 / 0.

MySQL Router: the official `percona/percona-mysql-router:9.7` (9.7.2-3.1) is 1.20 GB on disk / 315 MB to download in 7
layers; the Wolfi `percona-mysql-router:9.7` (9.7.2-2) is 444 MB / 165 MB in one layer, both with MySQL Shell. CVEs:
official 712 (grype) / 720 (trivy), 25 High, none Critical, again in the RHEL base (krb5-libs, sqlite-libs, expat,
json-glib, vim, pip); Wolfi 0 / 0.

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
