resource "aws_cloudwatch_log_group" "calcom" {
  name              = "/ecs/${var.name_prefix}-calcom"
  retention_in_days = 30
  tags              = var.tags
}

locals {
  # Authoritative NEXT_PUBLIC_WEBAPP_URL is the build arg in CI; set at runtime
  # too as a fallback (newer Cal.com tolerates this with a brief startup delay).
  app_environment = [
    { name = "NEXTAUTH_URL", value = "https://${local.fqdn}" },
    { name = "NEXT_PUBLIC_WEBAPP_URL", value = "https://${local.fqdn}" },
    # RDS PG15+ defaults rds.force_ssl=1; Cal.com's node-postgres driver
    # adapter won't use TLS unless told to (Prisma's migrate engine does,
    # so the migrate task is unaffected). "no-verify" = TLS on, cert
    # verification off — the RDS CA bundle isn't in the image trust store;
    # hardening TODO: ship the bundle and use verify-full.
    { name = "PGSSLMODE", value = "no-verify" },
  ]

  app_secrets = [
    { name = "DATABASE_URL", valueFrom = var.database_url_secret_arn },
    # Prisma's directUrl (pooler bypass) — no PgBouncer here, so same URL.
    { name = "DATABASE_DIRECT_URL", valueFrom = var.database_url_secret_arn },
    { name = "NEXTAUTH_SECRET", valueFrom = var.nextauth_secret_arn },
    { name = "CALENDSO_ENCRYPTION_KEY", valueFrom = var.encryption_key_secret_arn },
  ]
}

resource "aws_ecs_task_definition" "calcom" {
  family                   = "${var.name_prefix}-calcom"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name        = local.container_name
      image       = local.image
      essential   = true
      cpu         = var.cpu
      memory      = var.memory
      environment = local.app_environment
      secrets     = local.app_secrets

      portMappings = [
        {
          containerPort = local.container_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.calcom.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
          mode                  = "non-blocking"
        }
      }
    }
  ])

  tags = var.tags
}

resource "aws_ecs_service" "calcom" {
  name            = "${var.name_prefix}-calcom"
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.calcom.arn
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
    target_group_arn = aws_lb_target_group.calcom.arn
    container_name   = local.container_name
    container_port   = local.container_port
  }

  depends_on = [aws_lb_listener_rule.calcom]

  lifecycle {
    ignore_changes = [task_definition] # CD updates the image
  }

  tags = var.tags
}
