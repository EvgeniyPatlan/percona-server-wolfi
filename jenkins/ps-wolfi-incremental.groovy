// ps-wolfi-incremental: on every push, rebuild only what changed (scripts/build.sh), then run the test suites, the
// CVE gate and signing of the images it rebuilt, and push those to docker.io/perconalab as <tag>-wolfi-ci (plus
// <full version>-<build number>-wolfi-ci). Signed with the CI key pair, never the release keys. The package repo,
// stamps, digests, generated lock files and the local registry are cached in S3 between ephemeral agents, so
// build.sh's plan sees the state of the last successful run. See jenkins/README.md.

def sharedEntries = 'sources out/cache/git out/cache/ccache out/cache/gomodcache'
def stateEntries = 'out/repo out/stamps out/results out/images out/ci-locks volume:ps-wolfi-registry'
def awsBinding = { -> [[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'AWS_CREDENTIALS_ID',
    accessKeyVariable: 'AWS_ACCESS_KEY_ID', secretKeyVariable: 'AWS_SECRET_ACCESS_KEY']] }

pipeline {
    agent {
        label "${params.AGENT_LABEL ?: 'ps-wolfi-x64'}"
    }
    parameters {
        string(name: 'GIT_REPO', defaultValue: 'https://github.com/EvgeniyPatlan/percona-server-wolfi.git',
            description: 'Repository to build')
        string(name: 'GIT_BRANCH', defaultValue: 'main', description: 'Branch to build')
        booleanParam(name: 'PUBLISH', defaultValue: true,
            description: 'Push the rebuilt images to docker.io/perconalab as -wolfi-ci tags')
        string(name: 'AGENT_LABEL', defaultValue: 'ps-wolfi-x64',
            description: 'x86_64 agent: privileged docker, 300 GB disk (jenkins/README.md)')
        string(name: 'CACHE_URL', defaultValue: 's3://ps-build-cache/ps-wolfi', description: 'S3 prefix of the build caches')
    }
    options {
        skipDefaultCheckout()
        disableConcurrentBuilds()
        timestamps()
        timeout(time: 8, unit: 'HOURS')
        buildDiscarder(logRotator(numToKeepStr: '50', artifactNumToKeepStr: '10'))
    }
    environment {
        // the CI key dir: apk key name ps-wolfi-dev, cosign.pub next to it (jenkins/scripts/install-keys.sh)
        KEY_DIR = "${env.HOME}/.config/ps-wolfi-ci"
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
                sh 'jenkins/scripts/preflight.sh incremental'
            }
        }
        stage('Restore caches') {
            steps {
                withCredentials(awsBinding()) {
                    sh 'CACHE_URL="$CACHE_URL/shared" jenkins/scripts/cache.sh restore ' + sharedEntries
                    sh 'CACHE_URL="$CACHE_URL/incremental" jenkins/scripts/cache.sh restore ' + stateEntries
                    sh 'jenkins/scripts/locks.sh unstash'
                }
            }
        }
        stage('Keys') {
            steps {
                withCredentials([file(credentialsId: 'ps-wolfi-ci-apk-key', variable: 'APK_KEY_FILE'),
                        file(credentialsId: 'ps-wolfi-ci-cosign-key', variable: 'COSIGN_KEY_FILE'),
                        string(credentialsId: 'ps-wolfi-ci-cosign-password', variable: 'COSIGN_PASSWORD')]) {
                    sh 'jenkins/scripts/install-keys.sh install ci'
                }
            }
        }
        stage('Plan') {
            steps {
                sh '''
                    make tools-pull registry-up
                    scripts/build.sh -n | tee out/ci-plan.txt
                    jenkins/scripts/changed.sh images < out/ci-plan.txt > out/ci-changed.txt
                '''
                script {
                    env.CHANGED = readFile('out/ci-changed.txt').trim().replaceAll('\\s+', ' ')
                    echo "images to rebuild: ${env.CHANGED ?: 'none'}"
                }
            }
        }
        stage('Build') {
            when { expression { env.CHANGED } }
            steps {
                // BUILD_ID (the Jenkins build number) adds a <full version>-<n> tag to each rebuilt image
                sh 'scripts/build.sh'
            }
        }
        stage('Test') {
            when { expression { env.CHANGED } }
            steps {
                sh '''
                    for t in $(jenkins/scripts/changed.sh tests $CHANGED); do
                        make "$t"
                    done
                '''
            }
        }
        stage('Scan and sign') {
            when { expression { env.CHANGED } }
            steps {
                withCredentials([string(credentialsId: 'ps-wolfi-ci-cosign-password', variable: 'COSIGN_PASSWORD')]) {
                    sh '''
                        rc=0
                        for i in $CHANGED; do make "scan-$i" || rc=1; done
                        [ "$rc" = 0 ]
                        for i in $CHANGED; do scripts/sign.sh sign "$i" && scripts/sign.sh verify "$i"; done
                    '''
                }
            }
        }
        stage('Publish') {
            when { expression { env.CHANGED && params.PUBLISH } }
            steps {
                withCredentials([usernamePassword(credentialsId: 'hub.docker.com',
                        usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                    sh 'COSIGN_PUB="$KEY_DIR/cosign.pub" jenkins/scripts/publish.sh perconalab -wolfi-ci $CHANGED'
                }
            }
        }
        stage('Save caches') {
            steps {
                withCredentials(awsBinding()) {
                    sh 'jenkins/scripts/locks.sh stash'
                    sh 'CACHE_URL="$CACHE_URL/shared" jenkins/scripts/cache.sh save ' + sharedEntries
                    sh 'CACHE_URL="$CACHE_URL/incremental" jenkins/scripts/cache.sh save ' + stateEntries
                }
            }
        }
    }
    post {
        always {
            sh 'jenkins/scripts/install-keys.sh clean ci || true'
            sh 'make report || true'
            archiveArtifacts artifacts: 'out/ci-plan.txt, out/report-*.tar.gz, out/results/**', allowEmptyArchive: true
        }
    }
}
