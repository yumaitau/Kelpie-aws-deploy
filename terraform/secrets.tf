resource "random_password" "better_auth" {
  length  = 48
  special = false
}

resource "random_password" "auth" {
  length  = 48
  special = false
}

resource "random_password" "app" {
  length  = 48
  special = false
}

resource "random_password" "server_actions" {
  length  = 48
  special = false
}

resource "random_password" "cron" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "runtime" {
  name_prefix             = "${local.name}-runtime-"
  description             = "Kelpie runtime connection strings and application secrets"
  kms_key_id              = aws_kms_key.this.arn
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "runtime" {
  secret_id = aws_secretsmanager_secret.runtime.id
  secret_string = jsonencode({
    DATABASE_URL                       = "postgresql://kelpieadmin:${random_password.database.result}@${aws_db_instance.this.address}:5432/kelpie?sslmode=require"
    REDIS_URL                          = "rediss://:${random_password.cache.result}@${aws_elasticache_replication_group.this.primary_endpoint_address}:6379"
    VALKEY_URL                         = "rediss://:${random_password.cache.result}@${aws_elasticache_replication_group.this.primary_endpoint_address}:6379"
    BETTER_AUTH_SECRET                 = random_password.better_auth.result
    AUTH_SECRET                        = random_password.auth.result
    APP_SECRET                         = random_password.app.result
    CRON_SECRET                        = random_password.cron.result
    NEXT_SERVER_ACTIONS_ENCRYPTION_KEY = random_password.server_actions.result
  })
}

