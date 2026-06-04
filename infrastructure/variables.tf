variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-north-1"
}

variable "project_name" {
  description = "Project name used as prefix for all AWS resource names"
  type        = string
  default     = "api-portal"
}

variable "environment" {
  description = "Deployment environment (dev | sit | stage | prod)"
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "sit", "stage", "prod"], var.environment)
    error_message = "environment must be one of: dev, sit, stage, prod."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 14
}

variable "alert_email" {
  description = "Email for CloudWatch alarm notifications. Leave empty to skip SNS subscription."
  type        = string
  default     = ""
}

variable "authorizer_api_key" {
  description = "Default X-Api-Key for the custom authorizer Lambda (stored in Secrets Manager)"
  type        = string
  default     = "my-secret-key-123"
  sensitive   = true
}
