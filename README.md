# Розгортання Django в AWS EKS

## Опис проєкту

Навчальний проєкт демонструє розгортання контейнеризованого Django-застосунку в Amazon EKS через Terraform і Helm у регіоні `us-west-2`.

Terraform створює VPC із public/private subnets, Internet Gateway, один NAT Gateway, ECR repository, кластер EKS `1.35` і два робочі вузли `t3.small`. Docker image Django зберігається в ECR. Helm chart розгортає Django, передає змінні середовища через ConfigMap і відкриває HTTP-доступ через публічний Network Load Balancer.

PostgreSQL працює в одному pod із постійним диском EBS `1Gi`. HPA керує кількістю Django pods у межах 2–6 із цільовим середнім CPU utilization 70%. Terraform state зберігається в S3, блокування забезпечує DynamoDB. Після демо інструкція передбачає повне видалення створених ресурсів.

## Орієнтовний кошторис

Оцінка для двогодинного демо в `us-west-2`, включно зі створенням і видаленням ресурсів. Нижче наведено округлені орієнтовні ставки станом на `2026-11-19` до врахування Free Tier і credits.

| Ресурс | Кількість та орієнтовна ставка | За 2 години, USD |
| --- | --- | --- |
| EKS зі standard support | 1 кластер × $0.10/год | 0.20 |
| EC2 `t3.small` | 2 вузли × близько $0.021/год | 0.084 |
| NAT Gateway | 1 × близько $0.045/год | 0.09 |
| Network Load Balancer | 1 × близько $0.0225/год | 0.045 |
| Public IPv4 | 3 адреси NLB та 1 NAT EIP × $0.005/год | 0.04 |
| EBS | 40 GiB root-дисків та 1 GiB PostgreSQL | близько 0.01 |
| **Базова вартість** | | **близько 0.47** |

