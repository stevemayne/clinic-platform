# Chat task role: invoke Anthropic models on Bedrock (both containers use the
# default AWS credential chain — no long-lived keys) and read/write the chat
# prefixes of the documents bucket (uploads + LiteLLM config, KMS-encrypted).

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "task" {
  name = "${var.name_prefix}-chat-task-role"

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
  name = "${var.name_prefix}-chat-task-policy"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Invoking via a cross-region inference profile (us.anthropic.*)
        # authorizes against both the profile and the underlying
        # foundation-model ARNs.
        Sid    = "InvokeAnthropicModels"
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/anthropic.*",
          "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*.anthropic.*"
        ]
      },
      {
        Sid      = "ChatBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = ["arn:aws:s3:::${var.documents_bucket}"]
        Condition = {
          StringLike = { "s3:prefix" = "chat/*" }
        }
      },
      {
        Sid      = "ChatUploads"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["arn:aws:s3:::${var.documents_bucket}/chat/uploads/*"]
      },
      {
        Sid      = "LitellmConfigRead"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["arn:aws:s3:::${var.documents_bucket}/${aws_s3_object.litellm_config.key}"]
      },
      {
        Sid      = "KmsForS3"
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [var.kms_key_arn]
      }
    ]
  })
}
