data "aws_caller_identity" "current" {}

locals {
  prefix     = "${var.project_name}-${var.environment}"
  lambda_zip = "${path.module}/lambda.zip"
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

# ── Secrets Manager — partner API key ────────────────────────────────────────
resource "aws_secretsmanager_secret" "partner_api_key" {
  name                    = "${local.prefix}/partner-api-key"
  description             = "X-Api-Key used by the custom Lambda authorizer"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "partner_api_key" {
  secret_id     = aws_secretsmanager_secret.partner_api_key.id
  secret_string = var.authorizer_api_key
}

# ── IAM — Backend Lambda ──────────────────────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name = "${local.prefix}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_xray" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# ── IAM — Authorizer Lambda ───────────────────────────────────────────────────
resource "aws_iam_role" "authorizer" {
  name = "${local.prefix}-authorizer-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "authorizer_basic" {
  role       = aws_iam_role.authorizer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "authorizer_secrets" {
  name = "${local.prefix}-authorizer-secrets-policy"
  role = aws_iam_role.authorizer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.partner_api_key.arn
    }]
  })
}

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.prefix}-lambda"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "authorizer" {
  name              = "/aws/lambda/${local.prefix}-authorizer"
  retention_in_days = var.log_retention_days
}

# ── Backend Lambda (api handler) ──────────────────────────────────────────────
resource "aws_lambda_function" "backend" {
  function_name    = "${local.prefix}-lambda"
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs18.x"
  handler          = "index.handler"
  filename         = local.lambda_zip
  source_code_hash = filebase64sha256(local.lambda_zip)
  architectures    = ["arm64"]
  publish          = true
  timeout          = 10

  environment {
    variables = {
      ENVIRONMENT = var.environment
      LOG_LEVEL   = var.environment == "prod" ? "ERROR" : "DEBUG"
    }
  }

  tracing_config { mode = "Active" }
  depends_on     = [aws_cloudwatch_log_group.lambda]
}

resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.backend.function_name
  function_version = aws_lambda_function.backend.version
}

# ── Authorizer Lambda (custom X-Api-Key validator) ────────────────────────────
resource "aws_lambda_function" "authorizer" {
  function_name    = "${local.prefix}-authorizer"
  role             = aws_iam_role.authorizer.arn
  runtime          = "nodejs18.x"
  handler          = "authorizer.handler"
  filename         = local.lambda_zip
  source_code_hash = filebase64sha256(local.lambda_zip)
  architectures    = ["arm64"]
  timeout          = 5

  environment {
    variables = {
      ENVIRONMENT        = var.environment
      VALID_API_KEY      = var.authorizer_api_key
      API_KEY_SECRET_ARN = aws_secretsmanager_secret.partner_api_key.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.authorizer]
}

# ── SNS — alarm notifications (optional: only if alert_email is set) ──────────
resource "aws_sns_topic" "alarms" {
  name = "${local.prefix}-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── CloudWatch Alarms ─────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.prefix}-lambda-errors"
  alarm_description   = "Lambda error rate > 1% for 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 1
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  metric_query {
    id          = "errors"
    return_data = false
    metric {
      metric_name = "Errors"
      namespace   = "AWS/Lambda"
      period      = 300
      stat        = "Sum"
      dimensions  = { FunctionName = aws_lambda_function.backend.function_name }
    }
  }
  metric_query {
    id          = "invocations"
    return_data = false
    metric {
      metric_name = "Invocations"
      namespace   = "AWS/Lambda"
      period      = 300
      stat        = "Sum"
      dimensions  = { FunctionName = aws_lambda_function.backend.function_name }
    }
  }
  metric_query {
    id          = "error_rate"
    expression  = "errors / invocations * 100"
    label       = "Lambda Error Rate (%)"
    return_data = true
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name          = "${local.prefix}-lambda-throttles"
  alarm_description   = "Lambda throttles detected"
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  dimensions          = { FunctionName = aws_lambda_function.backend.function_name }
}

# ── SSM Parameters — published for backend repo to consume ───────────────────
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

resource "aws_ssm_parameter" "lambda_arn" {
  name      = "/${var.project_name}/${var.environment}/lambda/arn"
  type      = "String"
  value     = aws_lambda_function.backend.arn
  overwrite = true
}

resource "aws_ssm_parameter" "lambda_function_name" {
  name      = "/${var.project_name}/${var.environment}/lambda/function-name"
  type      = "String"
  value     = aws_lambda_function.backend.function_name
  overwrite = true
}

resource "aws_ssm_parameter" "authorizer_arn" {
  name      = "/${var.project_name}/${var.environment}/authorizer/arn"
  type      = "String"
  value     = aws_lambda_function.authorizer.arn
  overwrite = true
}

resource "aws_ssm_parameter" "authorizer_function_name" {
  name      = "/${var.project_name}/${var.environment}/authorizer/function-name"
  type      = "String"
  value     = aws_lambda_function.authorizer.function_name
  overwrite = true
}

resource "aws_ssm_parameter" "partner_api_key_secret_arn" {
  name      = "/${var.project_name}/${var.environment}/secrets/partner-api-key-arn"
  type      = "String"
  value     = aws_secretsmanager_secret.partner_api_key.arn
  overwrite = true
}
