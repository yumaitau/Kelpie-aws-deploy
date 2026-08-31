output "application_url" {
  description = "Public Kelpie URL."
  value       = local.application_url
}

output "container_image" {
  description = "Immutable image reference used by every task definition."
  value       = var.container_image
}

output "migration_log_group_name" {
  description = "CloudWatch log group for migration and storage proof tasks."
  value       = aws_cloudwatch_log_group.migration.name
}

output "load_balancer_dns_name" {
  description = "ALB DNS name."
  value       = aws_lb.web.dns_name
}

output "ecs_cluster_name" {
  description = "ECS cluster used by services and one-shot tasks."
  value       = aws_ecs_cluster.this.name
}

output "web_task_definition_arn" {
  description = "Pinned web task definition revision."
  value       = aws_ecs_task_definition.web.arn
}

output "worker_task_definition_arn" {
  description = "Pinned worker task definition revision."
  value       = aws_ecs_task_definition.worker.arn
}

output "migration_task_definition_arn" {
  description = "One-shot migration task definition revision."
  value       = aws_ecs_task_definition.migration.arn
}

output "web_service_arn" {
  description = "Web ECS service ARN, or null during migration-only bootstrap."
  value       = try(aws_ecs_service.web[0].id, null)
}

output "worker_service_arn" {
  description = "Worker ECS service ARN, or null during migration-only bootstrap."
  value       = try(aws_ecs_service.worker[0].id, null)
}

output "application_subnet_ids" {
  description = "Private subnets for Fargate tasks."
  value       = aws_subnet.application[*].id
}

output "task_security_group_id" {
  description = "Security group for Fargate tasks."
  value       = aws_security_group.tasks.id
}

output "database_endpoint" {
  description = "Private RDS endpoint."
  value       = aws_db_instance.this.endpoint
}

output "cache_endpoint" {
  description = "Private TLS Redis endpoint."
  value       = "${aws_elasticache_replication_group.this.primary_endpoint_address}:6379"
}

output "evidence_bucket_name" {
  description = "Private KMS-encrypted S3 evidence bucket."
  value       = aws_s3_bucket.evidence.id
}

output "runtime_secret_arn" {
  description = "Secrets Manager ARN referenced by task definitions. Secret values are never output."
  value       = aws_secretsmanager_secret.runtime.arn
}

output "aws_account_id" {
  description = "Account that owns this deployment."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "Deployment region."
  value       = var.aws_region
}

output "stack_name" {
  description = "Name prefix used for the ECS cluster and log groups."
  value       = local.name
}

output "marketplace_license_enforcement" {
  description = "Marketplace images always enforce CheckoutLicense. Deployment configuration cannot disable it."
  value       = "mandatory"
}
