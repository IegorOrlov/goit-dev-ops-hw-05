# CI/CD для Django в AWS EKS

## Опис проєкту

Навчальний проєкт готує CI/CD для Django в Amazon EKS у регіоні `us-west-2`. Jenkins збиратиме образ із HW-02 і публікуватиме його в ECR. Argo CD застосовуватиме Helm chart із HW-05 після оновлення тега образу в Git.

Terraform створює VPC із public/private subnets, Internet Gateway, один NAT Gateway, ECR repository, кластер EKS `1.35` і три робочі вузли `t3.small`. Docker image Django зберігається в ECR. Helm chart розгортає Django, передає змінні середовища через ConfigMap і відкриває HTTP-доступ через публічний Network Load Balancer.

PostgreSQL працює в одному pod із постійним диском EBS `1Gi`. HPA керує кількістю Django pods у межах 2–6 із цільовим середнім CPU utilization 70%. Terraform state зберігається в S3, блокування забезпечує DynamoDB. Після демо інструкція передбачає повне видалення створених ресурсів.

## Орієнтовний кошторис

Оцінка для двогодинного демо в `us-west-2`, включно зі створенням і видаленням ресурсів. Нижче наведено округлені орієнтовні ставки станом на `2026-11-19` до врахування Free Tier і credits.

| Ресурс | Кількість та орієнтовна ставка | За 2 години, USD |
| --- | --- | --- |
| EKS зі standard support | 1 кластер × $0.10/год | 0.20 |
| EC2 `t3.small` | 3 вузли × близько $0.021/год | 0.126 |
| NAT Gateway | 1 × близько $0.045/год | 0.09 |
| Network Load Balancer | 1 × близько $0.0225/год | 0.045 |
| Public IPv4 | 3 адреси NLB та 1 NAT EIP × $0.005/год | 0.04 |
| EBS | 60 GiB root-дисків, 8 GiB Jenkins та 1 GiB PostgreSQL | близько 0.01 |
| **Базова вартість** | | **близько 0.51** |

