terraform {
  required_version = "~> 1.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}