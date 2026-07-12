locals {
  clinic      = "__CLINIC__"
  environment = "production"
  project     = "clinic-platform"
  region      = "us-east-1"

  name_prefix = basename(path.cwd) # must match the directory name = clinic slug

  # Replace with the clinic's real domain (delegate NS to the zone created below).
  domain_name = "__CLINIC__.example.com"

  # Networking — each clinic is its own account/VPC, so the CIDR can be reused.
  vpc_cidr           = "10.0.0.0/16"
  azs                = ["us-east-1a", "us-east-1b", "us-east-1c"]
  public_subnets     = ["10.0.0.0/22", "10.0.4.0/22", "10.0.8.0/22"]
  private_subnets    = ["10.0.12.0/22", "10.0.16.0/22", "10.0.20.0/22"]
  single_nat_gateway = true

  # Data
  multi_az            = false
  deletion_protection = true

  # Chat SSO — populate once the clinic's Workspace admin creates the OAuth
  # client (Google Cloud, consent screen = Internal, redirect URI = the
  # chat_oidc_redirect_uri output). Client ID is non-sensitive; the secret
  # goes in the <clinic>/chat_oauth_client_secret placeholder. While the ID
  # is empty the chat UI falls back to local login — claim the admin account.
  chat_oauth_client_id       = ""
  chat_oauth_allowed_domains = "" # the clinic's Workspace email domain

  common_tags = {
    Clinic      = local.clinic
    Environment = local.environment
    Project     = local.project
    ManagedBy   = "terraform"
  }
}