Додатково оплачуються обробка traffic через NAT Gateway, NLB capacity units, передавання даних, зберігання та API-запити ECR/S3/DynamoDB, можливі T3 CPU credits. Практичний орієнтир для короткого демо — **$1–2**. Фактична сума залежить від часу роботи й обсягу використання. Перед запуском звірте регіональні тарифи, після демо виконайте cleanup у пунктах 6–9. [EKS](https://aws.amazon.com/eks/pricing/), [EC2](https://aws.amazon.com/ec2/instance-types/t3/), [NAT та IPv4](https://aws.amazon.com/vpc/pricing/), [NLB](https://aws.amazon.com/elasticloadbalancing/pricing/), [EBS](https://aws.amazon.com/ebs/pricing/), [AWS Calculator](https://calculator.aws/).

## Передумови

Потрібні Terraform `>=1.15`, AWS CLI v2 із `aws login`, Docker з Buildx, Helm, `kubectl`, Python 3 та Django source у `../goit-dev-ops-hw-02/django`. Усі команди виконуйте з кореня цього репозиторію в одному terminal. За помилки зупиніться на поточному кроці.

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

## 1. Зібрати Docker image

```bash
export IMAGE_TAG=lesson-7
export NAMESPACE=django-demo
export RELEASE=django
docker buildx build --platform linux/amd64 --load \
  --build-context deployment=./django --file django/Dockerfile \
  --tag "django-app:$IMAGE_TAG" ../goit-dev-ops-hw-02/django
```

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
export BACKUP_DIR="$(mktemp -d /tmp/goit-hw04-backup.XXXXXX)"
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
terraform apply
```

Service-linked role створюється один раз для EKS node groups. Якщо AWS повідомляє, що `AWSServiceRoleForAmazonEKSNodegroup` уже існує, продовжуйте з `terraform apply`.

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

## 5. Завантажити image та розгорнути застосунок

```bash
aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR_URL%%/*}"
docker tag "django-app:$IMAGE_TAG" "$ECR_URL:$IMAGE_TAG"
docker push "$ECR_URL:$IMAGE_TAG"
helm upgrade --install "$RELEASE" charts/django-app --kube-context "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" --create-namespace \
  --set-string image.repository="$ECR_URL" --set-string image.tag="$IMAGE_TAG" \
  --set-string config.ALLOWED_HOSTS="localhost\,127.0.0.1\,$RELEASE-django" \
  --wait --timeout 10m
kubectl --context "$CLUSTER_NAME" -n "$NAMESPACE" exec deployment/"$RELEASE-django" -- python manage.py migrate --noinput
```

Додайте IPv4 NLB до `ALLOWED_HOSTS`. За тимчасової помилки DNS повторіть отримання IP через 30 секунд. Остання команда очікує HTTP `200`, адресу `http://$NLB_IP` можна відкрити у браузері.

```bash
kubectl --context "$CLUSTER_NAME" -n "$NAMESPACE" wait \
  --for=jsonpath='{.status.loadBalancer.ingress[0].hostname}' service/"$RELEASE-django" --timeout=5m
export NLB_DNS="$(kubectl --context "$CLUSTER_NAME" -n "$NAMESPACE" get service "$RELEASE-django" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
export NLB_IP="$(python3 -c 'import socket,sys; print(socket.gethostbyname(sys.argv[1]))' "$NLB_DNS")"
helm upgrade "$RELEASE" charts/django-app --kube-context "$CLUSTER_NAME" \
  --namespace "$NAMESPACE" --reuse-values \
  --set-string config.ALLOWED_HOSTS="localhost\,127.0.0.1\,$RELEASE-django\,$NLB_IP" --wait --timeout 10m
python3 - "$NLB_IP" <<'PYTHON'
import sys, time, urllib.request
for attempt in range(30):
    try:
        with urllib.request.urlopen("http://" + sys.argv[1], timeout=10) as response:
            print(response.status)
            assert response.status == 200
        break
    except (OSError, AssertionError):
        if attempt == 29:
            raise
        time.sleep(10)
PYTHON
```

## 6. Видалити застосунок, NLB і PostgreSQL volume

Збережіть IDs до видалення. Controllers мають працювати до завершення cleanup NLB/EBS. Після частково невдалого deployment видаляйте фактично створені ресурси, пропускаючи команди з відсутніми IDs.

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
helm uninstall "$RELEASE" --kube-context "$CLUSTER_NAME" --namespace "$NAMESPACE" --ignore-not-found --wait --timeout 10m
kubectl --context "$CLUSTER_NAME" wait --for=delete pv/"$PV_NAME" --timeout=10m
```

`helm uninstall --wait` очікує видалення Service з controller finalizer, а видалення PV — завершення CSI reclaim. Якщо PV вже відсутній, відповідь `NotFound` для його точного імені означає, що перевірку Kubernetes завершено. Перед видаленням EKS адміністратор у **EC2 Console**, Region **Oregon / us-west-2**, перевіряє відсутність NLB `$NLB_NAME` у **Load Balancers**, його target group зі збереженим ARN у **Target Groups** та PostgreSQL volume `$DB_VOLUME_ID` у **Volumes**. За затримки дочекайтеся видалення, зберігаючи controllers запущеними. Add-ons і namespace видаляться разом із EKS під час `terraform destroy`.

Для цих Console-перевірок увійдіть під адміністратором у той самий AWS account. Користувач `terraform-student` не має, зокрема, `elasticloadbalancing:DescribeLoadBalancers` та `ec2:DescribeVolumes`; Console під цим користувачем також не покаже ресурси. `AccessDenied` не підтверджує їх відсутність. Розширювати права `terraform-student` для cleanup не потрібно.

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
for role_suffix in cluster node load-balancer ebs-csi; do
  aws iam get-role --role-name "$CLUSTER_NAME-$role_suffix"
done
aws iam get-policy --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$CLUSTER_NAME-load-balancer"
```

Адміністратор перевіряє в **EC2 Console → Volumes**, Region `us-west-2`, відсутність усіх EBS volumes з `$BACKUP_DIR/volume-ids.txt`, включно із системними дисками вузлів. Порожній список без помилки доступу підтверджує відсутність volumes; якщо список непорожній, перевірте кожен збережений ID. У **IAM → Identity providers** має бути відсутній `$OIDC_PROVIDER_ARN`. IDs збережені в `$BACKUP_DIR/resource-ids.txt`, backup зберігайте до завершення перевірок.

Ручні IAM policies та service-linked roles самі по собі [не оплачуються](https://aws.amazon.com/iam/faqs/). Для припинення витрат їх можна залишити. Наступні дії потрібні лише для повного видалення створених для демо IAM resources.

Після успішного destroy адміністратор від'єднує `GoitHw04TerraformAccess` від `terraform-student` і видаляє цю policy та `lesson-7-eks-role-boundary`. Вони створювалися вручну та перебувають поза Terraform state.

Адміністратор також видаляє через **IAM → Roles** service-linked roles, створені цим розгортанням, після звільнення їхніх залежностей.

- `AWSServiceRoleForAmazonEKS`
- `AWSServiceRoleForAmazonEKSNodegroup`
- `AWSServiceRoleForAutoScaling`
- `AWSServiceRoleForElasticLoadBalancing`

Ці ролі спільні для account. Перед видаленням переконайтеся, що вони створені цим запуском і не використовуються іншими проєктами.

Після cleanup перевірте **Billing → Bills / Cost Explorer** за Region `us-west-2`. Дані оновлюються із затримкою, вже спожиті ресурси залишаються в рахунку.
