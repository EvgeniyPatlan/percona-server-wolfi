// ps-wolfi-mtr-nightly: the upstream MTR suites (make mtr-nightly) against the packages of the last successful
// incremental build (out/repo from the S3 cache, signed with the CI key). Report only: never publishes anything.
// See jenkins/README.md.

pipeline {
    agent {
        label "${params.AGENT_LABEL ?: 'ps-wolfi-x64'}"
    }
    parameters {
        string(name: 'GIT_REPO', defaultValue: 'https://github.com/EvgeniyPatlan/percona-server-wolfi.git',
            description: 'Repository (for the MTR skip lists and scripts)')
        string(name: 'GIT_BRANCH', defaultValue: 'main', description: 'Branch')
        string(name: 'SUITES', defaultValue: 'main,innodb,rocksdb,sys_vars,audit_log_filter,component_keyring_file',
            description: 'MTR suites, comma separated')
        string(name: 'AGENT_LABEL', defaultValue: 'ps-wolfi-x64', description: 'x86_64 agent (jenkins/README.md)')
        string(name: 'CACHE_URL', defaultValue: 's3://ps-build-cache/ps-wolfi', description: 'S3 prefix of the build caches')
    }
    options {
        skipDefaultCheckout()
        disableConcurrentBuilds()
        timestamps()
        timeout(time: 12, unit: 'HOURS')
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '30'))
    }
    environment {
        KEY_DIR = "${env.HOME}/.config/ps-wolfi-ci"
    }
    stages {
        stage('Checkout') {
            steps {
                deleteDir()
                checkout([$class: 'GitSCM', branches: [[name: params.GIT_BRANCH]],
                    userRemoteConfigs: [[url: params.GIT_REPO]],
                    extensions: [[$class: 'CloneOption', shallow: false, noTags: false]]])
            }
        }
        stage('Preflight') {
            steps {
                sh 'jenkins/scripts/preflight.sh mtr'
            }
        }
        stage('Restore packages') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'AWS_CREDENTIALS_ID',
                        accessKeyVariable: 'AWS_ACCESS_KEY_ID', secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']]) {
                    sh 'CACHE_URL="$CACHE_URL/incremental" jenkins/scripts/cache.sh restore out/repo'
                }
                sh 'test -f out/repo/x86_64/APKINDEX.tar.gz || { echo "no cached out/repo: run ps-wolfi-incremental first" >&2; exit 1; }'
            }
        }
        stage('Keys') {
            steps {
                // only the public half is used (to trust out/repo); install-keys.sh derives it from the CI key
                withCredentials([file(credentialsId: 'ps-wolfi-ci-apk-key', variable: 'APK_KEY_FILE'),
                        file(credentialsId: 'ps-wolfi-ci-cosign-key', variable: 'COSIGN_KEY_FILE'),
                        string(credentialsId: 'ps-wolfi-ci-cosign-password', variable: 'COSIGN_PASSWORD')]) {
                    sh 'jenkins/scripts/install-keys.sh install ci'
                }
            }
        }
        stage('MTR') {
            steps {
                script {
                    if (!(params.SUITES ==~ /[a-z0-9_]+(,[a-z0-9_]+)*/)) {
                        error "SUITES must be a comma separated list of suite names, got '${params.SUITES}'"
                    }
                }
                sh 'make tools-pull && make mtr-nightly SUITES="$SUITES"'
            }
        }
    }
    post {
        always {
            sh 'jenkins/scripts/install-keys.sh clean ci || true'
            archiveArtifacts artifacts: 'out/results/mtr-*.txt, out/logs/mtr-nightly-*.log', allowEmptyArchive: true
        }
    }
}
