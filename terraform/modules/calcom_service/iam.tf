# Minimal task role — Cal.com makes no AWS API calls in the base setup (email is
# via SMTP). Kept for a stable ARN and easy future grants (e.g. SES).

resource "aws_iam_role" "task" {
  name = "${var.name_prefix}-calcom-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = var.tags
}