Додатково оплачуються обробка traffic через NAT Gateway, NLB capacity units, передавання даних, зберігання та API-запити ECR/S3/DynamoDB, можливі T3 CPU credits. Практичний орієнтир для короткого демо — **$1–2**. Фактична сума залежить від часу роботи й обсягу використання. Перед запуском звірте регіональні тарифи, після демо виконайте cleanup у пунктах 6–9. [EKS](https://aws.amazon.com/eks/pricing/), [EC2](https://aws.amazon.com/ec2/instance-types/t3/), [NAT та IPv4](https://aws.amazon.com/vpc/pricing/), [NLB](https://aws.amazon.com/elasticloadbalancing/pricing/), [EBS](https://aws.amazon.com/ebs/pricing/), [AWS Calculator](https://calculator.aws/).

## Місткість EKS

Оцінка за Kubernetes requests для одного Jenkins build і Django на верхній межі HPA. Для Django враховано сім pods під час rollout або шість pods і Job міграцій, а також PostgreSQL.

| Компонент | CPU | Пам’ять | Pods |
| --- | ---: | ---: | ---: |
| Jenkins controller | 250m | 768 MiB | 1 |
| Jenkins agent з Git і Kaniko | 400m | 832 MiB | 1 |
| Django і PostgreSQL | 800m | 1 152 MiB | 8 |
| Бюджет для Argo CD | 500m | 640 MiB | 6 |
| EKS і add-ons, оцінка | 1 000m | 768 MiB | 14 |
| **Разом** | **2 950m** | **4 160 MiB** | **30** |

Два `t3.small` мають разом 4 GiB номінальної пам’яті до резерву EKS, тож потрібен третій вузол. За типової конфігурації VPC CNI максимальна кількість pods на вузол становить `3 × (4 − 1) + 2 = 11`. Три вузли дають 33 місця під pods, із яких 30 закладено в оцінку. [Ліміти ENI та IPv4 для EC2](https://docs.aws.amazon.com/ec2/latest/instancetypes/gp.html), [вибір типу інстанса для EKS](https://docs.aws.amazon.com/eks/latest/userguide/choosing-instance-type.html).

Резерв пам’яті за цієї кількості pods становить приблизно `11 × 11 + 255 + 100 = 476 MiB` на вузол. Від номінальних 2 048 MiB лишається до 1 572 MiB на вузол, або близько 4,6 GiB на групу. Один можливий розподіл запитів становить 1 408 MiB і 10 pods на першому вузлі, 1 408 MiB і 9 pods на другому та 1 344 MiB і 11 pods на третьому. Перед запуском звірте фактичні `Allocatable` та `Allocated resources` у `kubectl describe nodes`. Розміщення залежить від requests Argo CD та зон EBS volumes. [Розрахунок allocatable memory для EKS](https://docs.aws.amazon.com/batch/latest/userguide/memory-cpu-batch-eks.html).

Три вузли потребують 6 вільних vCPU у квоті **Running On-Demand Standard instances** в `us-west-2`. Перед розгортанням адміністратор перевіряє застосовану квоту в **Service Quotas → Amazon EC2**. Стандартна квота AWS становить 5 vCPU. Якщо вільних vCPU менше шести, підвищіть квоту до запуску. [Квоти EC2 On-Demand](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-on-demand-instances.html).

## Передумови

Для підготовки й перевірки інфраструктури потрібні Terraform `>=1.15`, AWS CLI v2 із `aws login`, Helm, `kubectl`, Python 3 і `curl`. Для збірки Jenkins потрібен доступ до GitHub-репозиторіїв HW-02 і HW-05. Команди AWS і Kubernetes виконуйте з кореня цього репозиторію в одному terminal. За помилки зупиніться на поточному кроці.

Команди використовують profile `goit` для IAM user `terraform-student`. Адміністратор призначає цьому користувачу AWS managed policies `AmazonS3FullAccess`, `AmazonDynamoDBFullAccess_v2`, `AmazonVPCFullAccess`, `AmazonEC2ContainerRegistryFullAccess`, `SignInLocalDevelopmentAccess`, а також inline policy `TerraformEipReadAttributes`.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "ec2:DescribeAddressesAttribute",
    "Resource": "*"
  }]
}
```

Адміністратор створює customer managed policy `lesson-7-eks-role-boundary` з [role-boundary.json](role-boundary.json) та `GoitHw04TerraformAccess` з [terraform-student-policy.json](terraform-student-policy.json). Користувачу призначається `GoitHw04TerraformAccess`, boundary застосовує Terraform до службових ролей. Для іншого account або IAM user замініть відповідні значення в JSON policies та `TF_VAR_admin_principal_arn`.

Для Jenkins адміністратор створює також дві customer managed policies у тому самому account.

- `lesson-7-eks-jenkins-agent-ecr` з [jenkins-agent-ecr-policy.json](jenkins-agent-ecr-policy.json). Terraform використовує її як permissions boundary та identity policy ролі агента. Upload і pull обмежені ECR repository `lesson-5-ecr`. `ecr:GetAuthorizationToken` застосовується до `*`.
- `GoitHw05JenkinsAccess` з [terraform-jenkins-policy.json](terraform-jenkins-policy.json), яку адміністратор призначає `terraform-student`. Якщо `GoitHw04TerraformAccess` уже існує, оновіть її з поточного JSON, щоб Terraform міг збільшити наявну node group.

Вузли EKS завантажують образи через `AmazonEC2ContainerRegistryPullOnly`. IRSA для публікації використовує тільки service account `jenkins-agent` у namespace `jenkins`. Для іншого account підставте його ID в обох Jenkins policies.

## 1. Контекст збірки для Jenkins

Jenkins отримує свіжий checkout гілки `lesson-4` (`refs/heads/lesson-4`) з HW-02. У прикладі `HW02_DIR` і `HW05_DIR` — абсолютні шляхи до двох checkout у workspace агента. Dockerfile з HW-05 замінює Dockerfile у свіжому checkout HW-02 лише для цієї збірки. [HW-02, гілка lesson-4](https://github.com/IegorOrlov/goit-dev-ops-hw-02/tree/lesson-4/django).

```bash
CONTEXT_DIR="$HW02_DIR/django"
cp "$HW05_DIR/django/Dockerfile" "$HW05_DIR/django/kubernetes_settings.py" "$CONTEXT_DIR/"
```

Kaniko отримує `--context="dir://$CONTEXT_DIR"` і `--dockerfile="$CONTEXT_DIR/Dockerfile"`. Контекст містить `requirements.txt`, `manage.py`, пакет `my-app` і `kubernetes_settings.py`. Dockerfile задає `DJANGO_SETTINGS_MODULE=kubernetes_settings`. Цей модуль додає читання `ALLOWED_HOSTS` із середовища, а параметри PostgreSQL застосунок читає з успадкованих Django settings через `POSTGRES_*`.

## 2. Увійти в AWS

```bash
aws login --profile goit --region us-west-2
```

## 3. Створити backend та інфраструктуру

Замініть `REPLACE_PUBLIC_IPV4` на вашу публічну IPv4. `BACKUP_DIR` зберігатиме state та IDs до завершення cleanup.

```bash
export AWS_PROFILE=goit
export AWS_REGION=us-west-2
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export TF_VAR_bucket_name="goit-tfstate-$ACCOUNT_ID-lesson-5"
export TF_VAR_admin_principal_arn="arn:aws:iam::$ACCOUNT_ID:user/terraform-student"
export TF_VAR_public_access_cidrs='["REPLACE_PUBLIC_IPV4/32"]'
umask 077
export BACKUP_DIR="$(mktemp -d /tmp/goit-hw05-backup.XXXXXX)"
```

Якщо інфраструктура вже розгорнута, залиште активний S3 backend із її bucket/key, виконайте `terraform init` і продовжуйте з пункту 4. Для нового запуску після повного cleanup спочатку закоментуйте блок S3 backend у `backend.tf`, потім створіть backend з локальним state. Перед `yes` у `apply` перегляньте його план.

```bash
terraform init
terraform apply -target=module.s3_backend
terraform state pull > "$BACKUP_DIR/before-s3.tfstate"
```

Розкоментуйте блок S3 backend у `backend.tf`. У `bucket` впишіть значення `TF_VAR_bucket_name`, інші параметри залиште як у файлі. Потім перенесіть state в S3, підтвердьте копіювання та створіть решту ресурсів.

```bash
terraform init -migrate-state
aws iam create-service-linked-role --aws-service-name eks-nodegroup.amazonaws.com
terraform apply -var='enable_jenkins=false'
```

Service-linked role створюється один раз для EKS node groups. Якщо AWS повідомляє, що `AWSServiceRoleForAmazonEKSNodegroup` уже існує, продовжуйте з `terraform apply -var='enable_jenkins=false'`.

## 4. Підключитися до EKS та встановити add-ons

Дочекайтеся готовності nodes, потім послідовно встановіть add-ons. Кожен `--wait` має завершитися успішно.

```bash
export CLUSTER_NAME="$(terraform output -raw cluster_name)"
export VPC_ID="$(terraform output -raw vpc_id)"
export ECR_URL="$(terraform output -raw ecr_repository_url)"
export ECR_NAME="$(terraform output -raw ecr_repository_name)"
export STATE_BUCKET="$(terraform output -raw s3_bucket_name)"
export LOCK_TABLE="$(terraform output -raw dynamodb_table_name)"
export LBC_ROLE="$(terraform output -raw load_balancer_controller_role_arn)"
export EBS_ROLE="$(terraform output -raw ebs_csi_role_arn)"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME"
kubectl --context "$CLUSTER_NAME" wait --for=condition=Ready nodes --all --timeout=10m
helm repo add eks https://aws.github.io/eks-charts
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --kube-context "$CLUSTER_NAME" --namespace kube-system --version 1.14.1 \
  --set clusterName="$CLUSTER_NAME" --set region="$AWS_REGION" --set vpcId="$VPC_ID" \
  --set replicaCount=1 --set resources.requests.cpu=100m --set resources.requests.memory=128Mi \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set-string "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$LBC_ROLE" \
  --wait --timeout 10m
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --kube-context "$CLUSTER_NAME" --namespace kube-system --version 2.68.0 \
  --set controller.replicaCount=1 --set node.enableWindows=false \
  --set controller.serviceAccount.name=ebs-csi-controller-sa \
  --set-string "controller.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$EBS_ROLE" \
  --wait --timeout 10m
