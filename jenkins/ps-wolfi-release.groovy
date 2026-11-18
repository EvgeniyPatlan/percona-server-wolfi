// ps-wolfi-release: full release build of the fifteen Wolfi images and their publication on Docker Hub.
// RELEASE=1 make all (packages twice for the reproducibility check, every image test suite, compat diff, CVE gate,
// signing), then jenkins/scripts/publish.sh: every tag as <tag>-wolfi on docker.io/<DOCKER_ORG>, digests unchanged,
// signatures and SBOM attestations verified there. See jenkins/README.md for the agent and the credentials.
// Parameters reach the shell steps as environment variables, never interpolated into the script text.

def cacheEntries = 'sources out/cache/git out/cache/ccache out/cache/gomodcache'

pipeline {
    agent {
        label "${params.AGENT_LABEL ?: 'ps-wolfi-x64'}"
    }
    parameters {
        string(name: 'GIT_REPO', defaultValue: 'https://github.com/EvgeniyPatlan/percona-server-wolfi.git',
            description: 'Repository to build')
        string(name: 'GIT_BRANCH', defaultValue: 'main', description: 'Branch or tag to build')
        choice(name: 'DOCKER_ORG', choices: ['perconalab', 'percona'], description: 'Docker Hub organisation to push to')
        booleanParam(name: 'PUBLISH', defaultValue: false,
            description: 'Push to Docker Hub after every gate passed (off: build, test, scan and sign only)')
        booleanParam(name: 'RELOCK', defaultValue: false,
            description: 'Re-resolve the image lock files instead of releasing: they are archived for a human to commit, nothing is published')
        string(name: 'AGENT_LABEL', defaultValue: 'ps-wolfi-x64',
            description: 'x86_64 agent: privileged docker, 300 GB disk (jenkins/README.md)')
        string(name: 'CACHE_URL', defaultValue: 's3://ps-build-cache/ps-wolfi', description: 'S3 prefix of the build caches')
    }
    options {
        skipDefaultCheckout()
        disableConcurrentBuilds()
        timestamps()
        timeout(time: 30, unit: 'HOURS')
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '10'))
    }
    environment {
        AWS_CREDENTIALS = 'AWS_CREDENTIALS_ID'
        DOCKER_HUB_CREDENTIALS = 'hub.docker.com'
    }
    stages {
        stage('Checkout') {
            steps {
                deleteDir()
                checkout([$class: 'GitSCM', branches: [[name: params.GIT_BRANCH]],
                    userRemoteConfigs: [[url: params.GIT_REPO]],
                    extensions: [[$class: 'CloneOption', shallow: false, noTags: false]]])
                sh 'git log -1 --format="%H %s"'
            }
        }
        stage('Preflight') {
            steps {
                // RELOCK reaches the script as the job parameter (true/false)
                sh 'jenkins/scripts/preflight.sh release'
            }
        }
        stage('Restore caches') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS,
                        accessKeyVariable: 'AWS_ACCESS_KEY_ID', secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                    sh 'CACHE_URL="$CACHE_URL/shared" jenkins/scripts/cache.sh restore ' + cacheEntries
                }
            }
        }
        stage('Keys') {
            steps {
                withCredentials([file(credentialsId: 'ps-wolfi-apk-key', variable: 'APK_KEY_FILE'),
                        file(credentialsId: 'ps-wolfi-cosign-key', variable: 'COSIGN_KEY_FILE'),
                        string(credentialsId: 'ps-wolfi-cosign-password', variable: 'COSIGN_PASSWORD')]) {
                    sh 'jenkins/scripts/install-keys.sh install release'
                }
            }
        }
        stage('Relock') {
            when { expression { params.RELOCK } }
            steps {
                sh 'make tools-pull phase-a REPRO=0 && make registry-up images-lock'
                archiveArtifacts artifacts: 'images/*.lock.json', fingerprint: true
            }
        }
        stage('Build, test, scan, sign') {
            when { expression { !params.RELOCK } }
            steps {
                withCredentials([string(credentialsId: 'ps-wolfi-cosign-password', variable: 'COSIGN_PASSWORD')]) {
                    // BUILD_ID would add a -<build number> tag to every image (scripts/apko-build.sh): not for releases.
                    sh 'unset BUILD_ID; make tools-pull && RELEASE=1 make all'
                }
            }
        }
        stage('Publish') {
            when { expression { params.PUBLISH && !params.RELOCK } }
            steps {
                withCredentials([usernamePassword(credentialsId: env.DOCKER_HUB_CREDENTIALS,
                        usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                    sh 'COSIGN_PUB=keys/cosign.pub jenkins/scripts/publish.sh "$DOCKER_ORG" -wolfi'
                }
            }
        }
        stage('Save caches') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: env.AWS_CREDENTIALS,
                        accessKeyVariable: 'AWS_ACCESS_KEY_ID', secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                    sh 'CACHE_URL="$CACHE_URL/shared" jenkins/scripts/cache.sh save ' + cacheEntries
                }
            }
        }
    }
    post {
        always {
            sh 'jenkins/scripts/install-keys.sh clean release || true'
            sh 'ls out/report-*.tar.gz > /dev/null 2>&1 || make report || true'
            archiveArtifacts artifacts: 'out/report-*.tar.gz, out/results/**', allowEmptyArchive: true
        }
    }
}
