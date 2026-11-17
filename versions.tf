terraform {
  required_version = ">= 1.16.5, < 2.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.68.0"
    }
  }
  backend "local" { path = "terraform.tfstate" }
}

provider "aws" {
  region = "eu-north-1"
  default_tags {
    tags = { Project = "s3-three-day-demo", ManagedBy = "Terraform" }
  }
}