helm upgrade --install metrics-server metrics-server/metrics-server \
  --kube-context "$CLUSTER_NAME" --namespace kube-system --version 3.14.0 --wait --timeout 10m
```

### Встановити Jenkins

Після `Ready` вузлів і готовності EBS CSI увімкніть Jenkins. Helm provider підключається до EKS API з CA кластера й отримує токен через `aws eks get-token`. Поки Jenkins має залишатись встановленим, використовуйте `TF_VAR_enable_jenkins=true` під час наступних Terraform apply.

```bash
export TF_VAR_enable_jenkins=true
terraform apply
kubectl --context "$CLUSTER_NAME" -n jenkins get sts,pvc
```

Отримайте ім’я адміністратора та випадковий пароль з Kubernetes Secret у приватному terminal. Запустіть port-forward і відкрийте `http://localhost:8080`.

```bash
kubectl --context "$CLUSTER_NAME" -n jenkins get secret jenkins \
  -o jsonpath='{.data.jenkins-admin-user}' | base64 -d
printf '\n'
kubectl --context "$CLUSTER_NAME" -n jenkins get secret jenkins \
  -o jsonpath='{.data.jenkins-admin-password}' | base64 -d
printf '\n'
kubectl --context "$CLUSTER_NAME" -n jenkins port-forward service/jenkins 8080:8080
```

