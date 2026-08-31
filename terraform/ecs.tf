resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "web" {
  name              = "/ecs/${local.name}/web"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${local.name}/worker"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn
}

resource "aws_cloudwatch_log_group" "migration" {
  name              = "/ecs/${local.name}/migration"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.this.arn
}

resource "aws_ecs_task_definition" "web" {
  family                   = "${local.name}-web"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.web_cpu)
  memory                   = tostring(var.web_memory)
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    merge(local.container_hardening, {
      name      = "web"
      image     = var.container_image
      essential = true
      command   = ["node", "server.js"]
      portMappings = [
        {
          name          = "http"
          containerPort = 3000
          hostPort      = 3000
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]
      environment = concat(local.common_environment, local.ses_environment, local.marketplace_environment)
      secrets     = local.common_secrets
      healthCheck = {
        command     = ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 180
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.web.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "web"
        }
      }
      }, var.container_registry_credentials_secret_arn == null ? {} : {
      repositoryCredentials = {
        credentialsParameter = var.container_registry_credentials_secret_arn
      }
    })
  ])

  depends_on = [
    aws_iam_role_policy_attachment.execution,
    aws_iam_role_policy.execution_secrets,
    aws_secretsmanager_secret_version.runtime,
  ]
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${local.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.worker_cpu)
  memory                   = tostring(var.worker_memory)
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    merge(local.container_hardening, {
      name        = "worker"
      image       = var.container_image
      essential   = true
      command     = ["node", "dist/jobs-worker.cjs"]
      environment = concat(local.common_environment, local.ses_environment, local.marketplace_environment)
      secrets     = local.common_secrets
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.worker.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "worker"
        }
      }
      }, var.container_registry_credentials_secret_arn == null ? {} : {
      repositoryCredentials = {
        credentialsParameter = var.container_registry_credentials_secret_arn
      }
    })
  ])

  depends_on = [
    aws_iam_role_policy_attachment.execution,
    aws_iam_role_policy.execution_secrets,
    aws_secretsmanager_secret_version.runtime,
  ]
}

resource "aws_ecs_task_definition" "migration" {
  family                   = "${local.name}-migration"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.migration_cpu)
  memory                   = tostring(var.migration_memory)
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    merge(local.container_hardening, {
      name        = "migration"
      image       = var.container_image
      essential   = true
      command     = ["node", "dist/migrate.cjs"]
      environment = concat(local.common_environment, local.ses_environment, local.marketplace_environment)
      secrets     = local.common_secrets
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.migration.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "migration"
        }
      }
      }, var.container_registry_credentials_secret_arn == null ? {} : {
      repositoryCredentials = {
        credentialsParameter = var.container_registry_credentials_secret_arn
      }
    })
  ])

  depends_on = [
    aws_iam_role_policy_attachment.execution,
    aws_iam_role_policy.execution_secrets,
    aws_secretsmanager_secret_version.runtime,
  ]
}

resource "aws_ecs_service" "web" {
  count = var.enable_services ? 1 : 0

  name             = "${local.name}-web"
  cluster          = aws_ecs_cluster.this.id
  task_definition  = aws_ecs_task_definition.web.arn
  desired_count    = var.web_desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  enable_ecs_managed_tags           = true
  health_check_grace_period_seconds = 180
  propagate_tags                    = "SERVICE"
  wait_for_steady_state             = true

  deployment_circuit_breaker {
    enable   = true
    rollback = false
  }

  network_configuration {
    assign_public_ip = false
    security_groups  = [aws_security_group.tasks.id]
    subnets          = aws_subnet.application[*].id
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.web.arn
    container_name   = "web"
    container_port   = 3000
  }

  depends_on = [
    aws_lb_listener.http,
    aws_lb_listener.https,
    aws_iam_role_policy_attachment.execution,
    aws_db_instance.this,
    aws_elasticache_replication_group.this,
  ]
}

resource "aws_ecs_service" "worker" {
  count = var.enable_services ? 1 : 0

  name             = "${local.name}-worker"
  cluster          = aws_ecs_cluster.this.id
  task_definition  = aws_ecs_task_definition.worker.arn
  desired_count    = var.worker_desired_count
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"
  wait_for_steady_state   = true

  deployment_circuit_breaker {
    enable   = true
    rollback = false
  }

  network_configuration {
    assign_public_ip = false
    security_groups  = [aws_security_group.tasks.id]
    subnets          = aws_subnet.application[*].id
  }

  depends_on = [
    aws_iam_role_policy_attachment.execution,
    aws_db_instance.this,
    aws_elasticache_replication_group.this,
  ]
}
