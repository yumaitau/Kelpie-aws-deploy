# Kelpie on AWS ECS Fargate (CloudFormation)

Native CloudFormation for buyers who do not want Terraform. Same first-launch shape as the Terraform stack in this repo: VPC, ALB, ECS Fargate (web + worker), RDS PostgreSQL 16, ElastiCache Redis (TLS), Secrets Manager, KMS, and a private S3 evidence bucket.

Subscribe on the Kelpie AWS Marketplace listing before you create the stack. The image is Marketplace ECR, not GHCR.

## Console

1. Open CloudFormation in the target Region (`ap-southeast-2` recommended; `us-east-1` for Marketplace metering proof).
2. Create stack → With new resources → Upload a template file → `kelpie-fargate.yaml`.
3. Pin **Container image** to an existing listing tag or digest. Marketplace product-code parameters are ignored.
4. Set **Allowed ingress CIDR** to your office, VPN, or client range. Leave **Allow internet ingress** false. `0.0.0.0/0` is rejected unless that flag is true.
6. Leave **ACM certificate ARN** and **SES From** empty for a first HTTP launch without mail.
7. Acknowledge IAM capabilities. Create.

When the stack is `CREATE_COMPLETE`, open the `ApplicationUrl` output. First user registers at `/sign-up`, then creates the organisation at `/onboarding`. Consider Amazon Bedrock on that form for in-account AI (Claude in your Region via the task role): ATO explainers, risk summaries, evidence-gap review, and ITSA/CISO draft briefs. Enable the model in Bedrock model access. Not required to boot.

## CLI

```sh
cd cloudformation
cp parameters.example.json parameters.json
# edit ContainerImage and AllowedIngressCidr

# Template is over the 51 KiB inline body limit; deploy uploads it to S3.
aws cloudformation deploy \
  --stack-name kelpie \
  --template-file kelpie-fargate.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides $(python3 -c 'import json; print(" ".join("%s=%s" % (p["ParameterKey"], p["ParameterValue"]) for p in json.load(open("parameters.json"))))')

aws cloudformation describe-stacks --stack-name kelpie \
  --query "Stacks[0].Outputs[?OutputKey=='ApplicationUrl'].OutputValue" \
  --output text
```

The image entrypoint waits for Postgres, migrates, then starts. A separate migration task definition is an output if you want an explicit pre-roll.

## Optional parameters

| Parameter | Empty default | Later |
| --- | --- | --- |
| `CertificateArn` + `AppUrl` | HTTP ALB | ACM in the ALB Region. TLS terminates on the ALB. Not an extra IAM role. HTTP still forwards to the target group; HTTPS is added on 443. |
| `SesFromEmail` | No mail | Verified SES identity. Stack sets `EMAIL_PROVIDER=ses` and `ses:SendEmail` on the task role. |
| `DatabaseMultiAz` / `CacheHighAvailability` | Off | Production resilience. |
| `EnableAwsBackup` | Off | Daily AWS Backup of RDS + evidence bucket. |
| `AllowedIngressCidr` | none (required) | Office, VPN, or client CIDR. |
| `AllowInternetIngress` | `false` | Set `true` only to allow `0.0.0.0/0` on the ALB. |

S3 evidence storage is always created. Dual-NAT (per-AZ egress) is Terraform-only.

## Destroy

Empty the evidence bucket first if objects exist, then:

```sh
aws cloudformation delete-stack --stack-name kelpie
aws cloudformation wait stack-delete-complete --stack-name kelpie
```

RDS uses `DeletionPolicy: Delete` (no final snapshot) to match the Terraform test teardown. Change that in a fork before production data.
