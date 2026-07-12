# Application secrets, created as placeholders and populated out-of-band
# (AWS CLI/console). Terraform ignores the value after creation so real
# secrets never live in state-as-code or git.
#
# RDS master password is NOT here — it's AWS-managed (see module.data).

locals {
  app_secrets = {
    n8n_encryption_key     = "n8n credential encryption key — BACK THIS UP; losing it bricks stored credentials"
    n8n_db_password        = "Password for the n8n Postgres role"
    calcom_nextauth_secret = "Cal.com NEXTAUTH_SECRET"
    calcom_encryption_key  = "Cal.com CALENDSO_ENCRYPTION_KEY"
    calcom_database_url    = "Full DATABASE_URL for Cal.com: postgresql://calcom:<pw>@<host>:5432/calcom"

    chat_database_url        = "Full DATABASE_URL for Open WebUI: postgresql://chatui:<pw>@<host>:5432/chatui?sslmode=require"
    chat_webui_secret_key    = "Open WebUI WEBUI_SECRET_KEY (JWT signing + at-rest encryption)"
    chat_oauth_client_secret = "Google Workspace OAuth client secret for chat SSO"
    chat_litellm_master_key  = "LiteLLM master key, must start with sk- (also Open WebUI's OPENAI_API_KEY)"
  }
}

resource "aws_secretsmanager_secret" "app" {
  for_each = local.app_secrets

  name        = "${local.clinic}/${each.key}"
  description = each.value
  kms_key_id  = module.data.kms_key_arn

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "app" {
  for_each = aws_secretsmanager_secret.app

  secret_id     = each.value.id
  secret_string = "placeholder-populate-me"

  lifecycle {
    ignore_changes = [secret_string]
  }
}