Jenkins controller зберігає конфігурацію на EBS PVC. Для pipeline використовується label `kaniko` і контейнери `git`, `kaniko` (`/busybox/sh`) та `jnlp` зі спільним workspace. Тимчасові AWS credentials від IRSA отримує контейнер `kaniko`, де їх використовує вбудований ECR credential helper.

Для читання публічного HW-02 автентифікація Git не потрібна. Якщо HW-02 стане приватним, створіть credential `github-hw02-read` із правом читання та вкажіть його `credentialsId` у checkout HW-02. Для оновлення HW-05 додайте в Jenkins Credentials тип `Username with password` під ID `github-hw05-write`. Вкажіть GitHub username та token з `Contents: Read and write` лише для HW-05. Перед запуском перевірте, що його власник може пушити в цільову гілку. Облікові дані зберігаються у Jenkins.

## 5. Перший запуск через GitOps

До налаштування job опублікуйте гілку `lesson-8-9` з `Jenkinsfile` і `charts/django-app/values.yaml` у HW-05. У Jenkins створіть **Pipeline** з **Pipeline script from SCM**, SCM **Git**, URL `https://github.com/IegorOrlov/goit-dev-ops-hw-05.git`, credential `github-hw05-write`, однією гілкою `refs/heads/lesson-8-9`, шляхом `Jenkinsfile` та увімкненим **Lightweight checkout**.

