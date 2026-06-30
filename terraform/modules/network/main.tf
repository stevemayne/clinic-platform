# VPC with public + private subnets. ECS tasks and RDS run in the private
# subnets behind NAT; the ALB sits in the public subnets. Interface VPC
# endpoints keep PHI-bearing traffic to AWS services (Bedrock, ECR, Secrets
# Manager, CloudWatch Logs) off the public internet.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = ">= 6.0.0, < 7.0.0"

  name = "${var.name_prefix}-vpc"
  cidr = var.vpc_cidr
  azs  = var.azs

  public_subnets  = var.public_subnets
  private_subnets = var.private_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = var.tags
}

# --- Security groups --------------------------------------------------------

resource "aws_security_group" "ecs" {
  name        = "${var.name_prefix}-ecs-sg"
  description = "ECS tasks: all outbound, inbound managed per-service."
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-ecs-sg" })
}

resource "aws_vpc_security_group_egress_rule" "ecs_all_outbound" {
  security_group_id = aws_security_group.ecs.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.name_prefix}-vpce-sg"
  description = "Allow HTTPS from within the VPC to interface endpoints."
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "vpce_https_from_vpc" {
  security_group_id = aws_security_group.vpc_endpoints.id
  description       = "HTTPS from within the VPC"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# --- VPC endpoints ----------------------------------------------------------

# S3 gateway endpoint (free) — used by ECR image layer pulls and n8n binary data.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-s3-vpce" })
}

# Interface endpoints for the AWS services tasks talk to privately.
locals {
  interface_endpoints = {
    ecr_api         = "com.amazonaws.${var.aws_region}.ecr.api"
    ecr_dkr         = "com.amazonaws.${var.aws_region}.ecr.dkr"
    secretsmanager  = "com.amazonaws.${var.aws_region}.secretsmanager"
    logs            = "com.amazonaws.${var.aws_region}.logs"
    bedrock_runtime = "com.amazonaws.${var.aws_region}.bedrock-runtime"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = module.vpc.vpc_id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}-vpce" })
}
