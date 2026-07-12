# n8n task role: read/write its S3 binary-data bucket (KMS-encrypted) and invoke
# Bedrock models for AI-powered automations.

resource "aws_iam_role" "task" {
  name = "${var.name_prefix}-n8n-task-role"

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

resource "aws_iam_role_policy" "task" {
  name = "${var.name_prefix}-n8n-task-policy"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BinaryDataBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = ["arn:aws:s3:::${var.binary_data_bucket}"]
      },
      {
        Sid      = "BinaryDataObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["arn:aws:s3:::${var.binary_data_bucket}/*"]
      },
      {
        Sid      = "KmsForS3"
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [var.kms_key_arn]
      },
      {
        Sid      = "BedrockInvoke"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = ["*"]
      }
    ]
  })
}

# --- Bedrock credential user --------------------------------------------------
#
# n8n's AWS credential type only supports access key/secret (no task-role /
# ambient-credential option, verified against n8n 2.29.10 source), so workflow
# nodes like "AWS Bedrock Chat Model" need an IAM user. Terraform owns the user
# and policy; the ACCESS KEY is created out-of-band and pasted into n8n's
# encrypted credential store (same philosophy as the Secrets Manager
# placeholder pattern — real secrets never live in code/state):
#
#   aws iam create-access-key --user-name <clinic>-n8n-bedrock
#
# See DEPLOY.md §10.

data "aws_caller_identity" "current" {}

resource "aws_iam_user" "bedrock" {
  name = "${var.name_prefix}-n8n-bedrock"

  tags = var.tags
}

resource "aws_iam_user_policy" "bedrock" {
  name = "${var.name_prefix}-n8n-bedrock-invoke"
  user = aws_iam_user.bedrock.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Invoking via a cross-region inference profile (us.anthropic.*, the
        # required form for current Claude models) authorizes against both the
        # profile and the underlying foundation-model ARNs.
        Sid    = "InvokeAnthropicModels"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/anthropic.*",
          "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*.anthropic.*"
        ]
      },
      {
        # Populates the model dropdown in n8n's Bedrock nodes.
        Sid      = "ListModels"
        Effect   = "Allow"
        Action   = ["bedrock:ListFoundationModels", "bedrock:ListInferenceProfiles"]
        Resource = "*"
      }
    ]
  })
}
