#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -d "${script_dir}/../../../marketplace" ]]; then
  evidence_file="${script_dir}/../../../marketplace/evidence/aws-fargate-deploy.md"
else
  evidence_file="${script_dir}/evidence/aws-fargate-deploy.md"
fi
terraform_args=("$@")

for command in terraform aws jq curl; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required command not found: ${command}" >&2
    exit 1
  fi
done

cd "${script_dir}"
terraform init

dump_log_group() {
  local group=$1
  local streams
  if ! streams=$(aws logs describe-log-streams \
    --region "${region}" \
    --log-group-name "${group}" \
    --order-by LastEventTime \
    --descending \
    --limit 2 \
    --query 'logStreams[].logStreamName' \
    --output text 2>/dev/null); then
    echo "(no log group ${group})" >&2
    return 0
  fi
  if [[ -z "${streams}" || "${streams}" == "None" ]]; then
    echo "(no streams in ${group})" >&2
    return 0
  fi
  local stream
  for stream in ${streams}; do
    echo "--- ${group} ${stream} ---" >&2
    aws logs get-log-events \
      --region "${region}" \
      --log-group-name "${group}" \
      --log-stream-name "${stream}" \
      --limit 40 \
      --start-from-head \
      --query 'events[].message' \
      --output text >&2 || true
  done
}

dump_service_diagnostics() {
  echo "ECS service diagnostics" >&2
  aws ecs describe-services \
    --region "${region}" \
    --cluster "${cluster}" \
    --services "${local_name}-web" "${local_name}-worker" \
    --query 'services[].{name:serviceName,status:status,desired:desiredCount,running:runningCount,rollout:deployments[].{state:rolloutState,reason:rolloutStateReason,failed:failedTasks},events:events[:8].message}' \
    --output json >&2 || true

  local stopped
  stopped=$(aws ecs list-tasks \
    --region "${region}" \
    --cluster "${cluster}" \
    --desired-status STOPPED \
    --query 'taskArns' \
    --output json)
  if [[ "${stopped}" != "[]" ]]; then
    aws ecs describe-tasks \
      --region "${region}" \
      --cluster "${cluster}" \
      --tasks $(jq -r '.[]' <<<"${stopped}") \
      --query 'tasks[].{group:group,stoppedReason:stoppedReason,exit:containers[0].exitCode}' \
      --output json >&2 || true
  fi

  dump_log_group "/ecs/${local_name}/web"
  dump_log_group "/ecs/${local_name}/worker"
  dump_log_group "/ecs/${local_name}/migration"
}

