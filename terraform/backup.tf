data "aws_iam_policy_document" "backup_assume_role" {
  count = var.enable_aws_backup ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "backup" {
  count = var.enable_aws_backup ? 1 : 0

  name               = "${local.name}-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume_role[0].json
}

resource "aws_iam_role_policy_attachment" "backup" {
  count = var.enable_aws_backup ? 1 : 0

  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_s3" {
  count = var.enable_aws_backup ? 1 : 0

  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Backup"
}

resource "aws_iam_role_policy_attachment" "restore_s3" {
  count = var.enable_aws_backup ? 1 : 0

  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Restore"
}

resource "aws_backup_vault" "this" {
  count = var.enable_aws_backup ? 1 : 0

  name          = "${local.name}-backup"
  kms_key_arn   = aws_kms_key.this.arn
  force_destroy = var.force_destroy_backup_vault
}

resource "aws_backup_plan" "this" {
  count = var.enable_aws_backup ? 1 : 0

  name = "${local.name}-daily"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this[0].name
    schedule          = "cron(0 16 * * ? *)"

    lifecycle {
      delete_after = var.backup_retention_days
    }
  }
}

resource "aws_backup_selection" "protected" {
  count = var.enable_aws_backup ? 1 : 0

  iam_role_arn = aws_iam_role.backup[0].arn
  name         = "${local.name}-protected"
  plan_id      = aws_backup_plan.this[0].id
  resources = [
    aws_db_instance.this.arn,
    aws_s3_bucket.evidence.arn,
  ]

  depends_on = [
    aws_iam_role_policy_attachment.backup,
    aws_iam_role_policy_attachment.backup_s3,
    aws_iam_role_policy_attachment.restore_s3,
  ]
}
