# Kelpie on AWS ECS Fargate

Buyer launch path: clone https://github.com/yumaitau/Kelpie-aws-deploy and start from the repository README. Subscribe on the Kelpie AWS Marketplace listing before `terraform apply`.

Terraform reference stack for a buyer-owned deployment in `ap-southeast-2`:

- Two-AZ VPC with public ALB subnets, private Fargate subnets, isolated data subnets, NAT egress, and an S3 gateway endpoint.
- ECS Fargate `X86_64` task definitions for web, worker, and one-shot migration roles.
- RDS PostgreSQL 16 and TLS-only ElastiCache Redis with no public route or public address.
- KMS-encrypted, versioned, public-blocked S3 evidence bucket.
- Secrets Manager runtime secret, ECS execution role, and least-privilege S3 task role. No AWS access keys enter task definitions.
- CloudWatch logs and Container Insights, ALB readiness checks, optional WAF, and optional AWS Backup.

Amazon EKS buyers use the same Marketplace image via `../charts/kelpie` and `../charts/kelpie/values-aws-marketplace.yaml`.

## Prerequisites

- Terraform 1.8 or newer.
- AWS CLI authenticated to the intended account.
- `jq` and `curl` for `bootstrap.sh`.
- Immutable multi-architecture Kelpie image containing `linux/amd64`.
- AWS Marketplace buyers: set `container_image` to an existing Marketplace ECR digest. No GitHub token. Licensing is enforced by the image.
- Private GHCR only: existing Secrets Manager secret containing exactly `{"username":"...","password":"..."}`. Password must be a GitHub token with `read:packages`.

Never put secrets in `terraform.tfvars`, shell history, or committed files. Terraform state contains generated database/application secrets; use an encrypted remote backend with restricted access for production.

## Clean-account deployment

Marketplace buyers: one `terraform apply`. Image entrypoint waits for Postgres,
applies Drizzle migrations (advisory-locked across web+worker), then starts the
task command. Secrets, RDS, Redis, and S3 are created by this stack. First
visitor registers at `/sign-up` (`SIGNUP_MODE=open`) and creates the organisation
at `/onboarding`. No seed admin is baked in. Consider Amazon Bedrock on that
form for in-account AI (Claude in your Region via the task role): ATO explainers,
risk summaries, evidence-gap review, and ITSA/CISO draft briefs. Enable the
model in Bedrock model access. Leave `ses_from_email` empty until
that first account exists — production email verification turns on only when SES
(or another provider) is configured. Set `SIGNUP_MODE=invite_only` later to lock
public registration.

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Pin container_image to a 1.0.3+ Marketplace ECR digest. Do not set a GHCR pull secret.
terraform init
terraform apply -var-file=terraform.tfvars
terraform output application_url
```

`./bootstrap.sh` is optional. It is the two-apply certification helper: services
off, one-shot migrate + S3 write-proof, services on, `/api/health`+`/api/health`, then
`terraform/evidence/aws-fargate-deploy.md`. Ordinary `terraform apply` is
enough to launch.

Use `terraform plan` / `terraform apply` for later infrastructure changes. The
entrypoint migrates on every task start; a separate migration task is still
available if you want an explicit pre-roll.

## Outputs

```sh
terraform output application_url
terraform output web_task_definition_arn
terraform output worker_task_definition_arn
terraform output migration_task_definition_arn
terraform output evidence_bucket_name
```

Outputs never contain secret values.

## Required vs optional AWS services

This stack always creates the services Kelpie needs to boot:

- VPC, NAT, ALB, ECS Fargate (web + worker)
- RDS PostgreSQL 16
- ElastiCache Redis (TLS to Redis; not public HTTPS)
- KMS-encrypted S3 evidence bucket + S3 gateway endpoint
- Secrets Manager, CloudWatch logs
- ECS execution role + task role with S3/KMS and License Manager `CheckoutLicense`

S3 is not a later add-on. Evidence uploads use this bucket. Do not tell operators to invent a second IAM role “for TLS in front of the instance”. TLS is an ACM certificate on the ALB (or their own proxy). IAM for S3/SES/License Manager already lives on the ECS **task** role.

Leave these unset until the buyer chooses them. First `/sign-up` works without either:

| Choice | Terraform | What happens if empty |
| --- | --- | --- |
| HTTPS | `certificate_arn` + `app_url` | HTTP ALB. `ALLOW_INSECURE_PUBLIC_URL=true`. Fine for a proof run. |
| Outbound email | `ses_from_email` (verified SES identity) | No mail. Invites and password reset stay in-app. Stack does not attach `ses:SendEmail` until this is set. |

Amazon EKS buyers do **not** get RDS/Redis/S3 from this module. They provision those plus IRSA themselves (`../charts/kelpie/values-aws-marketplace.yaml`).

## Production switches

Test defaults optimise for a short proof run. Production should set:

```hcl
app_url                       = "https://kelpie.example.com"
certificate_arn                = "arn:aws:acm:ap-southeast-2:...:certificate/..."
allowed_ingress_cidrs          = ["203.0.113.0/24"]
allow_internet_ingress         = false
database_multi_az              = true
database_deletion_protection   = true
cache_high_availability        = true
single_nat_gateway             = false
enable_aws_backup              = true
force_destroy_backup_vault     = false
force_destroy_evidence_bucket  = false
```

`allowed_ingress_cidrs` is required. `0.0.0.0/0` is rejected unless `allow_internet_ingress = true`. Use that flag only for a public site behind WAF and HTTPS.

HTTPS is ACM on the ALB. Request the certificate in the same Region as the load balancer, then set both `certificate_arn` and `app_url`. Same `terraform apply` later; no new IAM role.

Outbound email is optional and should wait until the first admin exists (so signup is not gated on mail that never arrives):

```hcl
ses_from_email = "Kelpie <no-reply@example.com>"
```

That identity must already be verified in Amazon SES. The stack then sets `EMAIL_PROVIDER=ses` and adds `ses:SendEmail` on the existing task role. SMTP, Paperboy, Resend, or Azure ACS are other `EMAIL_PROVIDER` choices; they are not created by this module.

Configure DNS to the ALB, use a remote state backend, and set a final-snapshot policy appropriate to the buyer. Do not ship `0.0.0.0/0` on the ALB unless `allow_internet_ingress` is an explicit, reviewed decision.

## Destroy

Test stack destroy is guarded and uses the same variable arguments as bootstrap:

```sh
KELPIE_ALLOW_DESTROY=yes ./destroy.sh -var-file=terraform.tfvars
```

`database_deletion_protection=true`, `force_destroy_backup_vault=false`, and `force_destroy_evidence_bucket=false` intentionally block destructive production teardown. Disable protection only after approved backup/export, retained recovery points, and evidence disposition. Test defaults skip the final RDS snapshot and allow test evidence/recovery-point deletion so ALB, NAT, RDS, and cache costs do not linger.
