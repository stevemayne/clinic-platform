locals {
  fqdn           = "${var.subdomain}.${var.domain_name}"
  container_name = "${var.name_prefix}-calcom"
  container_port = 3000
  image          = "${aws_ecr_repository.calcom.repository_url}:${var.image_tag}"
}

resource "aws_lb_target_group" "calcom" {
  name        = "${var.name_prefix}-calcom"
  port        = local.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    # Cal.com root redirects to the login/app page; allow redirects.
    # Verify the exact health path against the chosen image during testing.
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags
}

resource "aws_lb_listener_rule" "calcom" {
  listener_arn = var.https_listener_arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.calcom.arn
  }

  condition {
    host_header {
      values = [local.fqdn]
    }
  }

  tags = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "alb_to_task" {
  security_group_id            = var.ecs_security_group_id
  description                  = "ALB to Cal.com task"
  from_port                    = local.container_port
  to_port                      = local.container_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = var.alb_security_group_id
}

resource "aws_route53_record" "calcom" {
  zone_id = var.zone_id
  name    = local.fqdn
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}
