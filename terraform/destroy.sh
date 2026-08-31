#!/usr/bin/env bash
set -euo pipefail

if [[ "${KELPIE_ALLOW_DESTROY:-}" != "yes" ]]; then
  echo "Refusing destroy. Set KELPIE_ALLOW_DESTROY=yes after checking account, region, and workspace." >&2
  exit 1
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -d "${script_dir}/../../../marketplace" ]]; then
  evidence_file="${script_dir}/../../../marketplace/evidence/aws-fargate-deploy.md"
else
  evidence_file="${script_dir}/evidence/aws-fargate-deploy.md"
fi

cd "${script_dir}"
account_id=$(terraform output -raw aws_account_id)
region=$(terraform output -raw aws_region)

echo "Destroying Kelpie resources in AWS account ${account_id}, region ${region}."
terraform destroy -auto-approve "$@"

destroyed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ -f "${evidence_file}" ]]; then
  cat >>"${evidence_file}" <<EOF

Destroy completed: ${destroyed_at} in account ${account_id}, region ${region}.
EOF
fi

echo "Destroy complete."

