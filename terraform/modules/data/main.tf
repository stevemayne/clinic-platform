# Per-clinic data layer: one customer-managed KMS key, one RDS Postgres
# instance (hosting the `n8n` and `calcom` databases — created by the app
# init step, not Terraform, since the DB is private), and encrypted S3 buckets.

# --- KMS --------------------------------------------------------------------

resource "aws_kms_key" "this" {
  description             = "${var.name_prefix} clinic CMK (RDS, S3, secrets)."
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-cmk" })
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.name_prefix}-clinic"
  target_key_id = aws_kms_key.this.key_id
}

# --- RDS Postgres -----------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-rds"
  subnet_ids = var.private_subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-rds" })
}

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds-sg"
  description = "Allow PostgreSQL from ECS tasks."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-rds-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_ecs" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from ECS tasks"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = var.ecs_security_group_id
}

resource "aws_db_parameter_group" "this" {
  name        = "${var.name_prefix}-postgres17"
  family      = "postgres17"
  description = "${var.name_prefix}: connection logging enabled for audit."

  parameter {
    name         = "log_connections"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_disconnections"
    value        = "1"
    apply_method = "immediate"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-postgres17" })
}

resource "aws_db_instance" "this" {
  identifier = "${var.name_prefix}-db"

  engine         = "postgres"
  engine_version = "17.9"
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.this.arn

  multi_az               = var.multi_az
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # AWS-managed master password, stored in its own Secrets Manager secret.
  # The `n8n` and `calcom` databases + least-privilege roles are created by
  # the application init step (one-off task / psql), not Terraform.
  username                      = "postgres"
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.this.arn
  port                          = 5432

  backup_retention_period    = 7
  auto_minor_version_upgrade = true
  maintenance_window         = "wed:01:00-wed:02:00"
  backup_window              = "23:00-23:30"

  deletion_protection          = var.deletion_protection
  copy_tags_to_snapshot        = true
  skip_final_snapshot          = false
  final_snapshot_identifier    = "${var.name_prefix}-db-final"
  performance_insights_enabled = true

  parameter_group_name = aws_db_parameter_group.this.name

  tags = merge(var.tags, { Name = "${var.name_prefix}-db" })
}

# --- S3 buckets -------------------------------------------------------------

locals {
  buckets = {
    binary    = "${var.name_prefix}-n8n-binary-data"
    documents = "${var.name_prefix}-documents"
  }
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets
  bucket   = each.value

  tags = merge(var.tags, { Name = each.value })
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.this.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
