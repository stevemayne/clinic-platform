# One-off Prisma migration task. Not a service — the deploy workflow runs it
# with `aws ecs run-task` (gated before the service rolls), e.g.:
#
#   aws ecs run-task --cluster <cluster> --launch-type FARGATE \
#     --task-definition <this family> \
#     --network-configuration "awsvpcConfiguration={subnets=[...],securityGroups=[...],assignPublicIp=DISABLED}"
#
# Verify the migrate command against the chosen Cal.com image during testing.

resource "aws_ecs_task_definition" "migrate" {
  family                   = "${var.name_prefix}-calcom-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "${var.name_prefix}-calcom-migrate"
      image     = local.image
      essential = true
      command   = ["npx", "prisma", "migrate", "deploy", "--schema", "packages/prisma/schema.prisma"]

      secrets = [
        { name = "DATABASE_URL", valueFrom = var.database_url_secret_arn },
        # Prisma's directUrl (pooler bypass) — no PgBouncer here, so same URL.
        { name = "DATABASE_DIRECT_URL", valueFrom = var.database_url_secret_arn },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.calcom.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "migrate"
          mode                  = "non-blocking"
        }
      }
    }
  ])

  tags = var.tags
}
