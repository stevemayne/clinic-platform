locals {
  clinic      = "acc"
  environment = "production"
  project     = "clinic-platform"
  region      = "us-east-1"

  name_prefix = basename(path.cwd) # "acc"

  # ACC's subdomain of the shared platform apex (secureclinic.co).
  # Delegate NS for this zone from the secureclinic.co apex (see below).
  domain_name = "acc.secureclinic.co"

  # Networking
  vpc_cidr           = "10.0.0.0/16"
  azs                = ["us-east-1a", "us-east-1b", "us-east-1c"]
  public_subnets     = ["10.0.0.0/22", "10.0.4.0/22", "10.0.8.0/22"]
  private_subnets    = ["10.0.12.0/22", "10.0.16.0/22", "10.0.20.0/22"]
  single_nat_gateway = true # cost model assumes 1 NAT; flip for HA

  # Data
  multi_az            = false # per-clinic HA upsell
  deletion_protection = true

  common_tags = {
    Clinic      = local.clinic
    Environment = local.environment
    Project     = local.project
    ManagedBy   = "terraform"
  }
}
