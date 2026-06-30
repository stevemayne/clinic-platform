output "kms_key_arn" {
  value = aws_kms_key.this.arn
}

output "kms_key_id" {
  value = aws_kms_key.this.key_id
}

output "db_address" {
  description = "RDS endpoint hostname."
  value       = aws_db_instance.this.address
}

output "db_port" {
  value = aws_db_instance.this.port
}

output "db_master_secret_arn" {
  description = "ARN of the AWS-managed master user password secret."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}

output "binary_data_bucket" {
  value = aws_s3_bucket.this["binary"].id
}

output "documents_bucket" {
  value = aws_s3_bucket.this["documents"].id
}
