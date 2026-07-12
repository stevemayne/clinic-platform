# Clinician chat UI: Open WebUI backed by the clinic RDS Postgres, with a
# LiteLLM sidecar translating OpenAI-compatible calls to Bedrock.
#
# Why not LibreChat (the original M4 candidate)? LibreChat requires MongoDB —
# either DocumentDB (~$60+/mo per clinic) or a self-managed mongod holding PHI.
# Open WebUI runs entirely on the existing encrypted, backed-up RDS instance
# (app data + pgvector RAG store in the `chatui` database), so the only new
# moving part is the stateless LiteLLM gateway; both containers authenticate
# to AWS via the task role — no long-lived keys.
#
# The `chatui` role/database are created by the app init step, not Terraform
# (same as n8n/calcom — see DEPLOY.md §7); the init step also runs
# CREATE EXTENSION vector.

resource "aws_cloudwatch_log_group" "chat" {
  name              = "/ecs/${var.name_prefix}-chat"
  retention_in_days = 30
  tags              = var.tags
}

# LiteLLM reads its model list from S3 (LITELLM_CONFIG_BUCKET_*) — no config
# volume needed on Fargate, and the model catalog stays Terraform-owned.
resource "aws_s3_object" "litellm_config" {
  bucket = var.documents_bucket
  key    = "chat/litellm-config.yaml"

  content = yamlencode({
    model_list = [for m in var.bedrock_models : {
      model_name = m.name
      litellm_params = {
        model           = "bedrock/${m.model_id}"
        aws_region_name = var.aws_region
      }
    }]
  })

  content_type = "application/yaml"

  tags = var.tags
}

locals {
  oauth_enabled = var.oauth_client_id != ""

  webui_environment = concat(
    [
      { name = "WEBUI_URL", value = "https://${local.fqdn}" },
      { name = "PORT", value = tostring(local.container_port) },
      # Keep the task definition authoritative: Open WebUI otherwise persists
      # most of these to the DB on first boot and ignores later env changes.
      { name = "ENABLE_PERSISTENT_CONFIG", value = "false" },

      # App data + RAG vectors both land in the chatui database (PGVECTOR_DB_URL
      # defaults to DATABASE_URL). The default chroma vector store writes to
      # local disk, which is ephemeral on Fargate.
      { name = "VECTOR_DB", value = "pgvector" },

      # Models come exclusively from the LiteLLM sidecar (same task, shared
      # localhost under awsvpc).
      { name = "ENABLE_OLLAMA_API", value = "false" },
      { name = "ENABLE_OPENAI_API", value = "true" },
      { name = "OPENAI_API_BASE_URL", value = "http://localhost:${local.litellm_port}/v1" },
      { name = "DEFAULT_MODELS", value = var.default_model },

      # Uploads go to S3 — local disk is ephemeral. Credentials come from the
      # task role (no S3_ACCESS_KEY_ID set -> boto3 default chain).
      { name = "STORAGE_PROVIDER", value = "s3" },
      { name = "S3_BUCKET_NAME", value = var.documents_bucket },
      { name = "S3_KEY_PREFIX", value = "chat/uploads" },
      { name = "S3_REGION_NAME", value = var.aws_region },
      { name = "AWS_REGION", value = var.aws_region },
    ],
    # Until the clinic's Google OAuth client exists, fall back to local login
    # so the first user (= admin) can be claimed; flipping oauth_client_id
    # switches to SSO-only. New SSO users are provisioned JIT as plain users.
    local.oauth_enabled ? [
      { name = "ENABLE_LOGIN_FORM", value = "false" },
      { name = "ENABLE_SIGNUP", value = "false" },
      { name = "ENABLE_OAUTH_SIGNUP", value = "true" },
      { name = "OAUTH_AUTO_REDIRECT", value = "true" },
      { name = "OAUTH_CLIENT_ID", value = var.oauth_client_id },
      { name = "OPENID_PROVIDER_URL", value = "https://accounts.google.com/.well-known/openid-configuration" },
      { name = "OAUTH_SCOPES", value = "openid email profile" },
      { name = "OAUTH_PROVIDER_NAME", value = "Google Workspace" },
      # Google verifies emails and the Internal consent screen limits sign-in
      # to the clinic's Workspace, so merging is safe here — and it lets the
      # bootstrap local admin account become an SSO account.
      { name = "OAUTH_MERGE_ACCOUNTS_BY_EMAIL", value = "true" },
      { name = "DEFAULT_USER_ROLE", value = "user" },
      ] : [
      { name = "ENABLE_LOGIN_FORM", value = "true" },
      { name = "ENABLE_SIGNUP", value = "true" },
    ],
    local.oauth_enabled && var.oauth_allowed_email_domains != "" ? [
      { name = "OAUTH_ALLOWED_DOMAINS", value = var.oauth_allowed_email_domains },
    ] : []
  )

  webui_secrets = concat(
    [
      { name = "DATABASE_URL", valueFrom = var.database_url_secret_arn },
      { name = "WEBUI_SECRET_KEY", valueFrom = var.webui_secret_key_secret_arn },
      # The sidecar's master key doubles as Open WebUI's API key for it.
      { name = "OPENAI_API_KEY", valueFrom = var.litellm_master_key_secret_arn },
    ],
    local.oauth_enabled ? [
      { name = "OAUTH_CLIENT_SECRET", valueFrom = var.oauth_client_secret_arn },
    ] : []
  )
}

resource "aws_ecs_task_definition" "chat" {
  family                   = "${var.name_prefix}-chat"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name              = local.container_name
      image             = var.open_webui_image
      essential         = true
      cpu               = var.cpu - local.litellm_cpu
      memoryReservation = var.memory - local.litellm_memory

      environment = local.webui_environment
      secrets     = local.webui_secrets

      portMappings = [
        {
          containerPort = local.container_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.chat.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
          mode                  = "non-blocking"
        }
      }
    },
    {
      name              = "${var.name_prefix}-litellm"
      image             = var.litellm_image
      essential         = true
      cpu               = local.litellm_cpu
      memoryReservation = local.litellm_memory

      environment = [
        { name = "LITELLM_CONFIG_BUCKET_TYPE", value = "s3" },
        { name = "LITELLM_CONFIG_BUCKET_NAME", value = var.documents_bucket },
        { name = "LITELLM_CONFIG_BUCKET_OBJECT_KEY", value = aws_s3_object.litellm_config.key },
        { name = "AWS_REGION", value = var.aws_region },
      ]

      secrets = [
        { name = "LITELLM_MASTER_KEY", valueFrom = var.litellm_master_key_secret_arn },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.chat.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "litellm"
          mode                  = "non-blocking"
        }
      }
    }
  ])

  tags = var.tags
}

resource "aws_ecs_service" "chat" {
  name            = "${var.name_prefix}-chat"
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.chat.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  enable_ecs_managed_tags = true
  propagate_tags          = "SERVICE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.chat.arn
    container_name   = local.container_name
    container_port   = local.container_port
  }

  depends_on = [aws_lb_listener_rule.chat]

  lifecycle {
    ignore_changes = [task_definition] # Terraform registers new revisions; point the service at them out-of-band (same as n8n)
  }

  tags = var.tags
}
