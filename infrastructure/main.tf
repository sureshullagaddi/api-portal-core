data "aws_caller_identity" "current" {}

locals {
  prefix = "${var.project_name}-${var.environment}"
}

# ── Cognito User Pool ─────────────────────────────────────────────────────────
resource "aws_cognito_user_pool" "this" {
  name                     = "${local.prefix}-user-pool"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_pool_client" "this" {
  name            = "${local.prefix}-client"
  user_pool_id    = aws_cognito_user_pool.this.id
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
}

# ── SSM Parameters — published for backend/frontend repos to consume ──────────
resource "aws_ssm_parameter" "cognito_pool_id" {
  name      = "/${var.project_name}/${var.environment}/cognito/pool-id"
  type      = "String"
  value     = aws_cognito_user_pool.this.id
  overwrite = true
}

resource "aws_ssm_parameter" "cognito_client_id" {
  name      = "/${var.project_name}/${var.environment}/cognito/client-id"
  type      = "String"
  value     = aws_cognito_user_pool_client.this.id
  overwrite = true
}
