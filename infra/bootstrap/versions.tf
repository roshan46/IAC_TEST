terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # Milestone 2: begin with local state; add backend "s3" {} after creating the bucket.
}

provider "aws" {
  region = var.aws_region
}
