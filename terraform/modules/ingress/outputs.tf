output "alb_arn" {
  value = module.alb.arn
}

output "alb_dns_name" {
  value = module.alb.dns_name
}

output "alb_zone_id" {
  value = module.alb.zone_id
}

output "alb_security_group_id" {
  value = module.alb.security_group_id
}

output "https_listener_arn" {
  description = "HTTPS listener ARN — service modules attach host-based rules here."
  value       = module.alb.listeners["https"].arn
}

output "certificate_arn" {
  value = aws_acm_certificate_validation.this.certificate_arn
}
