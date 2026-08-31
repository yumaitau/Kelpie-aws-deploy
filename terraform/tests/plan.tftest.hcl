mock_provider "aws" {
  override_during = plan

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-southeast-2a", "ap-southeast-2b"]
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

mock_provider "random" {
  override_during = plan
}

variables {
  container_image       = "ghcr.io/yumaitau/kelpie@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  allowed_ingress_cidrs = ["203.0.113.0/24"]
  cpu_architecture      = "X86_64"
}

run "secure_test_baseline" {
  command = plan

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false
    error_message = "RDS must not be publicly accessible."
  }

  assert {
    condition     = aws_ecs_task_definition.web.runtime_platform[0].cpu_architecture == "X86_64"
    error_message = "Fargate web task must explicitly target amd64."
  }

  assert {
    condition     = local.container_hardening.user == "kelpie"
    error_message = "Fargate web task must run as the image non-root user."
  }

  assert {
    condition = contains(
      local.container_hardening.linuxParameters.capabilities.drop,
      "ALL",
    )
    error_message = "Fargate web task must drop all Linux capabilities."
  }

  assert {
    condition = anytrue([
      for variable in local.common_environment :
      variable.name == "HOSTNAME" && variable.value == "0.0.0.0"
    ])
    error_message = "Fargate web task must bind Next.js to all interfaces so loopback health checks work."
  }

  assert {
    condition = anytrue([
      for variable in local.common_environment :
      variable.name == "SIGNUP_MODE" && variable.value == "open"
    ])
    error_message = "Fargate tasks must allow the first administrator to self-register."
  }

  assert {
    condition = anytrue([
      for variable in local.common_environment :
      variable.name == "NEXT_PUBLIC_SIGNUP_MODE" && variable.value == "open"
    ])
    error_message = "Fargate tasks must advertise open sign-up for the first administrator."
  }

  assert {
    condition     = aws_ecs_service.web[0].network_configuration[0].assign_public_ip == false
    error_message = "Web tasks must not receive public IPs."
  }

  assert {
    condition     = aws_ecs_service.web[0].deployment_circuit_breaker[0].enable && !aws_ecs_service.web[0].deployment_circuit_breaker[0].rollback
    error_message = "First-create services must not request circuit-breaker rollback; ECS has no prior revision."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.evidence.block_public_policy
    error_message = "Evidence bucket must block public policies."
  }

  assert {
    condition     = aws_elasticache_replication_group.this.transit_encryption_enabled
    error_message = "Redis traffic must require TLS."
  }

  assert {
    condition = alltrue([
      for rule in aws_vpc_security_group_ingress_rule.alb : rule.cidr_ipv4 != "0.0.0.0/0" && rule.cidr_ipv4 != "::/0"
    ])
    error_message = "ALB ingress must not default to the public internet."
  }

  assert {
    condition     = aws_flow_log.this.traffic_type == "ALL"
    error_message = "VPC flow logs must capture all traffic."
  }
}

run "reject_world_open_ingress" {
  command = plan

  variables {
    allowed_ingress_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [aws_vpc_security_group_ingress_rule.alb]
}

run "allow_world_open_ingress_when_explicit" {
  command = plan

  variables {
    allowed_ingress_cidrs  = ["0.0.0.0/0"]
    allow_internet_ingress = true
  }

  assert {
    condition = anytrue([
      for rule in aws_vpc_security_group_ingress_rule.alb : rule.cidr_ipv4 == "0.0.0.0/0"
    ])
    error_message = "allow_internet_ingress must be able to open the ALB when the buyer opts in."
  }
}

run "migration_only_bootstrap" {
  command = plan

  variables {
    enable_services = false
  }

  assert {
    condition     = length(aws_ecs_service.web) == 0 && length(aws_ecs_service.worker) == 0
    error_message = "Bootstrap must be able to run migration before services exist."
  }
}

run "marketplace_identity_is_not_buyer_configurable" {
  command = plan

  variables {
    marketplace_product_code              = "buyer-forged-product-code"
    marketplace_product_sku               = "buyer-forged-product-sku"
    marketplace_enforce_container_license = false
  }

  assert {
    condition     = length(local.marketplace_environment) == 0
    error_message = "Marketplace product identity and license flags must not be injected into the task environment."
  }

  assert {
    condition = !anytrue([
      for variable in concat(local.common_environment, local.marketplace_environment) :
      contains([
        "AWS_MARKETPLACE_ENFORCE_CONTAINER_LICENSE",
        "AWS_MARKETPLACE_PRODUCT_CODE",
        "AWS_MARKETPLACE_PRODUCT_SKU",
        "AWS_MARKETPLACE_ENABLED",
      ], variable.name)
    ])
    error_message = "Buyer environment must not include Marketplace license controls."
  }

  assert {
    condition     = aws_ecs_service.web[0].deployment_circuit_breaker[0].enable && !aws_ecs_service.web[0].deployment_circuit_breaker[0].rollback
    error_message = "First-create services must not request circuit-breaker rollback."
  }
}

run "reject_latest_image" {
  command = plan

  variables {
    container_image = "ghcr.io/yumaitau/kelpie:latest"
  }

  expect_failures = [var.container_image]
}

run "reject_unproven_region" {
  command = plan

  variables {
    aws_region = "eu-west-2"
  }

  expect_failures = [var.aws_region]
}
