# Public hosted zone for the clinic. After first apply, delegate the registrar's
# NS records to the name servers in the `name_servers` output.
resource "aws_route53_zone" "public" {
  name    = local.domain_name
  comment = "Public hosted zone for ${local.domain_name}"

  tags = local.common_tags
}

module "network" {
  source = "../../modules/network"

  name_prefix        = local.name_prefix
  aws_region         = local.region
  vpc_cidr           = local.vpc_cidr
  azs                = local.azs
  public_subnets     = local.public_subnets
  private_subnets    = local.private_subnets
  single_nat_gateway = local.single_nat_gateway

  tags = local.common_tags
}

module "ecs_cluster" {
  source = "../../modules/ecs_cluster"

  name_prefix = local.name_prefix
  tags        = local.common_tags
}

module "data" {
  source = "../../modules/data"

  name_prefix           = local.name_prefix
  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  ecs_security_group_id = module.network.ecs_security_group_id
  multi_az              = local.multi_az
  deletion_protection   = local.deletion_protection

  # TEMPORARY free-plan sizing — see locals.tf.
  db_instance_class            = local.db_instance_class
  db_allocated_storage         = local.db_allocated_storage
  db_max_allocated_storage     = local.db_max_allocated_storage
  db_backup_retention_days     = local.db_backup_retention_days
  performance_insights_enabled = local.db_performance_insights

  tags = local.common_tags
}

module "ingress" {
  source = "../../modules/ingress"

  name_prefix       = local.name_prefix
  vpc_id            = module.network.vpc_id
  vpc_cidr          = module.network.vpc_cidr
  public_subnet_ids = module.network.public_subnet_ids
  domain_name       = local.domain_name
  zone_id           = aws_route53_zone.public.zone_id

  tags = local.common_tags
}

module "n8n" {
  source = "../../modules/n8n_service"

  name_prefix = local.name_prefix
  aws_region  = local.region

  cluster_arn        = module.ecs_cluster.cluster_arn
  execution_role_arn = module.ecs_cluster.execution_role_arn

  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  ecs_security_group_id = module.network.ecs_security_group_id
  alb_security_group_id = module.ingress.alb_security_group_id

  https_listener_arn = module.ingress.https_listener_arn
  alb_dns_name       = module.ingress.alb_dns_name
  alb_zone_id        = module.ingress.alb_zone_id
  zone_id            = aws_route53_zone.public.zone_id
  domain_name        = local.domain_name

  db_host            = module.data.db_address
  binary_data_bucket = module.data.binary_data_bucket
  kms_key_arn        = module.data.kms_key_arn

  encryption_key_secret_arn = aws_secretsmanager_secret.app["n8n_encryption_key"].arn
  db_password_secret_arn    = aws_secretsmanager_secret.app["n8n_db_password"].arn

  tags = local.common_tags
}

module "calcom" {
  source = "../../modules/calcom_service"

  name_prefix = local.name_prefix
  aws_region  = local.region

  cluster_arn        = module.ecs_cluster.cluster_arn
  execution_role_arn = module.ecs_cluster.execution_role_arn

  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  ecs_security_group_id = module.network.ecs_security_group_id
  alb_security_group_id = module.ingress.alb_security_group_id

  https_listener_arn = module.ingress.https_listener_arn
  alb_dns_name       = module.ingress.alb_dns_name
  alb_zone_id        = module.ingress.alb_zone_id
  zone_id            = aws_route53_zone.public.zone_id
  domain_name        = local.domain_name

  database_url_secret_arn   = aws_secretsmanager_secret.app["calcom_database_url"].arn
  nextauth_secret_arn       = aws_secretsmanager_secret.app["calcom_nextauth_secret"].arn
  encryption_key_secret_arn = aws_secretsmanager_secret.app["calcom_encryption_key"].arn

  tags = local.common_tags
}

module "chat" {
  source = "../../modules/chat_service"

  name_prefix = local.name_prefix
  aws_region  = local.region

  cluster_arn        = module.ecs_cluster.cluster_arn
  execution_role_arn = module.ecs_cluster.execution_role_arn

  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  ecs_security_group_id = module.network.ecs_security_group_id
  alb_security_group_id = module.ingress.alb_security_group_id

  https_listener_arn = module.ingress.https_listener_arn
  alb_dns_name       = module.ingress.alb_dns_name
  alb_zone_id        = module.ingress.alb_zone_id
  zone_id            = aws_route53_zone.public.zone_id
  domain_name        = local.domain_name

  documents_bucket = module.data.documents_bucket
  kms_key_arn      = module.data.kms_key_arn

  oauth_client_id             = local.chat_oauth_client_id
  oauth_allowed_email_domains = local.chat_oauth_allowed_domains

  database_url_secret_arn       = aws_secretsmanager_secret.app["chat_database_url"].arn
  webui_secret_key_secret_arn   = aws_secretsmanager_secret.app["chat_webui_secret_key"].arn
  oauth_client_secret_arn       = aws_secretsmanager_secret.app["chat_oauth_client_secret"].arn
  litellm_master_key_secret_arn = aws_secretsmanager_secret.app["chat_litellm_master_key"].arn

  tags = local.common_tags
}
