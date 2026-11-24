pipeline {
    agent { label 'kaniko' }

    options {
        skipDefaultCheckout()
        disableConcurrentBuilds()
    }

    parameters {
        string(name: 'GITOPS_BRANCH', defaultValue: 'main', trim: true,
               description: 'Гілка HW-05, яку відстежує Argo CD')
    }

    environment {
        GITOPS_BRANCH = "${params.GITOPS_BRANCH}"
    }

    triggers {
        pollSCM('* * * * *')
    }

    stages {
        stage('Prepare build context') {
            steps {
                container('git') {
                    sh '''
                        set -eu
                        printf '%s\\n' "${ECR_REPOSITORY_URL:-}" | grep -Eq '^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9][a-z0-9._/-]*$' || {
                            echo 'ECR_REPOSITORY_URL має містити URL ECR repository без тега.' >&2
                            exit 1
                        }
                        git check-ref-format "refs/heads/$GITOPS_BRANCH"
                    '''
                    dir('hw02') {
                        checkout(poll: true, changelog: true, scm: [
                            $class: 'GitSCM',
                            branches: [[name: 'refs/heads/lesson-4']],
                            userRemoteConfigs: [[
                                url: 'https://github.com/IegorOrlov/goit-dev-ops-hw-02.git',
                                refspec: '+refs/heads/lesson-4:refs/remotes/origin/lesson-4'
                            ]]
                        ])
                        script {
                            def sourceCommit = sh(script: 'git rev-parse --short=12 HEAD', returnStdout: true).trim()
                            env.IMAGE_TAG = "${sourceCommit}-${env.BUILD_NUMBER}"
                        }
                    }
                    dir('hw05') {
                        checkout(scm: scm, poll: false, changelog: false)
                    }
                    sh 'cp hw05/django/Dockerfile hw05/django/kubernetes_settings.py hw02/django/'
                }
            }
        }

        stage('Build and push image') {
            steps {
                container(name: 'kaniko', shell: '/busybox/sh') {
                    sh '''#!/busybox/sh
                        set -eu
                        registry=${ECR_REPOSITORY_URL%%/*}
                        mkdir -p /kaniko/.docker
                        printf '{"credHelpers":{"%s":"ecr-login"}}\\n' "$registry" > /kaniko/.docker/config.json
                        /kaniko/executor \\
                            --context="dir://$WORKSPACE/hw02/django" \\
                            --dockerfile="$WORKSPACE/hw02/django/Dockerfile" \\
                            --destination="$ECR_REPOSITORY_URL:$IMAGE_TAG"
                    '''
                }
            }
        }

        stage('Update Helm values') {
            steps {
                container('git') {
                    withCredentials([gitUsernamePassword(credentialsId: 'github-hw05-write', gitToolName: 'Default')]) {
                        sh '''
                            set -eu
                            git init gitops
                            cd gitops
                            git remote add origin https://github.com/IegorOrlov/goit-dev-ops-hw-05.git
                            git fetch --no-tags origin "refs/heads/$GITOPS_BRANCH"
                            git checkout --detach FETCH_HEAD

                            values=charts/django-app/values.yaml
                            awk -v repository="$ECR_REPOSITORY_URL" -v tag="$IMAGE_TAG" '
                                /^[^[:space:]#]/ { in_image = 0 }
                                /^image:[[:space:]]*(#.*)?$/ { in_image = 1; images++ }
                                in_image && /^  (repository|tag): +[^[:space:]#]+ *(#.*)?$/ {
                                    match($0, /^  (repository|tag): +[^[:space:]#]+/)
                                    field = $1
                                    keys[field]++
                                    value = (field == "repository:" ? repository : tag)
                                    if ($2 != value && $2 != sprintf("%c%s%c", 34, value, 34) && $2 != sprintf("%c%s%c", 39, value, 39)) {
                                        $0 = "  " field " " value substr($0, RLENGTH + 1)
                                    }
                                }
                                { print }
                                END {
                                    if (images != 1 || keys["repository:"] != 1 || keys["tag:"] != 1) exit 1
                                }
                            ' "$values" > "$values.tmp" || {
                                echo "Очікується один блок image із простими значеннями repository і tag у $values" >&2
                                exit 1
                            }
                            mv "$values.tmp" "$values"

                            if git diff --quiet -- "$values"; then
                                echo 'Helm values уже посилається на опублікований образ.'
                                exit 0
                            fi
                            git add -- "$values"
                            git -c user.name=Jenkins -c user.email=jenkins@users.noreply.github.com \\
                                commit -m "Update Django image to $IMAGE_TAG"
                            git push origin "HEAD:refs/heads/$GITOPS_BRANCH"
                        '''
                    }
                }
            }
        }
    }
}
