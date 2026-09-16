terraform {
  required_version = ">= 1.6"

  required_providers {
    http = {
      source = "hashicorp/http"
      # Reads the published cloud-config. 3.x is where response_body replaced
      # the deprecated body attribute this stack reads.
      version = "~> 3.4"
    }
    aws = {
      source = "hashicorp/aws"
      # 5.x has the vpc_security_group_*_rule resources this stack uses; the
      # older inline `ingress` blocks on aws_security_group are deprecated.
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region. Put it near the people using the console — this is one box, not a CDN."
  type        = string
  default     = "eu-west-2"
}
