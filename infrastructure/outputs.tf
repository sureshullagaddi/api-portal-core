output "cognito_user_pool_id" { value = aws_cognito_user_pool.this.id }
output "cognito_client_id"    { value = aws_cognito_user_pool_client.this.id }
output "account_id"           { value = data.aws_caller_identity.current.account_id }

output "ssm_paths" {
  description = "SSM parameter paths written — read by api-portal-backend and api-portal-frontend"
  value = {
    cognito_pool_id  = aws_ssm_parameter.cognito_pool_id.name
    cognito_client_id = aws_ssm_parameter.cognito_client_id.name
  }
}

output "create_test_user_commands" {
  description = "Commands to create and authenticate a Cognito test user"
  value       = <<-EOT
    # 1. Create user
    aws cognito-idp admin-create-user \
      --user-pool-id ${aws_cognito_user_pool.this.id} \
      --username test@example.com \
      --temporary-password Temp1234! \
      --message-action SUPPRESS \
      --region ${var.aws_region}

    # 2. Set permanent password
    aws cognito-idp admin-set-user-password \
      --user-pool-id ${aws_cognito_user_pool.this.id} \
      --username test@example.com \
      --password Perm5678@ \
      --permanent \
      --region ${var.aws_region}

    # 3. Get IdToken
    TOKEN=$(aws cognito-idp initiate-auth \
      --auth-flow USER_PASSWORD_AUTH \
      --auth-parameters USERNAME=test@example.com,PASSWORD=Perm5678@ \
      --client-id ${aws_cognito_user_pool_client.this.id} \
      --region ${var.aws_region} \
      --query 'AuthenticationResult.IdToken' --output text)
    echo $TOKEN
  EOT
}
