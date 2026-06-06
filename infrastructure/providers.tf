terraform {
  required_version = ">= 1.5"
  required_providers {
    aws     = { source = "hashicorp/aws",     version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
  }
  backend "s3" {
    bucket         = "tf-state-397979615352"
    region         = "eu-north-1"
    dynamodb_table = "api-portal-terraform-locks"
    encrypt        = true
    # key injected per env: -backend-config="key=api-portal/core/{env}/terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "api-portal"
      Component   = "core"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repo        = "api-portal-core"
    }
  }
}

