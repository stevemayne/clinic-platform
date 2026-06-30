locals {
  fqdn           = "${var.subdomain}.${var.domain_name}"
  container_name = "${var.name_prefix}-n8n"
  container_port = 5678
}

resource "aws_lb_target_group" "n8n" {
  name        = "${var.name_prefix}-n8n"
  port        = local.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags
}

resource "aws_lb_listener_rule" "n8n" {
  listener_arn = var.https_listener_arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.n8n.arn
  }

  condition {
    host_header {
      values = [local.fqdn]
    }
  }

  tags = var.tags
}

# Allow the ALB to reach the task on the n8n port (added to the shared ECS SG).
resource "aws_vpc_security_group_ingress_rule" "alb_to_task" {
  security_group_id            = var.ecs_security_group_id
  description                  = "ALB to n8n task"
  from_port                    = local.container_port
  to_port                      = local.container_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = var.alb_security_group_id
}

resource "aws_route53_record" "n8n" {
  zone_id = var.zone_id
  name    = local.fqdn
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}
