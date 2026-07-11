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

  # TEMPORARY — sized to the AWS free plan while ACC is pre-launch. Revert to
  # the module defaults (db.t4g.small, 30→100 GB, 7-day backups, Performance
  # Insights on) before real PHI lands: 1-day backup retention is below the
  # platform's HIPAA posture. Tracked in TODO.md §1.
  db_instance_class        = "db.t4g.micro" # free-plan-eligible class
  db_allocated_storage     = 20             # free-plan storage cap
  db_max_allocated_storage = 0              # storage autoscaling off
  db_backup_retention_days = 1              # free-plan maximum
  db_performance_insights  = false

  common_tags = {
    Clinic      = local.clinic
    Environment = local.environment
    Project     = local.project
    ManagedBy   = "terraform"
  }
}
