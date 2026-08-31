# Kelpie AWS Marketplace deploy

Public buyer artifacts for Kelpie on AWS Marketplace. Subscribe on that listing
**before** you pull the image or create a stack. The publisher does not host
your data.

This repository is CloudFormation, Terraform, Helm, and IAM only. The
application image lives in AWS Marketplace ECR:

`709825985650.dkr.ecr.us-east-1.amazonaws.com/yuma-it/kelpie-aws`

AWS Marketplace always shows `docker login` + `docker pull` for container
listings. That snippet only proves the subscription can pull the image. It does
not create VPC, ECS, RDS, Redis, S3, or IAM. Use this repo to launch the product.

The Kelpie AWS Marketplace distribution validates its entitlement at runtime
with AWS License Manager `CheckoutLicense`. Marketplace licensing cannot be
disabled through Docker, ECS, Terraform, Helm, or environment configuration.
The ECS task role must permit the required AWS License Manager operations.

Pin `container_image` / Helm `image.tag` to a tag that **already exists** in
Marketplace ECR (`sha-<commit>` or a version tag created from that digest).
Do not use `:latest`.

## ECS Fargate — CloudFormation (AWS Console)

No Terraform. Upload the template in the CloudFormation console or use the AWS CLI.

Creates VPC, ALB, ECS Fargate (web + worker), RDS PostgreSQL 16, ElastiCache Redis,
Secrets Manager, KMS, and a private S3 attachments bucket. The ECS task role
already has S3, KMS, SES (when configured), and License Manager `CheckoutLicense`.

```sh
git clone https://github.com/yumaitau/Kelpie-aws-deploy.git
cd Kelpie-aws-deploy/cloudformation
```

Console: Create stack → Upload `kelpie-fargate.yaml` → set **ContainerImage** to
an existing listing tag or digest → set **AllowedIngressCidr** to your office/VPN
CIDR → acknowledge IAM → Create. Do not use `0.0.0.0/0` unless
**AllowInternetIngress** is true. Marketplace product-code parameters are ignored;
the image already knows the Kelpie listing.

CLI:

```sh
cp parameters.example.json parameters.json
# edit image and AllowedIngressCidr

aws cloudformation deploy \
  --stack-name kelpie \
  --template-file kelpie-fargate.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides $(python3 -c 'import json; print(" ".join("%s=%s" % (p["ParameterKey"], p["ParameterValue"]) for p in json.load(open("parameters.json"))))')
```

Open the `ApplicationUrl` output. First user registers at `/sign-up`, then
creates the organisation. No seed admin is baked into the image.

HTTPS later: ACM certificate in the ALB Region, then set `CertificateArn` and
`AppUrl`. TLS terminates on the ALB.

Outbound email later: verify an Amazon SES identity, then set `SesFromEmail`.

Details: [`cloudformation/README.md`](cloudformation/README.md).

## ECS Fargate — Terraform

Same stack as CloudFormation if you already use Terraform.

```sh
git clone https://github.com/yumaitau/Kelpie-aws-deploy.git
cd Kelpie-aws-deploy/terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

1. Pin `container_image` to an existing Marketplace ECR tag or digest.
2. Set `allowed_ingress_cidrs` to your office, VPN, or client CIDR. Leave
   `allow_internet_ingress` false. `0.0.0.0/0` is rejected unless that flag is true.
3. Leave `certificate_arn` and `ses_from_email` empty for a first HTTP launch
   without mail.

Do not set `marketplace_enforce_container_license`,
`AWS_MARKETPLACE_ENFORCE_CONTAINER_LICENSE`, or buyer-supplied product codes.
Those values cannot disable licensing.

```sh
terraform init
terraform apply -var-file=terraform.tfvars
terraform output application_url
```

Optional: `./bootstrap.sh -var-file=terraform.tfvars` runs migration before
starting services. Ordinary `terraform apply` is enough.

Full variable notes: [`terraform/README.md`](terraform/README.md). Dual-NAT
(per-AZ egress) is Terraform-only.

## Amazon EKS

Helm does **not** create RDS, Redis, or S3. Provision those plus an IRSA role first, then:

```sh
helm upgrade --install kelpie charts/kelpie --namespace kelpie --create-namespace \
  -f charts/kelpie/values-aws-marketplace.yaml \
  --set env.APP_URL=https://kelpie.example.com \
  --set env.BETTER_AUTH_URL=https://kelpie.example.com \
  --set env.STORAGE_DRIVER=s3 \
  --set env.S3_BUCKET=<your-bucket>
```

Attach [`iam-policy.json`](iam-policy.json) plus S3/KMS (and `ses:SendEmail` if
using SES) to the IRSA role. Terminate HTTPS on your Ingress or load balancer.

Web command is `node server.js`. Worker is `node dist/jobs-worker.cjs`.
Migrations: `node dist/migrate.cjs`. Keep the image `ENTRYPOINT`.

## Health

- `GET /api/health` — process liveness and dependency check

If a Marketplace task starts without a valid entitlement, it exits with a
non-zero status and does not serve Kelpie.

## Cost

You pay AWS directly for Fargate, ALB, NAT, RDS, ElastiCache, S3, KMS, Secrets
Manager, CloudWatch, and optional WAF/Backup. Marketplace contract charges are
separate.

## Destroy

CloudFormation:

```sh
aws cloudformation delete-stack --stack-name kelpie
```

Terraform:

```sh
cd terraform
KELPIE_ALLOW_DESTROY=yes ./destroy.sh -var-file=terraform.tfvars
```

Empty the attachments bucket first if objects exist.

## CI

Pushes and pull requests to `main` run [`.github/workflows/security.yml`](.github/workflows/security.yml): Terraform fmt and validate, Helm lint, Checkov, Gitleaks, and Trivy.

## Support

https://github.com/yumaitau/Kelpie/issues
