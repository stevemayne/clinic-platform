# n8n on Fargate, in "main" mode (single task, Postgres-backed). Scale to queue
# mode (Redis + workers) later — S3 binary-data mode below is forward-compatible.
#
# Image: the PoC pulls the public image directly via NAT. For production, create
# an ECR pull-through cache (avoids Docker Hub rate limits, adds scanning) and
# set var.n8n_image to the cache URI, e.g.:
#
#   resource "aws_ecr_pull_through_cache_rule" "dockerhub" {
#     ecr_repository_prefix = "docker-hub"
#     upstream_registry_url  = "registry-1.docker.io"
#     credential_arn         = <secrets-manager-arn-with-dockerhub-creds>
#   }
#   # then: <account>.dkr.ecr.<region>.amazonaws.com/docker-hub/n8nio/n8n:<tag>

resource "aws_cloudwatch_log_group" "n8n" {
  name              = "/ecs/${var.name_prefix}-n8n"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_ecs_task_definition" "n8n" {
  family                   = "${var.name_prefix}-n8n"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = var.n8n_image
      essential = true
      cpu       = var.cpu
      memory    = var.memory

      environment = [
        { name = "DB_TYPE", value = "postgresdb" },
        { name = "DB_POSTGRESDB_HOST", value = var.db_host },
        { name = "DB_POSTGRESDB_PORT", value = tostring(var.db_port) },
        { name = "DB_POSTGRESDB_DATABASE", value = var.db_name },
        { name = "DB_POSTGRESDB_USER", value = var.db_user },
        # RDS PG15+ defaults rds.force_ssl=1; node-postgres won't use TLS
        # unless told to. Cert verification stays off because the RDS CA
        # bundle isn't in the image trust store — hardening TODO: ship the
        # bundle and verify.
        { name = "DB_POSTGRESDB_SSL_ENABLED", value = "true" },
        { name = "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED", value = "false" },
        { name = "N8N_HOST", value = local.fqdn },
        { name = "N8N_PORT", value = tostring(local.container_port) },
        { name = "N8N_PROTOCOL", value = "https" },
        { name = "WEBHOOK_URL", value = "https://${local.fqdn}/" },
        { name = "N8N_EDITOR_BASE_URL", value = "https://${local.fqdn}/" },
        { name = "GENERIC_TIMEZONE", value = var.timezone },

        # Binary data to S3 (required for queue mode later). AUTH_AUTO_DETECT
        # makes n8n use the AWS default credential chain (= the task IAM role)
        # instead of demanding an access key/secret pair. Verified 2026-07.
        { name = "N8N_DEFAULT_BINARY_DATA_MODE", value = "s3" },
        { name = "N8N_EXTERNAL_STORAGE_S3_AUTH_AUTO_DETECT", value = "true" },
        # s3 must also be listed as *available* or n8n refuses to start.
        { name = "N8N_AVAILABLE_BINARY_DATA_MODES", value = "s3" },
        { name = "N8N_EXTERNAL_STORAGE_S3_HOST", value = "s3.${var.aws_region}.amazonaws.com" },
        { name = "N8N_EXTERNAL_STORAGE_S3_BUCKET_NAME", value = var.binary_data_bucket },
        { name = "N8N_EXTERNAL_STORAGE_S3_BUCKET_REGION", value = var.aws_region },

        # Keep PHI out of long-lived execution logs.
        { name = "EXECUTIONS_DATA_PRUNE", value = "true" },
        { name = "EXECUTIONS_DATA_MAX_AGE", value = "168" }, # hours (7 days)
      ]

      secrets = [
        { name = "N8N_ENCRYPTION_KEY", valueFrom = var.encryption_key_secret_arn },
        { name = "DB_POSTGRESDB_PASSWORD", valueFrom = var.db_password_secret_arn },
      ]

      portMappings = [
        {
          containerPort = local.container_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.n8n.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
          mode                  = "non-blocking"
        }
      }
    }
  ])

  tags = var.tags
}

resource "aws_ecs_service" "n8n" {
  name            = "${var.name_prefix}-n8n"
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.n8n.arn
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
    target_group_arn = aws_lb_target_group.n8n.arn
    container_name   = local.container_name
    container_port   = local.container_port
  }

  depends_on = [aws_lb_listener_rule.n8n]

  lifecycle {
    ignore_changes = [task_definition] # CD updates the image
  }

  tags = var.tags
}
