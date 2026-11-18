# Jenkins jobs

Three pipeline jobs, laid out like [Percona-Lab/jenkins-pipelines](https://github.com/Percona-Lab/jenkins-pipelines)
(a Jenkins Job Builder definition `<job>.yml` next to its declarative pipeline `<job>.groovy`), so they can move there
unchanged except for the SCM URL. The jobs only drive the repo's own `make` targets and scripts: every gate
(reproducibility, image suites, compat diff, CVE gate, cosign verify) is the same as on a build host.

| Job | Trigger | Runs | Publishes |
|---|---|---|---|
| `ps-wolfi-release` | by hand | `RELEASE=1 make all`, then `jenkins/scripts/publish.sh` | only with `PUBLISH`: `docker.io/<DOCKER_ORG>/<repo>:<tag>-wolfi` |
| `ps-wolfi-incremental` | GitHub push to `main` | `scripts/build.sh`, then the suites, CVE gate and signing of the images it rebuilt | `docker.io/perconalab/<repo>:<tag>-wolfi-ci` (and `<full version>-<build number>-wolfi-ci`) |
| `ps-wolfi-mtr-nightly` | nightly | `make mtr-nightly` on the packages of the last incremental build | never |

Every published tag ends in `-wolfi` (`publish.sh` refuses any other suffix), so the official images' tags are never
written. Images keep their digest on the way to Docker Hub (`oras copy -r` copies the image with its cosign signature
and SBOM attestation bundles); `publish.sh` verifies the local image before the copy and the pushed one after it:

    cosign verify --key keys/cosign.pub --insecure-ignore-tlog docker.io/percona/percona-server:9.7-wolfi
    cosign verify-attestation --type spdxjson --key keys/cosign.pub --insecure-ignore-tlog docker.io/percona/percona-server:9.7-wolfi

(The `-wolfi-ci` images verify with the CI public key instead; nothing is uploaded to the public Rekor log.)

## Setup

1. **Agent**: an EC2 cloud template (spot) with the label `ps-wolfi-x64` (each job's `AGENT_LABEL` parameter):
   x86_64, Docker that can run `--privileged` containers (melange), 300 GB disk, 16+ vCPU and 64 GB RAM for the
   release build, `make`, `git`, `curl`, `python3`. Every other tool runs as a digest-pinned container
   (`versions/tools.yaml`, `jenkins/tools.yaml`). A spot interruption fails the run; re-run it (the caches make the
   second attempt faster).
2. **Release keys**, once: `make keys` on a trusted machine, commit `keys/ps-wolfi.rsa.pub` and `keys/cosign.pub`, then
   store the private halves as credentials and keep an offline backup.
3. **CI keys**, once: `KEY_DIR=$HOME/ps-wolfi-ci-keys make keys` (any dir outside the repo; the apk key is named
   `ps-wolfi-dev`, nothing is committed), store them as credentials, then delete the dir.
4. **Credentials**:

   | ID | Kind | Content | Jobs |
   |---|---|---|---|
   | `ps-wolfi-apk-key` | Secret file | `ps-wolfi.rsa` (apk signing key) | release |
   | `ps-wolfi-cosign-key` | Secret file | `cosign.key` | release |
   | `ps-wolfi-cosign-password` | Secret text | its password | release |
   | `ps-wolfi-ci-apk-key` | Secret file | the CI `ps-wolfi-dev.rsa` | incremental, MTR |
   | `ps-wolfi-ci-cosign-key` | Secret file | the CI `cosign.key` | incremental, MTR |
   | `ps-wolfi-ci-cosign-password` | Secret text | its password | incremental, MTR |
   | `hub.docker.com` | Username with password | Docker Hub user and access token (Percona's existing one) | release, incremental |
   | `AWS_CREDENTIALS_ID` | AWS credentials | S3 access to `CACHE_URL` | all |

   `jenkins/scripts/install-keys.sh` writes the keys to a key dir outside the workspace (the release keys to the
   default `~/.config/ps-wolfi`, so `make` treats them as release keys), refuses to overwrite an existing dir, checks
   that the release keys match the committed public keys before anything is built, and removes the dir in `post`.
5. **Jobs**: `jenkins-jobs update jenkins/ps-wolfi-*.yml` (JJB), then a GitHub webhook to Jenkins for the
   incremental job's push trigger.
6. **First release**: `ps-wolfi-release` with `RELOCK` checked. It builds the packages, re-resolves the image lock
   files and archives them; commit `images/*.lock.json`, together with `v8_src_sha256` in `versions/9.7.yaml` if
   it is not pinned yet (`make vendor-v8` prints it). Then run it with `PUBLISH` unchecked (a full dry run: build,
   every gate, signing), and with `PUBLISH` checked to push. The preflight stage stops a release in seconds when a
   lock file, a public key or the V8 pin is missing, when the build inputs have uncommitted changes, or when the agent
   lacks disk or privileged Docker.

## Caches (S3)

`jenkins/scripts/cache.sh` keeps one `tar.zst` per directory under `CACHE_URL` (default `s3://ps-build-cache/ps-wolfi`):

| Prefix | Entries | Saved by | Restored by |
|---|---|---|---|
| `shared/` | `sources`, `out/cache/git`, `out/cache/ccache`, `out/cache/gomodcache` | release, incremental | release, incremental |
| `incremental/` | `out/repo`, `out/stamps`, `out/results`, `out/images`, `out/ci-locks` (generated lock files), the local registry volume | incremental | incremental, MTR (`out/repo`) |

A release never restores packages or images: it builds everything. Uploads go to `<object>.partial` and are renamed
only after tar and upload succeeded; a failed restore removes what it extracted. A cache problem is a warning, never a
failed build: every restored file is checked again by the build (tarball sha256, pinned commits, go.sum, apk
signatures). Set an S3 lifecycle rule on the prefix (e.g. 30 days) so unused caches expire.

## Checking the job files

    make lint            # shellcheck, including jenkins/scripts
    make lint-jenkins    # jenkins-jobs test on the .yml files, Jenkins' declarative validator on the .groovy files
    make test-unit       # tests/unit/jenkins.bats: the scripts with stubbed docker, curl and S3

`make lint-jenkins` starts a throwaway Jenkins (pinned in `jenkins/tools.yaml`) on 127.0.0.1:8099 and installs the
pipeline plugins on its first start, a few minutes; `KEEP=1` leaves it running for the next call.
