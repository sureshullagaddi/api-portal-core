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