preflight_marketplace_license() {
  # Read-only. CheckoutLicense from this CLI identity holds the listing's
  # MaxCount=1 seat for ~60 minutes and Fargate tasks cannot share it.
  echo "Preflight: list-received-licenses in us-east-1 (does not consume the seat)"
  local licenses
  licenses=$(aws license-manager list-received-licenses --region us-east-1 --output json)
  local available
  available=$(jq -r '
    [.Licenses[]? | select(.Status == "AVAILABLE" or .Status == "ACTIVE")] | length
  ' <<<"${licenses}")
  if [[ "${available}" == "0" ]]; then
    echo "No AVAILABLE License Manager licenses in this account." >&2
    echo "Subscribe on the Kelpie AWS Marketplace listing before launching tasks." >&2
    exit 1
  fi
  echo "Found ${available} AVAILABLE license(s)."
}

# Clean-account bootstrap: build data plane and task definitions first, run
# migration, then create long-running services only after migration succeeds.
terraform apply -auto-approve "${terraform_args[@]}" -var enable_services=false

region=$(terraform output -raw aws_region)
cluster=$(terraform output -raw ecs_cluster_name)
local_name=$(terraform output -raw stack_name)
migration_definition=$(terraform output -raw migration_task_definition_arn)
security_group=$(terraform output -raw task_security_group_id)
subnets=$(terraform output -json application_subnet_ids | jq -r 'join(",")')
network="awsvpcConfiguration={subnets=[${subnets}],securityGroups=[${security_group}],assignPublicIp=DISABLED}"

preflight_marketplace_license

run_task() {
  local label=$1
  local overrides=${2:-}
  local args=(
    ecs run-task
    --region "${region}"
    --cluster "${cluster}"
    --launch-type FARGATE
    --platform-version LATEST
    --task-definition "${migration_definition}"
    --network-configuration "${network}"
  )
  if [[ -n "${overrides}" ]]; then
    args+=(--overrides "${overrides}")
  fi

  local task_arn
  task_arn=$(aws "${args[@]}" --query 'tasks[0].taskArn' --output text)
  if [[ -z "${task_arn}" || "${task_arn}" == "None" ]]; then
    echo "${label} task did not start" >&2
    dump_service_diagnostics
    exit 1
  fi

  aws ecs wait tasks-stopped --region "${region}" --cluster "${cluster}" --tasks "${task_arn}"

  local exit_code
  exit_code=$(aws ecs describe-tasks \
    --region "${region}" \
    --cluster "${cluster}" \
    --tasks "${task_arn}" \
    --query 'tasks[0].containers[0].exitCode' \
    --output text)
  if [[ "${exit_code}" != "0" ]]; then
    aws ecs describe-tasks \
      --region "${region}" \
      --cluster "${cluster}" \
      --tasks "${task_arn}" \
      --query 'tasks[0].{stoppedReason:stoppedReason,containers:containers[].{name:name,reason:reason,exitCode:exitCode}}'
    dump_log_group "/ecs/${local_name}/migration"
    exit 1
  fi

  printf '%s' "${task_arn}"
}

migration_task_arn=$(run_task "migration")

proof_key="uploads/deployment-proof-$(date -u +%Y%m%dT%H%M%SZ).txt"
proof_script="const {S3Client,PutObjectCommand}=require('@aws-sdk/client-s3');new S3Client({}).send(new PutObjectCommand({Bucket:process.env.S3_BUCKET,Key:process.env.STORAGE_PROOF_KEY,Body:'Kelpie Fargate storage proof\\n',ContentType:'text/plain'})).then(()=>console.log('stored '+process.env.STORAGE_PROOF_KEY)).catch(e=>{console.error(e);process.exit(1)})"
storage_overrides=$(jq -nc \
  --arg key "${proof_key}" \
  --arg script "${proof_script}" \
  '{containerOverrides:[{name:"migration",command:["node","-e",$script],environment:[{name:"STORAGE_PROOF_KEY",value:$key}]}]}')
storage_task_arn=$(run_task "storage proof" "${storage_overrides}")

if ! terraform apply -auto-approve "${terraform_args[@]}" -var enable_services=true; then
  dump_service_diagnostics
  exit 1
fi

application_url=$(terraform output -raw application_url)
for attempt in $(seq 1 30); do
  if live_response=$(curl -fsS "${application_url}/api/health") && ready_response=$(curl -fsS "${application_url}/api/health"); then
    break
  fi
  if [[ "${attempt}" == "30" ]]; then
    echo "Health probes did not become ready: ${application_url}" >&2
    dump_service_diagnostics
    exit 1
  fi
  sleep 10
done

account_id=$(terraform output -raw aws_account_id)
image=$(terraform output -raw container_image)
web_definition=$(terraform output -raw web_task_definition_arn)
worker_definition=$(terraform output -raw worker_task_definition_arn)
bucket=$(terraform output -raw evidence_bucket_name)
log_group=$(terraform output -raw migration_log_group_name)
deployed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$(dirname "${evidence_file}")"
cat >"${evidence_file}" <<EOF
# AWS Fargate deployment evidence

- Recorded: ${deployed_at}
- AWS account: ${account_id}
- Region: ${region}
- URL: ${application_url}
- Image: \`${image}\`
- Web task definition: \`${web_definition}\`
- Worker task definition: \`${worker_definition}\`
- Migration task: \`${migration_task_arn}\`
- Storage proof task: \`${storage_task_arn}\`
- CloudWatch log group: \`${log_group}\`
- Evidence bucket: \`${bucket}\`
- Storage proof object: \`s3://${bucket}/${proof_key}\`

## Probe results

\`/api/health\`:

\`\`\`json
$(printf '%s' "${live_response}" | jq -c .)
\`\`\`

\`/api/health\`:

\`\`\`json
$(printf '%s' "${ready_response}" | jq -c .)
\`\`\`

## Teardown

Not yet recorded. Run \`KELPIE_ALLOW_DESTROY=yes ./destroy.sh <same Terraform arguments>\`.
EOF

echo "Deployment healthy: ${application_url}"
echo "Evidence written: ${evidence_file}"
