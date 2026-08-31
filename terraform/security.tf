resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public ingress to Kelpie ALB"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name}-alb"
  }
}

resource "aws_security_group" "tasks" {
  name        = "${local.name}-tasks"
  description = "Kelpie Fargate web and worker tasks"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name}-tasks"
  }
}

resource "aws_security_group" "database" {
  name        = "${local.name}-database"
  description = "Private PostgreSQL access from Kelpie tasks"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name}-database"
  }
}

resource "aws_security_group" "cache" {
  name        = "${local.name}-cache"
  description = "Private Redis access from Kelpie tasks"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name}-cache"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb" {
  for_each = local.alb_ingress_rules

  security_group_id = aws_security_group.alb.id
  description       = each.value.port == 443 ? "HTTPS" : "HTTP"
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value.cidr

  lifecycle {
    precondition {
      condition = var.allow_internet_ingress || alltrue([
        for cidr in var.allowed_ingress_cidrs : cidr != "0.0.0.0/0" && cidr != "::/0"
      ])
      error_message = "0.0.0.0/0 and ::/0 are blocked on the ALB unless allow_internet_ingress is true."
    }
  }
}

resource "aws_vpc_security_group_egress_rule" "alb_to_web" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Web task traffic"
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.tasks.id
}

resource "aws_vpc_security_group_ingress_rule" "web_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "ALB to web task"
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "tasks_https" {
  security_group_id = aws_security_group.tasks.id
  description       = "HTTPS dependencies and GHCR image pulls"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "tasks_dns_udp" {
  security_group_id = aws_security_group.tasks.id
  description       = "VPC DNS over UDP"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "tasks_dns_tcp" {
  security_group_id = aws_security_group.tasks.id
  description       = "VPC DNS over TCP"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "tasks_to_database" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "PostgreSQL"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.database.id
}

resource "aws_vpc_security_group_ingress_rule" "database_from_tasks" {
  security_group_id            = aws_security_group.database.id
  description                  = "PostgreSQL from tasks"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.tasks.id
}

resource "aws_vpc_security_group_egress_rule" "tasks_to_cache" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "Redis TLS"
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.cache.id
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_tasks" {
  security_group_id            = aws_security_group.cache.id
  description                  = "Redis from tasks"
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.tasks.id
}