Перший запуск через **Build Now** реєструє **Poll SCM** (`* * * * *`) і публікує перший образ. Для демо Jenkins опитує Git щохвилини. Це найкоротший інтервал у Jenkins cron. Jenkins завантажує `Jenkinsfile` через Lightweight checkout, а опитує Git plugin checkout гілки `refs/heads/lesson-4` з HW-02. У **Console Output** перевірте рядок `Obtained Jenkinsfile from git`, а в **Polling Log** перевірте, що Jenkins опитує тільки цю гілку HW-02. Коміт Jenkins у `lesson-8-9` підхоплює Argo CD. Наступну збірку запускає зміна в `lesson-4` у HW-02. [Jenkins SCM polling](https://github.com/jenkinsci/workflow-scm-step-plugin/blob/master/README.md), [синтаксис Jenkins cron](https://www.jenkins.io/doc/book/pipeline/syntax/#jenkins-cron-syntax).

Terraform передає ECR URL агенту. Після успішного push Kaniko Jenkins записує `image.repository` і `image.tag` в один commit у цільовій гілці. Тег складається зі скороченого SHA джерела та номера Jenkins build. Новий build публікує новий тег. Якщо обидва значення вже відповідають образу цього build, оновлення пропускає commit. Помилка Kaniko зупиняє pipeline до оновлення чарта. Якщо Git push відхилено, перевірте права або зміни цільової гілки та запустіть job повторно.

Створюйте Argo CD `Application` після того, як Jenkins запише опублікований образ у `charts/django-app/values.yaml` у гілці `lesson-8-9`. За замовчуванням `GITOPS_BRANCH` у `Jenkinsfile` і `gitops_branch` у Terraform вказують на `lesson-8-9`. Для іншої цільової гілки змініть обидва значення.

Під час повного sync Argo CD спочатку застосовує ConfigMap і ресурси PostgreSQL, включно з EBS PVC, та чекає готовності БД. Потім Job запускає `python manage.py migrate --noinput` з тим самим образом і ConfigMap, що й Django Deployment. Після успіху Argo CD застосовує Django Deployment, HPA і публічний NLB Service.

Для навчального демо `config.ALLOWED_HOSTS` має значення `"*"`, щоб Django приймав HTTP-запити на DNS-ім’я або IPv4 нового NLB відразу після його появи. Якщо є заздалегідь відоме DNS-ім’я, у Git можна задати його або список імен через кому.

Після синхронізації встановіть `NAMESPACE` і `RELEASE` за конфігурацією `Application` та перевірте HTTP через hostname NLB.

```bash
kubectl --context "$CLUSTER_NAME" -n "$NAMESPACE" wait \
  --for=jsonpath='{.status.loadBalancer.ingress[0].hostname}' service/"$RELEASE-django" --timeout=5m
NLB_DNS="$(kubectl --context "$CLUSTER_NAME" -n "$NAMESPACE" get service "$RELEASE-django" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
curl --fail --max-time 10 --retry 12 --retry-all-errors --retry-delay 10 --output /dev/null \
  --write-out '%{http_code}\n' "http://$NLB_DNS/"
```

Очікувана відповідь Django — HTTP `200`.

## 6. Видалити застосунок, NLB і PostgreSQL volume

Збережіть IDs до видалення. Підставте namespace Argo CD та назву `Application` у `ARGOCD_NAMESPACE` і `APP_NAME`. `Application` має містити finalizer `resources-finalizer.argocd.argoproj.io` для каскадного видалення ресурсів Django. Argo CD, AWS Load Balancer Controller та EBS CSI мають працювати до завершення cleanup NLB/EBS. Після частково невдалого deployment видаляйте фактично створені ресурси, пропускаючи команди з відсутніми IDs.

```bash
terraform state pull > "$BACKUP_DIR/before-cleanup.tfstate"
terraform output -json > "$BACKUP_DIR/outputs.json"
export NLB_DNS="$(kubectl --context "$CLUSTER_NAME" -n "$NAMESPACE" get service "$RELEASE-django" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
export NLB_NAME="$(python3 -c 'import sys; print(sys.argv[1].split(".")[0].rsplit("-",1)[0])' "$NLB_DNS")"
export TARGET_GROUP_ARN="$(kubectl --context "$CLUSTER_NAME" -n "$NAMESPACE" get targetgroupbindings \
  -o jsonpath='{.items[0].spec.targetGroupARN}')"
export PV_NAME="$(kubectl --context "$CLUSTER_NAME" -n "$NAMESPACE" get pvc "$RELEASE-postgres" -o jsonpath='{.spec.volumeName}')"
export DB_VOLUME_ID="$(kubectl --context "$CLUSTER_NAME" get pv "$PV_NAME" -o jsonpath='{.spec.csi.volumeHandle}')"
export OIDC_ISSUER="$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.identity.oidc.issuer --output text)"
export OIDC_PROVIDER_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/${OIDC_ISSUER#https://}"
aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId' \
  --output text | tr '\t' '\n' > "$BACKUP_DIR/volume-ids.txt"
printf '%s\n' "$DB_VOLUME_ID" >> "$BACKUP_DIR/volume-ids.txt"
printf '%s\n' "$NLB_NAME" "$TARGET_GROUP_ARN" "$DB_VOLUME_ID" "$OIDC_PROVIDER_ARN" > "$BACKUP_DIR/resource-ids.txt"
kubectl --context "$CLUSTER_NAME" -n "$ARGOCD_NAMESPACE" delete application "$APP_NAME" \
  --cascade=foreground --ignore-not-found --wait=true --timeout=10m
kubectl --context "$CLUSTER_NAME" wait --for=delete pv/"$PV_NAME" --timeout=10m
```

Каскадне видалення `Application` очікує видалення його ресурсів, включно із Service з controller finalizer. Видалення PV підтверджує завершення CSI reclaim. Якщо PV вже відсутній, відповідь `NotFound` для його точного імені означає, що перевірку Kubernetes завершено. Перед видаленням EKS адміністратор у **EC2 Console**, Region **Oregon / us-west-2**, перевіряє відсутність NLB `$NLB_NAME` у **Load Balancers**, його target group зі збереженим ARN у **Target Groups** та PostgreSQL volume `$DB_VOLUME_ID` у **Volumes**. За затримки дочекайтеся видалення, зберігаючи controllers запущеними. Add-ons і namespace видаляться разом із EKS під час `terraform destroy`.

Для цих Console-перевірок увійдіть під адміністратором у той самий AWS account. Користувач `terraform-student` не має, зокрема, `elasticloadbalancing:DescribeLoadBalancers` та `ec2:DescribeVolumes`; Console під цим користувачем також не покаже ресурси. `AccessDenied` не підтверджує їх відсутність. Розширювати права `terraform-student` для cleanup не потрібно.

Якщо Jenkins встановлено, дочекайтеся завершення активної збірки й видаліть його через той самий Terraform state, доки доступні EKS API та EBS CSI. Спочатку збережіть ім’я PV та ID диска для перевірки в AWS Console. Видалення релізу також видаляє Jenkins PVC і дані на ньому.

```bash
JENKINS_PV="$(kubectl --context "$CLUSTER_NAME" -n jenkins get pvc jenkins \
  -o jsonpath='{.spec.volumeName}')"
JENKINS_VOLUME_ID="$(kubectl --context "$CLUSTER_NAME" get pv "$JENKINS_PV" \
  -o jsonpath='{.spec.csi.volumeHandle}')"
printf '%s\n' "$JENKINS_VOLUME_ID" >> "$BACKUP_DIR/volume-ids.txt"
unset TF_VAR_enable_jenkins
terraform apply -var='enable_jenkins=false'
kubectl --context "$CLUSTER_NAME" wait --for=delete pv/"$JENKINS_PV" --timeout=10m
```

Якщо PV вже відсутній, `NotFound` для його імені підтверджує завершення перевірки Kubernetes. Перевірте видалення Jenkins volume за збереженим ID у **EC2 Console → Volumes** перед видаленням EKS.

## 7. Очистити ECR та перенести state локально

У **AWS Console**, Region **Oregon / us-west-2**, відкрийте **ECR → Private repositories → lesson-5-ecr → Images**. Видаліть усі tagged та untagged images. Якщо image використовується manifest index, спочатку видаліть index. Repository видалить Terraform. Перевірка має повернути `[]`.

```bash
aws ecr list-images --repository-name "$ECR_NAME" --query imageIds
```

Поки S3 backend ще активний, збережіть список ресурсів:

```bash
terraform state list > "$BACKUP_DIR/before-local.txt"
```

Тепер закоментуйте блок S3 backend у `backend.tf`, перенесіть актуальний state локально та підтвердьте копіювання. `diff` має бути порожнім, перевірка backend має завершитися успішно. Лише після цього переходьте до очищення S3.

```bash
terraform init -migrate-state
terraform state list > "$BACKUP_DIR/after-local.txt"
diff "$BACKUP_DIR/before-local.txt" "$BACKUP_DIR/after-local.txt"
python3 -c 'import json,pathlib; p=pathlib.Path(".terraform/terraform.tfstate"); assert not p.exists() or (json.loads(p.read_text()).get("backend") or {}).get("type") != "s3"'
```

## 8. Очистити S3 та виконати destroy

Після успішної міграції state відкрийте **S3 Console → bucket `$STATE_BUCKET` → Empty**, підтвердьте очищення всіх versions і delete markers та дочекайтеся завершення. [Очищення S3 bucket](https://docs.aws.amazon.com/AmazonS3/latest/userguide/empty-bucket.html).

```bash
terraform destroy
terraform state list
```

Перед `yes` перегляньте список видалення. Очікуються `Destroy complete!` та порожній state. За помилки усуньте вказану залежність і повторіть `terraform destroy`.

Видалення EKS node group, кластера та NAT Gateway може тривати понад 10 хвилин. Повідомлення `Still destroying...` без помилки означає, що Terraform очікує завершення операції AWS; дочекайтеся результату.

## 9. Переконатися, що ресурси демо видалені

Очікуються `NotFound`/`NoSuchEntity`, S3 `404` та порожні списки. Це очікувані відповіді перевірок: продовжуйте наступною командою. NAT зі станом `deleted` уже видалений. `AccessDenied` не підтверджує видалення: відповідний ресурс перевіряє адміністратор у Console.

```bash
aws eks describe-cluster --name "$CLUSTER_NAME"
aws ecr describe-repositories --repository-names "$ECR_NAME"
aws s3api head-bucket --bucket "$STATE_BUCKET"
aws dynamodb describe-table --table-name "$LOCK_TABLE"
aws ec2 describe-vpcs --filters "Name=vpc-id,Values=$VPC_ID"
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --query 'NatGateways[?State!=`deleted`]'
aws ec2 describe-addresses --filters Name=tag:Project,Values=goit-dev-ops-hw-04
for role_suffix in cluster node load-balancer ebs-csi jenkins-agent; do
  aws iam get-role --role-name "$CLUSTER_NAME-$role_suffix"
done
aws iam get-policy --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$CLUSTER_NAME-load-balancer"
```

Адміністратор перевіряє в **EC2 Console → Volumes**, Region `us-west-2`, відсутність усіх EBS volumes з `$BACKUP_DIR/volume-ids.txt`, включно із системними дисками вузлів. Порожній список без помилки доступу підтверджує відсутність volumes; якщо список непорожній, перевірте кожен збережений ID. У **IAM → Identity providers** має бути відсутній `$OIDC_PROVIDER_ARN`. IDs збережені в `$BACKUP_DIR/resource-ids.txt`, backup зберігайте до завершення перевірок.

Ручні IAM policies та service-linked roles самі по собі [не оплачуються](https://aws.amazon.com/iam/faqs/). Для припинення витрат їх можна залишити. Наступні дії потрібні лише для повного видалення створених для демо IAM resources.

Після успішного destroy адміністратор від'єднує `GoitHw04TerraformAccess` і `GoitHw05JenkinsAccess` від `terraform-student` і видаляє ці policies, `lesson-7-eks-role-boundary` та `lesson-7-eks-jenkins-agent-ecr`. Вони створювалися вручну та перебувають поза Terraform state.

Адміністратор також видаляє через **IAM → Roles** service-linked roles, створені цим розгортанням, після звільнення їхніх залежностей.

- `AWSServiceRoleForAmazonEKS`
- `AWSServiceRoleForAmazonEKSNodegroup`
- `AWSServiceRoleForAutoScaling`
- `AWSServiceRoleForElasticLoadBalancing`

Ці ролі спільні для account. Перед видаленням переконайтеся, що вони створені цим запуском і не використовуються іншими проєктами.

Після cleanup перевірте **Billing → Bills / Cost Explorer** за Region `us-west-2`. Дані оновлюються із затримкою, вже спожиті ресурси залишаються в рахунку.
