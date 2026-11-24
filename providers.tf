terraform {
  required_version = ">= 1.15.0, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.23.0, < 7.0.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
  default_tags {
    tags = {
      Project = "goit-dev-ops-hw-04"
    }
  }
}
